# A stupid simple filesystem monitor.
#
#   (c) George Lemon | MIT License
#       Made by humans from OpenPeeps
#       https://gitnub.com/openpeeps/watchout

import std/[os, strutils, options, tables, times]

when defined(macosx) or defined(bsd):
  {.passL: "-fobjc-arc -framework CoreServices -framework CoreFoundation".}
elif defined(linux):
  {.passL: "-lrt".}
elif defined(windows):
  {.passL: "-lws2_32 -liphlpapi".}
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

# Platform-specific watch proc
when defined(macosx) or defined(bsd):
  import watchout/platform/mac as platformWatch
  proc watchDirs(dirs: seq[string], cb: WatchoutCallbackC, watcher: pointer) =
    platformWatch.watch(dirs, cb, watcher)
elif defined(linux):
  import watchout/platform/linux as platformWatch
  proc watchDirs(dirs: seq[string], cb: WatchoutCallbackC, watcher: pointer) =
    platformWatch.watch(dirs, cb, watcher)
elif defined(windows):
  import watchout/platform/windows as platformWatch
  proc watchDirs(dirs: seq[string], cb: WatchoutCallbackC, watcher: pointer) =
    platformWatch.watch(dirs, cb, watcher)
else:
  error("Unsupported OS")

proc matchesPattern(path: string, pattern: Option[string]): bool =
  ## Check if a file path matches the given glob pattern.
  if pattern.isNone:
    return true
  let pat = pattern.get()
  let filename = path.extractFilename()
  # Simple glob matching: support * and ?
  if pat.contains('*') or pat.contains('?'):
    # Convert glob to simple regex-like matching
    let patParts = pat.split('*')
    if patParts.len == 1:
      # No * in pattern, try exact match with ? support
      if patParts[0].len != filename.len:
        return false
      for i in 0 ..< patParts[0].len:
        if patParts[0][i] != '?' and patParts[0][i] != filename[i]:
          return false
      return true
    # Has * - check prefix and suffix
    let prefix = patParts[0]
    let suffix = patParts[^1]
    if prefix.len > 0 and not filename.startsWith(prefix):
      return false
    if suffix.len > 0 and not filename.endsWith(suffix):
      return false
    return true
  # Exact match
  return filename == pat

proc isHidden(path: string): bool =
  ## Check if a file is hidden (starts with .).
  let filename = path.extractFilename()
  return filename.len > 0 and filename[0] == '.'

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

proc handleEvent*(watch: Watchout, path: string) =
  ## Process a filesystem event for the given path.
  ## Handles file creation, modification, and deletion tracking.

  # Check ignoreHidden
  if watch.ignoreHidden and path.isHidden():
    return

  # Check pattern
  if not path.matchesPattern(watch.pattern):
    return

  if watch.files.hasKey(path):
    if fileExists(path):
      let lastMod = getFileInfo(path).lastWriteTime
      if watch.files[path].lastModified < lastMod:
        watch.files[path].lastModified = lastMod
        if watch.onChange != nil:
          watch.onChange(watch.files[path])
    else:
      if watch.onDelete != nil:
        watch.onDelete(watch.files[path])
      watch.files.del(path)
  elif fileExists(path):
    let file = File(path: path, lastModified: getFileInfo(path).lastWriteTime)
    watch.files[path] = file
    if watch.onFound != nil:
      watch.onFound(file)
    if watch.onChange != nil:
      watch.onChange(file)

proc onWatch(path: cstring, watcher: pointer) {.cdecl.} =
  let w = cast[Watchout](watcher)
  handleEvent(w, $path)

proc start*(watch: Watchout) =
  ## Start monitoring the filesystem for changes.
  if watch.srcDirs.len == 0: return
  watchDirs(watch.srcDirs, onWatch, cast[pointer](watch))

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
