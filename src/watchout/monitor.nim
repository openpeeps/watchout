# 🐶 A super small, language agnostic
# File System Monitor for development purposes
# 
# MIT License
# Copyright 2022 George Lemon from OpenPeep
# https://github.com/openpeep/watchout

from std/times import Time
from std/os import getLastModificationTime, sleep, fileExists
from std/strutils import `%`
import std/tables

type
    File = object
        path: string
        callback: proc(){.gcsafe, closure.}
        last_modified: Time

    Monitor* = object
        ref_files: seq[string]
        files: OrderedTable[string, File]
        sleepTime: int
        excludeEmptyFiles: bool                    # TODO Exclude monitoring files with no contents
        informEmptyFiles: bool                     # TODO Print a info message in case a file has no contents
    
    FSNotifyException* = object of CatchableError

proc init*[T: typedesc[Monitor]](monitor: T, informEmptyFiles, excludeEmptyFiles = false): Monitor =
    ## Initialize an instance of Monitor object
    Monitor(informEmptyFiles: informEmptyFiles, excludeEmptyFiles: excludeEmptyFiles)

proc addFile*[T: Monitor](monitor: var T, f: string, cb: proc(){.gcsafe, closure.}) =
    ## Add a new file for monitoring live changes with callback procedure
    if f.fileExists():
        if not monitor.files.hasKey(f):
            monitor.files[f] = File(callback: cb, path: f, last_modified: getLastModificationTime(f))
            monitor.ref_files.add(f)
    else: raise newException(FSNotifyException, "File does not exist:\n$1" % [f])

proc start*[T: Monitor](monitor: var T, ms: int) =
    ## Start monitoring over collected files
    var i = 1
    let allFiles = monitor.ref_files.len
    while true:
        if i > allFiles: i = 1
        let filePathID = monitor.ref_files[i - 1]
        var fobj = monitor.files[filePathID]
        if filePathID.fileExists():
            let updateLastModified = getLastModificationTime(fobj.path)
            if fobj.last_modified != updateLastModified:
                fobj.callback()
                fobj.last_modified = updateLastModified
                monitor.files[filePathID] = fobj
        inc i
        sleep(ms)   # time to sleep