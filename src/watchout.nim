# A stupid simple filesystem monitor.
#
#   (c) George Lemon | MIT License
#   Made by humans from OpenPeeps
#   https://gitnub.com/openpeeps/watchout

import std/[locks, os, tables, hashes,
    asyncdispatch, times]

type
  File* = object
    path: string
    lastModified: Time

  WatchoutCallback* = proc(file: File) {.closure.}

  Watchout* = ref object
    srcPath: seq[string]
    pattern: string
    files {.guard: L.}: TableRef[string, File] = newTable[string, File]()
    onChange, onFound, onDelete*: WatchoutCallback
    L: Lock

proc newWatchout*(sourceDir, pattern: string): Watchout =
  ## Initialize a new Watchout instance.
  result = Watchout()
  result.srcPath = @[sourceDir]
  result.pattern = pattern

proc newWatchout*(dirs: seq[string], pattern: string): Watchout =
  ## Initialize a new Watchout instance.
  result = Watchout()
  result.srcPath = dirs
  result.pattern = pattern

proc indexFile(watch: Watchout, p: string)  =
  let path = absolutePath(p)
  withLock watch.L:
    {.gcsafe.}:
      let fileInfo = path.getFileInfo()
      if not watch.files.hasKey(path):
        let watchoutFile = File(
          path: path,
          lastModified: fileInfo.lastWriteTime
        )
        watch.files[path] = watchoutFile
        if watch.onFound != nil:
          watch.onFound(watchoutFile)  # call the onFound callback, if it exists
        else:
          watch.onChange(watchoutFile)   # otherwise, run the default callback
      else:
        if fileInfo.lastWriteTime > watch.files[path].lastModified:
          # file has been modified. run the onChange callback
          watch.onChange(watch.files[path])
          watch.files[path].lastModified = fileInfo.lastWriteTime

proc indexHandler(watch: Watchout) {.thread.} =
  while true:
    for dir in watch.srcPath:
      # iterate over the files in the `srcPath` directories
      for path in walkPattern(dir):
        let fileInfo = path.getFileInfo()
        case fileInfo.kind
        of pcFile:
          watch.indexFile(path)
        of pcDir:
          for f in walkDirRec(path, yieldFilter = {pcFile}):
            if f.isHidden: continue
            watch.indexFile(f)
        else: discard
    sleep(200) # todo expose the delay as a parameter

proc onChangeCallback*(watch: Watchout, callback: WatchoutCallback) =
  ## Set the onChange callback.
  watch.onChange = callback

proc onFoundCallback*(watch: Watchout, callback: WatchoutCallback) =
  ## Set the onFound callback.
  watch.onFound = callback

proc onDeleteCallback*(watch: Watchout, callback: WatchoutCallback) =
  ## Set the onDelete callback.
  watch.onDelete = callback

proc getPath*(file: File): string =
  ## Get the path of the file.
  result = file.path

proc getName*(file: File): string =
  ## Get the name of the file.
  result = file.path.extractFilename()

proc start*(w: Watchout) =
  ## Start the Watchout instance.
  var watchoutThreads = newSeq[Thread[Watchout]](3)
  
  # create a thread for the index handler
  # in this thread we will watch the new files
  createThread(watchoutThreads[0], indexHandler, w)
  sleep(10)
