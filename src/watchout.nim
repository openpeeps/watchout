# A stupid simple filesystem monitor.
#
#   (c) George Lemon | MIT License
#   Made by humans from OpenPeeps
#   https://gitnub.com/openpeeps/watchout

import std/[locks, os, tables,
  hashes, options, asyncdispatch, times]

import pkg/[httpx, websocketx]

from std/net import Port, `$`
export Port

type
  File* = object
    path: string
    lastModified: Time

  WatchCallback* = proc(file: File) {.closure.}
  WatchoutBrowserSync* = ref object
    port*: Port
    delay*: range[100..5000]

  Watchout* = ref object
    pattern: string
    dirs, ext: seq[string]
    delay: range[100..5000] 
    files {.guard: L.}: TableRef[string, File] = newTable[string, File]()
    onChange, onFound, onDelete: WatchCallback
    recursive: bool
    browserSync: WatchoutBrowserSync
    prevModified {.guard: L.}: Time
    lastModified {.guard: L.}: Time
    isModified {.guard: L.}: bool
    L: Lock

template updateTimes {.dirty.} =
  watch.prevModified = watch.lastModified
  watch.lastModified = file.lastModified
  if watch.lastModified > watch.prevModified:
    watch.isModified = true

proc handleIndex(watch: Watchout) {.thread.} =
  var hasExt = watch.ext.len > 0
  if watch.pattern.len > 0:
    while true:
      for f in walkFiles(watch.pattern):
        if f.isHidden: continue
        if hasExt:
          if not watch.ext.contains(f.splitFile().ext):
            continue
        {.gcsafe.}:
          let fpath = absolutePath(f)
          withLock watch.L:
            if not watch.files.hasKey(fpath):
              let finfo = fpath.getFileInfo
              var file = File(path: fpath, lastModified: finfo.lastWriteTime)
              watch.files[fpath] = file
              if watch.onFound != nil:
                watch.onFound(file)
              else:
                watch.onChange(file)
              updateTimes()
      sleep(watch.delay * 100) # todo idle mode
  else:
    while true:
      for dir in watch.dirs:
        for path in walkPattern(dir):
          let finfo = path.getFileInfo
          case finfo.kind
          of pcFile:
            if path.isHidden: continue
            if hasExt:
              if not watch.ext.contains(path.splitFile().ext):
                continue
            withLock watch.L:
              {.gcsafe.}:
                let fpath = absolutePath(path)
                if not watch.files.hasKey(fpath): 
                  var file = File(path: fpath, lastModified: finfo.lastWriteTime)
                  watch.files[fpath] = file
                  if watch.onFound != nil:
                    watch.onFound(file)
                  else:
                    watch.onChange(file)
                  updateTimes()
          of pcDir:
            for f in walkDirRec(path, yieldFilter = {pcFile}):
              withLock watch.L:
                {.gcsafe.}:
                  let finfo = f.getFileInfo
                  let fpath = absolutePath(f)
                  if fpath.isHidden: continue
                  if hasExt:
                    if not watch.ext.contains(splitFile(fpath).ext):
                      continue
                  if not watch.files.hasKey(fpath):
                    var file = File(path: fpath, lastModified: finfo.lastWriteTime)
                    watch.files[fpath] = file
                    if watch.onFound != nil:
                      watch.onFound(file)
                      updateTimes()
                    else:
                      watch.onChange(file)
                      updateTimes()
          else: discard # todo support symlinks ?
      sleep(watch.delay * 100) # todo idle mode

proc handleChanges(watch: Watchout) {.thread.} =
  while true:
    withLock watch.L:
      {.gcsafe.}:
        if watch.files.len > 0:
          var queue: seq[string]
          for fpath, file in mpairs(watch.files):
            if likely(fpath.fileExists):
              let finfo = fpath.getFileInfo
              if finfo.lastWriteTime > file.lastModified:
                file.lastModified = finfo.lastWriteTime
                watch.onChange(file)
                updateTimes()
            else:
              if watch.onDelete != nil:
                watch.onDelete(file)
                updateTimes()
              queue.add(fpath)
          for f in queue:
            watch.files.del(f)
    sleep(watch.delay)

proc newWatchout*(pattern: string, onChange: WatchCallback, onFound,
    onDelete: WatchCallback = nil, delay: range[100..5000] = 350,
    recursive = false, browserSync: WatchoutBrowserSync = nil): Watchout =
  ## Create a new `Watchout` instance that discovers
  Watchout(pattern: pattern, delay: delay,
    onChange: onChange, onFound: onFound,
    onDelete: onDelete, recursive: recursive,
    browserSync: browserSync)

proc newWatchout*(dirs: seq[string], onChange: WatchCallback, onFound,
    onDelete: WatchCallback = nil, delay: range[100..5000] = 350,
    recursive = false, ext: seq[string] = @[],
    browserSync: WatchoutBrowserSync = nil): Watchout =
  ## Create a new `Watchout` instance based on multiple `dirs` targets
  ## For example: `@["../some/*.json", "./tests/*.nims"]`
  Watchout(dirs: dirs, delay: delay,
    onChange: onChange, onFound: onFound,
    onDelete: onDelete, recursive: recursive, ext: ext,
    browserSync: browserSync)

proc runBrowserSync*(x: (Port, int, ptr Lock, ptr bool)) {.thread.} =
  proc onRequest(req: Request) {.async.} =
    if req.httpMethod == some HttpGet:
      case req.path.get:
      of "/":
        req.send("Watchout is running")
      of "/ws":
        try:
          var ws = await newWebSocket(req)
          while ws.readyState == Open:
            withLock x[2][]:
              if x[3][]:
                await ws.send("1")
                ws.close()
                x[3][] = false
                break
            await ws.send("0")
            sleep(x[1])
          await ws.send("0")
        except WebSocketClosedError:
          echo "Socket closed"
        except WebSocketProtocolMismatchError:
          echo "Socket tried to use an unknown protocol: ", getCurrentExceptionMsg()
        except WebSocketError:
          req.send(Http404)
      else: req.send(Http404)
    else: req.send(Http503)
  let settings = initSettings(x[0], numThreads = 1)
  httpx.run(onRequest, settings)

proc getPath*(file: File): string =
  result = file.path

proc getName*(file: File): string =
  result = file.path.extractFilename()

proc getLastModified*(file: File): Time =
  result = file.lastModified

proc startThread*(w: Watchout) {.thread.} =
  var threads = newSeq[Thread[Watchout]](2)
  # var indexThread: Thread[Watchout]
  # var changesThread: Thread[Watchout]
  var browserSyncThread: Thread[(Port, int, ptr Lock, ptr bool)]
  createThread(threads[0], handleIndex, w)
  createThread(threads[1], handleChanges, w)
  withLock w.L:
    when defined watchoutBrowserSync:
      if w.browserSync != nil:
        createThread(browserSyncThread, runBrowserSync,
          (w.browserSync.port, w.browserSync.delay, addr(w.L), addr(w.isModified)))
  joinThreads(threads)

proc start*(w: Watchout) =
  var thr: Thread[Watchout]
  createThread(thr, startThread, w)
  sleep(5)
