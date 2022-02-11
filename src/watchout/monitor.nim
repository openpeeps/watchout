# 🐶 A super small, language agnostic
# File System Monitor for development purposes
# 
# MIT License
# Copyright 2022 George Lemon from OpenPeep
# https://github.com/openpeep/watchout

from std/times import Time
from std/os import getLastModificationTime, sleep, fileExists, splitPath, execShellCmd
from std/strutils import `%`, strip, split
from std/osproc import execProcess, poStdErrToStdOut, poUsePath
import std/tables

type
    FileObject* = ref object
        path: string
        callback: proc(file: FileObject){.gcsafe, closure.}
        last_modified: Time

    Watchout* = object
        ref_files: seq[string]
        files: OrderedTable[string, FileObject]
        sleepTime: int
        cleanOutput: bool
    
    FSNotifyException* = object of CatchableError

proc cmd(inputCmd: string, inputArgs: openarray[string]): auto {.discardable.} =
    ## Short hand for executing shell commands via execProcess
    return execProcess(inputCmd, args=inputArgs, options={poStdErrToStdOut, poUsePath})

proc finder*(extensions, excludes, findArgs: seq[string] = @[], path=""): seq[string] {.thread.} =
    ## Recursively search for files.
    ## Optionally, you can set the maximum depth level,
    ## whether to ignore a certain types of files, by extension and/or visibility (dot files)
    ##
    ## This procedure is using `find` for Unix systems, while
    ## on Windows is making use of walkDirRec's Nim iterator and Regex module.
    ## TODO implement excludePaths for both Unix and Windows versions
    ## TODO add support for multiple extensions

    when defined windows:
        var files: seq[string]
        for file in walkDirRec(getCurrentDir()):
            if file.match re".*\.php":
                files.add(file)
        result = files
    else:
        var args: seq[string] = findArgs
        args.insert(path, 0)
        var files = cmd("find", args).strip()
        if files.len == 0: # "Unable to find any files at given location"
            result = @[]
        else:
            result = files.split("\n")

proc init*[T: typedesc[Watchout]](monitor: T, cleanOutput = true): Watchout =
    ## Initialize an instance of Watchout object
    Watchout(cleanOutput: cleanOutput)

proc cleanOutputIfEnabled[T: Watchout](monitor: T) =
    ## Clean previous output in terminal screen
    if monitor.cleanOutput: discard execShellCmd("clear")

proc getPath*[T: FileObject](f: T): string = f.path
proc getName(f: string): string = splitPath(f).tail
proc getName*[T: FileObject](f: T): string = getName(f.path)

proc addFile*[T: Watchout](monitor: var T, f: string, callback: proc(file: FileObject){.gcsafe, closure.}) =
    ## Add a new file for monitoring live changes with callback procedure
    if f.fileExists():
        if not monitor.files.hasKey(f):
            monitor.files[f] = FileObject(callback: callback, path: f, last_modified: getLastModificationTime(f))
            monitor.ref_files.add(f)
        else: raise newException(FSNotifyException, "File has already been monitored once")
    else: raise newException(FSNotifyException, "File does not exist:\n$1" % [f])

proc addDir*[T: Watchout](monitor: var T, dir: string, callback: proc(file: FileObject){.gcsafe, closure.}) =
    ## Add a new directory for monitoring all the files inside it.
    discard

proc removeFile*[T: Watchout](monitor: var T, f: FileObject, callback: proc(){.gcsafe, closure.}) =
    ## Remove a file from current Watchout instance
    ## TODO
    discard

proc start*[T: Watchout](monitor: var T, ms: int) =
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
                monitor.cleanOutputIfEnabled()
                fobj.callback(fobj)
                fobj.last_modified = updateLastModified
                monitor.files[filePathID] = fobj
        else:
            echo "File $1 has been deleted." % [getName(filePathId)]
        inc i
        sleep(ms)   # time to sleep