# A stupid simple filesystem monitor.
#
#   (c) George Lemon | MIT License
#   Made by humans from OpenPeeps
#   https://gitnub.com/openpeeps/watchout

import std/[locks, os, tables, hashes, times]

when not compileOption("threads"):
  raise newException(WatchoutException, "Watchout requires --threads:on")

var wlocker: Lock
type
  File* = object
    path: string
    lastModified: Time

  WatchCallback* = proc(file: File) {.closure.}

  Watchout* = ref object
    pattern: string
    dirs: seq[string]
    delay: range[200..5000] 
    files {.guard: wlocker.}: Table[string, File]
    onChange, onFound, onDelete: WatchCallback
    recursive: bool

var thr: array[0..1, Thread[Watchout]]

proc handleIndex(watch: Watchout) {.thread.} =
  # todo ignore hidden files?
  if watch.pattern.len > 0:
    while true:
      for f in walkFiles(watch.pattern):
        withLock wlocker:
          {.gcsafe.}:
            let fpath = absolutePath(f)
            if not watch.files.hasKey(fpath):
              let finfo = fpath.getFileInfo
              var file = File(path: fpath, lastModified: finfo.lastWriteTime)
              watch.files[fpath] = file
              if watch.onFound != nil:
                watch.onFound(file)
              else:
                watch.onChange(file)
      sleep(watch.delay * 2) # todo idle mode
  else:
    while true:
      for dir in watch.dirs:
        for path in walkPattern(dir):
          let finfo = path.getFileInfo
          case finfo.kind
          of pcFile:
            withLock wlocker:
              {.gcsafe.}:
                let fpath = absolutePath(path)
                if not watch.files.hasKey(fpath): 
                  var file = File(path: fpath, lastModified: finfo.lastWriteTime)
                  watch.files[fpath] = file
                  if watch.onFound != nil:
                    watch.onFound(file)
                  else:
                    watch.onChange(file)
          of pcDir:
            # todo recursive walk when pattern
            # contains ext /some/dir/*.txt
            for f in walkDirRec(path):
              withLock wlocker:
                {.gcsafe.}:
                  let finfo = f.getFileInfo
                  let fpath = absolutePath(f)
                  if not watch.files.hasKey(fpath):
                    var file = File(path: fpath, lastModified: finfo.lastWriteTime)
                    watch.files[fpath] = file
                    if watch.onFound != nil:
                      watch.onFound(file)
                    else:
                      watch.onChange(file)
          else: discard # todo support symlinks ?
      sleep(watch.delay * 2) # todo idle mode

proc handleChanges(watch: Watchout) {.thread.} =
  while true:
    withLock wlocker:
      {.gcsafe.}:
        if watch.files.len > 0:
          var queue: seq[string]
          for fpath, file in mpairs(watch.files):
            if likely(fpath.fileExists):
              let finfo = fpath.getFileInfo
              if finfo.lastWriteTime > file.lastModified:
                file.lastModified = finfo.lastWriteTime
                watch.onChange(file)
            else:
              if watch.onDelete != nil:
                watch.onDelete(file)
              queue.add(fpath)
          for f in queue:
            watch.files.del(f)
    sleep(watch.delay)

proc newWatchout*(pattern: string, onChange: WatchCallback, onFound,
    onDelete: WatchCallback = nil, delay: range[200..5000] = 350): Watchout =
  ## Creates a new `Watchout` instance that discovers files based on `pattern`,
  ## For example: `./some/*.nims`
  Watchout(pattern: pattern, delay: delay, onChange: onChange, onFound: onFound, onDelete: onDelete)

proc newWatchout*(dirs: seq[string], onChange: WatchCallback, onFound,
    onDelete: WatchCallback = nil, delay: range[200..5000] = 350,
    recursive = false): Watchout =
  ## Creates a new `Watchout` instance that discovers files
  ## based on given `dirs` directories. 
  ## For example: `@["../some/*.json", "./tests/*.nims"]`
  Watchout(dirs: dirs, delay: delay, onChange: onChange,
    onFound: onFound, onDelete: onDelete, recursive: recursive)

proc getPath*(file: File): string =
  result = file.path

template lockit(x: typed) =
  initLock(wlocker)
  x
  deinitLock(wlocker)

proc start*(w: Watchout, waitThreads = false) =
  lockit:
    createThread(thr[0], handleIndex, w)
    createThread(thr[1], handleChanges, w)
    if waitThreads: joinThreads(thr)