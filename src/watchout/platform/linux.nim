# A stupid simple filesystem monitor.
#
# (c) George Lemon | MIT License
#     Made by humans from OpenPeeps
#     https://gitnub.com/openpeeps/watchout

## watchout/platform/linux.nim — inotify backend for Linux.
##
## All types, constants and handles are pure Nim bindings (importc +
## header pragmas, following powpow/fswatch.nim conventions).
## The watcher thread runs a blocking read() loop in Nim — no C emit
## required because inotify uses simple POSIX I/O (no CFRunLoop).

import std/posix
import std/os

# ── Linker flags ─────────────────────────────────────────────────────────────

{.passL: "-lrt".}

# ── Types ─────────────────────────────────────────────────────────────────────

type
  InotifyEvent {.pure, final.} = object
    wd:     int32
    mask:   uint32
    cookie: uint32
    len:    uint32

  FileChangedCallback* = proc(path: cstring, watcher: pointer) {.cdecl, gcsafe.}

# ── Constants ─────────────────────────────────────────────────────────────────

const
  IN_NONBLOCK*   = 0x800
  IN_MODIFY*     = 0x00000002'u32
  IN_CREATE*     = 0x00000100'u32
  IN_DELETE*     = 0x00000200'u32
  IN_MOVED_FROM* = 0x00000040'u32
  IN_MOVED_TO*   = 0x00000080'u32
  IN_ATTRIB*     = 0x00000004'u32
  IN_DELETE_SELF* = 0x00000400'u32
  IN_MOVE_SELF*  = 0x00000800'u32
  IN_IGNORED*    = 0x00008000'u32
  IN_CLOSE_WRITE* = 0x00000008'u32
  IN_ISDIR*       = 0x40000000'u32

  InWatchMask = IN_MODIFY or IN_CREATE or IN_DELETE or
                IN_MOVED_FROM or IN_MOVED_TO or IN_ATTRIB or IN_CLOSE_WRITE

# ── Imported procs ───────────────────────────────────────────────────────────

proc inotifyInit1(flags: cint): cint {.
  importc: "inotify_init1",
  header: "<sys/inotify.h>".}

proc inotifyAddWatch(fd: cint; path: cstring; mask: uint32): cint {.
  importc: "inotify_add_watch",
  header: "<sys/inotify.h>".}

proc inotifyRmWatch(fd: cint; wd: cint): cint {.
  importc: "inotify_rm_watch",
  header: "<sys/inotify.h>".}

# ── Watcher thread argument (GC-free for safe cross-thread passing) ──────────

type
  WatchDir = object
    wd:   int
    base: string

  WatchThreadArg = object
    dirs:     ptr UncheckedArray[cstring]
    dirCount: int
    cb:       pointer
    watcher:  pointer

proc addWatchRecursive(fd: cint, root: string, maps: var seq[WatchDir]) =
  ## Add an inotify watch for `root` and every subdirectory below it.
  ## inotify watches are not recursive, so each level needs its own watch.
  ## Paths already watched are skipped.
  if not dirExists(root): return
  var dirs = @[root]
  for path in walkDirRec(root, yieldFilter = {pcDir}):
    dirs.add(path)
  for d in dirs:
    var known = false
    for m in maps:
      if m.base == d:
        known = true
        break
    if known: continue
    let wd = inotifyAddWatch(fd, d.cstring, InWatchMask)
    if wd >= 0:
      maps.add(WatchDir(wd: wd.int, base: d))

proc watcherThread(argPtr: ptr WatchThreadArg) {.thread.} =
  let arg = argPtr[]
  let callback = cast[FileChangedCallback](arg.cb)

  let fd = inotifyInit1(0) # blocking mode
  if fd < 0: return

  var maps: seq[WatchDir]
  for i in 0 ..< arg.dirCount:
    addWatchRecursive(fd, $arg.dirs[i], maps)

  if maps.len == 0:
    discard close(fd)
    return

  const bufLen = 8192
  let buf = cast[ptr UncheckedArray[byte]](alloc(bufLen))

  while true:
    let n = read(fd, buf, bufLen)
    if n <= 0: break

    var off = 0
    while off < n:
      let ie = cast[ptr InotifyEvent](addr buf[off])
      if ie.len == 0:
        # No filename attached (e.g. IN_IGNORED when a watched dir is
        # removed): drop the stale watch so a reused wd can't misroute
        # future events. A re-created dir is re-watched via its parent's
        # IN_CREATE | IN_ISDIR event.
        if (ie.mask and IN_IGNORED) != 0:
          for i in 0 ..< maps.len:
            if maps[i].wd == ie.wd.int:
              maps.del(i)
              break
        off += sizeof(InotifyEvent)
        continue
      var base = ""
      for m in maps:
        if m.wd == ie.wd.int:
          base = m.base
          break
      if base.len > 0:
        let name = cast[cstring](addr buf[off + sizeof(InotifyEvent)])
        var path = base
        if path.len > 0 and path[^1] != '/':
          path.add '/'
        path.add $name
        if (ie.mask and IN_ISDIR) != 0:
          # A directory itself changed. New subdirectories (created or
          # moved in) get watched recursively; pre-existing files inside
          # moved-in trees are reported so they are picked up immediately.
          # Nothing is reported for the directory itself.
          if (ie.mask and (IN_CREATE or IN_MOVED_TO)) != 0:
            let before = maps.len
            addWatchRecursive(fd, path, maps)
            if maps.len > before and callback != nil:
              for fpath in walkDirRec(path):
                callback(cstring(fpath), arg.watcher)
        elif callback != nil:
          callback(cstring(path), arg.watcher)
      off += sizeof(InotifyEvent) + ie.len.int

  for m in maps:
    discard inotifyRmWatch(fd, m.wd.cint)
  discard close(fd)
  dealloc(buf)

# ── Public entry point ──────────────────────────────────────────────────────

proc watch*(dirs: seq[string], cb: FileChangedCallback, watcher: pointer) =
  if dirs.len == 0: return
  let cdirs = cast[ptr UncheckedArray[cstring]](alloc0(sizeof(cstring) * dirs.len))
  for i, d in dirs:
    let mem = alloc(d.len + 1)
    if d.len > 0:
      copyMem(mem, unsafeAddr d[0], d.len)
    cast[ptr UncheckedArray[char]](mem)[d.len] = '\0'
    cdirs[i] = cast[cstring](mem)
  let argPtr = cast[ptr WatchThreadArg](alloc0(sizeof(WatchThreadArg)))
  argPtr.dirs = cdirs
  argPtr.dirCount = dirs.len
  argPtr.cb = cast[pointer](cb)
  argPtr.watcher = watcher
  let threadPtr = cast[ptr Thread[ptr WatchThreadArg]](alloc0(sizeof(Thread[ptr WatchThreadArg])))
  createThread(threadPtr[], watcherThread, argPtr)
