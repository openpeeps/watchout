import std/[tables, locks, typeinfo]

from std/times import Time
from std/os import getLastModificationTime, sleep, fileExists, splitPath, execShellCmd
from std/strutils import `%`, strip, split
from std/osproc import execProcess, poStdErrToStdOut, poUsePath

export typeinfo

type
    File* = ref object
        path: string
        lastModified: Time

    Callback* = proc(file: File) {.gcsafe.}

    Watchout* = object
        ref_files: seq[string]
        files: OrderedTable[string, File]
        cleanOutput: bool
        callback: Callback
    
    FSNotifyException* = object of CatchableError

when not compileOption("threads"):
    raise newException(FSNotifyException, "Watchout requires --threads:on")

var
    l: Lock
    m {.threadvar}: Watchout
    thr: Thread[(seq[string], Callback, int)]

proc getPath*[F: File](f: F): string = f.path
proc getName(f: string): string = splitPath(f).tail
proc getName*[F: File](f: F): string = getName(f.path)

# proc cleanOutputIfEnabled(monitor: var Watchout) =
#     ## Clean previous output in terminal screen
#     if monitor.cleanOutput: discard execShellCmd("clear")

proc addFile*[W: Watchout](monitor: var W, f: string) =
    ## Add a new file for monitoring live changes with callback procedure
    if f.fileExists():
        if not monitor.files.hasKey(f):
            monitor.files[f] = new File
            monitor.files[f].path = f
            monitor.files[f].lastModified = getLastModificationTime(f)
            monitor.ref_files.add(f)
        else: raise newException(FSNotifyException, "File has already been monitored once")
    else: raise newException(FSNotifyException, "File does not exist:\n$1" % [f])

proc start(arg: (seq[string], Callback, int)) {.thread.} =
    m.callback = arg[1]
    for path in arg[0]:
        m.addFile path
    var i = 1
    let allFiles = arg[0].len
    while true:
        for k, file in m.files.mpairs():
            if likely(fileExists(k)):
                let updateLastModified = getLastModificationTime(file.path)
                if file.lastModified != updateLastModified:
                    # m.cleanOutputIfEnabled()
                    m.callback(file)
                    file.lastModified = updateLastModified
                    m.files[file.path] = file 
            else:
                echo "File $1 has been deleted" % [k.getName]
        sleep(arg[2])

template startThread*[W: typedesc[Watchout]](monitor: W, callback: Callback, files: seq[string], ms: int, shouldJoinThread = false) =
    createThread(thr, start, (files, callback, ms))
    if shouldJoinThread:
        joinThread(thr)
