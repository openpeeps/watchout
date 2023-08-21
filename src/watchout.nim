import std/[tables, typeinfo, times, os, strutils]

export typeinfo

type
  File* = ref object
    path: string
    lastModified: Time

  Callback* = proc(file: File) {.closure.} 

  Watchout* = object
    entries: OrderedTableRef[string, File]
    callback: Callback
  
  WatchoutException* = object of CatchableError

when not compileOption("threads"):
  raise newException(WatchoutException, "Watchout requires --threads:on")

var
  m {.threadvar}: Watchout
  thr: Thread[(seq[string], Callback, int)]

proc getPath*[F: File](f: F): string = f.path
proc getName(f: string): string = splitPath(f).tail
proc getName*[F: File](f: F): string = getName(f.path)

template walkHandler() {.dirty.} =
  monitor.entries[entry] = new File
  monitor.entries[entry].path = entry
  monitor.entries[entry].lastModified = getLastModificationTime(entry)

proc add(monitor: var Watchout, f: string) {.thread.} =
  if likely(f.fileExists):
    if likely(not monitor.entries.hasKey(f)):
      var entry = f
      walkHandler()
    else: raise newException(WatchoutException, "Duplicate file in Watchout monitor:\n$1" % [f])
  elif f.dirExists:
    for entry in walkDirRec(f):
      if entry.isHidden or monitor.entries.hasKey(f): continue
      walkHandler
  elif f.parentDir.dirExists:
    for entry in walkPattern(f):
      if entry.isHidden or monitor.entries.hasKey(f): continue
      walkHandler
  else: raise newException(WatchoutException, "File does not exist:\n$1" % [f])

proc start(arg: (seq[string], Callback, int)) {.thread.} =
  {.gcsafe.}:
    m.callback = arg[1]
    m.entries = newOrderedTable[string, File]()
    for p in arg[0]:
      m.add(p)
    while true:
      for path, file in m.entries.mpairs():
        if likely(path.fileExists or path.dirExists):
          let updateLastModified = getLastModificationTime(file.path)
          if file.lastModified != updateLastModified:
            m.callback(file)
            file.lastModified = updateLastModified
            m.entries[file.path] = file 
        else:
          echo "File $1 has been deleted" % [path.getName]
          m.entries.del(path)
      sleep(arg[2])

proc startThread*(callback: Callback, files: seq[string], ms: int, shouldJoinThread = false) =
  ## Run Watchout in a separate thread 
  createThread(thr, start, (files, callback, ms))
  if shouldJoinThread:
    joinThread(thr)

# proc spawnProcess*(callback: Callback, files: seq[string], ms: int) =
#   spawn start((files, callback, ms))
