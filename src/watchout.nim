# A stupid simple filesystem monitor.
#
#   (c) George Lemon | MIT License
#       Made by humans from OpenPeeps
#       https://gitnub.com/openpeeps/watchout

import std/[os, strutils, options, tables, times]

when defined osx:
  {.passL: "-fobjc-arc -framework CoreServices".}
  {.compile: "watcher_macos.c".}
elif defined linux:
  {.passL: "-lrt".}
  {.compile: "watcher_linux.c".}
elif defined windows:
  {.passL: "-lws2_32 -liphlpapi".}
  {.compile: "watcher_windows.c".}
else:
  error("Unsupported OS")

type
  WatchoutCallbackC = proc(path: cstring, watcher: pointer) {.cdecl.}
  WatchoutCallback* = proc(file: File) {.closure.}

  File* = object
    path: string
      ## The absolute path of the file
    lastModified: Time
      ## The last modified time of the file

  Watchout* = ref object
    ## A Watchout instance monitors filesystem changes
    pattern*: Option[string]
      ## Optionally, a glob pattern to filter files
      ## (e.g. "*.html", "*.nim", etc)
      ## 
      ## If not set, all files are monitored.
    srcDirs*: seq[string]
      ## Directories to monitor
    files: TableRef[string, File] = newTable[string, File]()
      # A table to keep track of monitored files
    ignoreHidden*: bool = true
      ## Whether to ignore hidden files (default: true)
    onChange*, onFound*, onDelete*: WatchoutCallback
      # Callback procs for file events

#
# Nim FFI to C watcher implementations
#
proc watchFileSystem(dirs: ptr cstring, dirCount: cint, cb: WatchoutCallbackC,
                  watcher: pointer) {.cdecl, importc: "watch_paths".}

#
# Initialize a new Watchout instance.
#
proc newWatchout*(sourceDir: string, pattern: Option[string] = none(string)): Watchout =
  ## Initialize a new Watchout instance watching a single directory.
  result = Watchout()
  result.srcDirs = @[sourceDir]
  result.pattern = pattern

proc newWatchout*(dirs: seq[string], pattern: Option[string] = none(string)): Watchout =
  ## Initialize a new Watchout instance.
  result = Watchout()
  result.srcDirs = dirs
  result.pattern = pattern

proc getPath*(file: File): string =
  ## Get the path of the file.
  result = file.path

proc getName*(file: File): string =
  ## Get the name of the file.
  result = file.path.extractFilename()

proc start*(watch: Watchout) =
  ## Start monitoring the filesystem for changes.
  ## The C implementation handles threading.
  proc onWatch(path: cstring, watcher: pointer) {.cdecl.} =
    let watch = cast[Watchout](watcher)
    let p = $path
    if watch.files.hasKey(p):
      if fileExists(p):
        let lastMod = getFileInfo(p).lastWriteTime
        if watch.files[p].lastModified < lastMod:
          watch.files[p].lastModified = getFileInfo(p).lastWriteTime
          if watch.onChange != nil:
            watch.onChange(watch.files[p])
      else:
        if watch.onDelete != nil:
          watch.onDelete(watch.files[p])
        watch.files.del(p)
    else:
      # new file found by watcher does not mean
      # is a new file on disk
      watch.files[p] = File(path: p, lastModified: getFileInfo(p).lastWriteTime)
      if watch.onChange != nil:
        watch.onChange(watch.files[p])

  # Prepare array of cstrings for C ABI
  if watch.srcDirs.len == 0: return
  var cpaths = newSeq[cstring](watch.srcDirs.len)
  for i, d in watch.srcDirs: cpaths[i] = cstring(d)
  watchFileSystem(unsafeAddr cpaths[0], cint(cpaths.len), onWatch, cast[pointer](watch))

when isMainModule:
  var w = newWatchout(@[getCurrentDir(), getCurrentDir().parentDir])
  
  w.onFound = proc(file: File) =
    echo "Found: ", file.path

  w.onChange = proc(file: File) =
    echo "Changed: ", file.path

  w.onDelete = proc(file: File) =
    echo "Deleted: ", file.path

  w.start()

  while true:
    sleep(1000)
