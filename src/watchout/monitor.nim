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
    m {.guard: l.}: Watchout
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
    withLock(l):
        {.gcsafe.}:
            m.callback = arg[1]
            for path in arg[0]:
                m.addFile path
    var i = 1
    let allFiles = arg[0].len
    while true:
        if i > allFiles: i = 1
        let filePathID = arg[0][i - 1]
        withLock(l):
            {.gcsafe.}:
                var fobj = m.files[filePathID]
                if filePathID.fileExists():
                    let updateLastModified = getLastModificationTime(fobj.path)
                    if fobj.lastModified != updateLastModified:
                        # m.cleanOutputIfEnabled()
                        m.callback(fobj)
                        fobj.lastModified = updateLastModified
                        m.files[filePathID] = fobj
                else:
                    echo "File $1 has been deleted." % [getName(filePathId)]
                inc i
                sleep(arg[2])

template startThread*[W: typedesc[Watchout]](monitor: W, callback: Callback, files: seq[string], ms: int) =
    initLock(l)
    createThread(thr, start, (files, callback, ms))
    # joinThreads(thr)
    deinitLock(l)
