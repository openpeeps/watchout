# A stupid simple filesystem monitor.
#
# (c) George Lemon | MIT License
#     Made by humans from OpenPeeps
#     https://gitnub.com/openpeeps/watchout

## watchout/platform/windows.nim — ReadDirectoryChangesW backend for Windows.
##
## All types, constants and handles are pure Nim bindings following
## powpow/platform/iocp.nim conventions (stdcall + dynlib).
## Each watched directory gets its own thread with a blocking
## ReadDirectoryChangesW loop.

# ── Types ─────────────────────────────────────────────────────────────────────

type
  Handle = pointer
  DWORD  = uint32
  BOOL   = int32
  WCHAR  = uint16

  FileChangedCallback* = proc(path: cstring, watcher: pointer) {.cdecl, gcsafe.}

  FILE_NOTIFY_INFORMATION {.importc: "FILE_NOTIFY_INFORMATION",
                            header: "<windows.h>",
                            pure, final.} = object
    NextEntryOffset: DWORD
    Action:           DWORD
    FileNameLength:   DWORD
    FileName:         UncheckedArray[WCHAR]

# ── Constants ─────────────────────────────────────────────────────────────────

const
  FILE_LIST_DIRECTORY         = 0x0001
  FILE_SHARE_READ             = 0x00000001
  FILE_SHARE_WRITE            = 0x00000002
  FILE_SHARE_DELETE           = 0x00000004
  OPEN_EXISTING               = 3
  FILE_FLAG_BACKUP_SEMANTICS  = 0x02000000

  FILE_NOTIFY_CHANGE_FILE_NAME   = 0x00000001
  FILE_NOTIFY_CHANGE_DIR_NAME    = 0x00000002
  FILE_NOTIFY_CHANGE_ATTRIBUTES  = 0x00000004
  FILE_NOTIFY_CHANGE_SIZE        = 0x00000008
  FILE_NOTIFY_CHANGE_LAST_WRITE  = 0x00000010
  FILE_NOTIFY_CHANGE_CREATION    = 0x00000040

  MAX_PATH        = 260
  CP_UTF8         = 65001
  INVALID_HANDLE  = cast[Handle](-1)

# ── Win32 procs ──────────────────────────────────────────────────────────────

proc createFileW(
    lpFileName: pointer,
    dwDesiredAccess: DWORD,
    dwShareMode: DWORD,
    lpSecurityAttributes: pointer,
    dwCreationDisposition: DWORD,
    dwFlagsAndAttributes: DWORD,
    hTemplateFile: Handle
): Handle {.
  importc: "CreateFileW",
  stdcall,
  dynlib: "kernel32".}

proc readDirectoryChangesW(
    hDirectory: Handle,
    lpBuffer: pointer,
    nBufferLength: DWORD,
    bWatchSubtree: BOOL,
    dwNotifyFilter: DWORD,
    lpBytesReturned: ptr DWORD,
    lpOverlapped: pointer,
    lpCompletionRoutine: pointer
): BOOL {.
  importc: "ReadDirectoryChangesW",
  stdcall,
  dynlib: "kernel32".}

proc closeHandle(hObject: Handle): BOOL {.
  importc: "CloseHandle",
  stdcall,
  dynlib: "kernel32".}

proc multiByteToWideChar(
    codePage: DWORD,
    dwFlags: DWORD,
    lpMultiByteStr: cstring,
    cbMultiByte: cint,
    lpWideCharStr: pointer,
    cchWideChar: cint
): cint {.
  importc: "MultiByteToWideChar",
  stdcall,
  dynlib: "kernel32".}

proc wideCharToMultiByte(
    codePage: DWORD,
    dwFlags: DWORD,
    lpWideCharStr: pointer,
    cchWideChar: cint,
    lpMultiByteStr: pointer,
    cbMultiByte: cint,
    lpDefaultChar: pointer,
    lpUsedDefaultChar: pointer
 ): cint {.
  importc: "WideCharToMultiByte",
  stdcall,
  dynlib: "kernel32".}

# ── Thread argument ──────────────────────────────────────────────────────────

type
  WatchThreadArg = object
    dir:     cstring
    cb:      pointer
    watcher: pointer

proc watcherThread(argPtr: ptr WatchThreadArg) {.thread.} =
  try:
    let arg = argPtr[]
    let callback = cast[FileChangedCallback](arg.cb)
    if arg.dir.isNil or callback.isNil:
      return

    # Convert UTF-8 dir to wide string
    var wdir: array[MAX_PATH, WCHAR]
    let wdirLen = multiByteToWideChar(CP_UTF8, 0, arg.dir, -1,
        addr wdir[0], MAX_PATH)
    if wdirLen == 0: return

    let hDir = createFileW(
      addr wdir[0],
      FILE_LIST_DIRECTORY,
      FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
      nil,
      OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS,
      nil
    )
    if hDir == nil or hDir == INVALID_HANDLE: return

    # Use heap for large buffer to avoid thread stack overflow (64 KiB)
    let buffer = cast[ptr UncheckedArray[byte]](alloc(64 * 1024))
    var bytesReturned: DWORD

    while true:
      let ok = readDirectoryChangesW(
        hDir,
        buffer,
        DWORD(64 * 1024),
        1, # TRUE — watch subtree
        FILE_NOTIFY_CHANGE_FILE_NAME or
        FILE_NOTIFY_CHANGE_DIR_NAME or
        FILE_NOTIFY_CHANGE_ATTRIBUTES or
        FILE_NOTIFY_CHANGE_SIZE or
        FILE_NOTIFY_CHANGE_LAST_WRITE or
        FILE_NOTIFY_CHANGE_CREATION,
        addr bytesReturned,
        nil,
        nil
      )
      if ok == 0: break

      var offset = 0
      while offset < int(bytesReturned):
        let fni = cast[ptr FILE_NOTIFY_INFORMATION](addr buffer[offset])
        if fni.FileNameLength == 0 or fni.FileNameLength > DWORD(MAX_PATH * 2):
          if fni.NextEntryOffset == 0: break
          offset += int(fni.NextEntryOffset)
          continue
        let wlen = int(fni.FileNameLength) div sizeof(WCHAR)
        if wlen <= 0 or wlen >= MAX_PATH:
          if fni.NextEntryOffset == 0: break
          offset += int(fni.NextEntryOffset)
          continue

        # Build wide path = dir + separator + filename
        var wpath: array[MAX_PATH, WCHAR]
        var dlen = 0
        while dlen < wdirLen - 1 and dlen < MAX_PATH - 1:
          wpath[dlen] = wdir[dlen]
          inc dlen
        if dlen > 0 and wpath[dlen - 1] != WCHAR('\\'):
          if dlen < MAX_PATH - 1:
            wpath[dlen] = WCHAR('\\')
            inc dlen

        var i = 0
        while i < wlen and dlen < MAX_PATH - 1:
          wpath[dlen] = fni.FileName[i]
          inc dlen
          inc i
        wpath[dlen] = WCHAR(0)

        # Convert back to UTF-8
        var pathUtf8: array[MAX_PATH * 3, byte]
        let utf8Len = wideCharToMultiByte(CP_UTF8, 0, addr wpath[0], -1,
            addr pathUtf8[0], MAX_PATH * 3, nil, nil)
        if utf8Len > 0 and callback != nil:
          {.cast(gcsafe).}:
            callback(cast[cstring](addr pathUtf8[0]), arg.watcher)

        if fni.NextEntryOffset == 0: break
        offset += int(fni.NextEntryOffset)

    dealloc(buffer)
    discard closeHandle(hDir)
  except:
    discard

# ── Public entry point ──────────────────────────────────────────────────────

proc watch*(dirs: seq[string], cb: FileChangedCallback, watcher: pointer) =
  if dirs.len == 0: return
  for d in dirs:
    let cstr = cast[cstring](alloc(d.len + 1))
    if d.len > 0:
      copyMem(cstr, unsafeAddr d[0], d.len)
    cast[ptr UncheckedArray[char]](cstr)[d.len] = '\0'
    let argPtr = cast[ptr WatchThreadArg](alloc0(sizeof(WatchThreadArg)))
    argPtr.dir = cstr
    argPtr.cb = cast[pointer](cb)
    argPtr.watcher = watcher
    # Allocate Thread on heap so its `addr(t)` remains valid after this
    # proc returns — `createThread` passes `addr(t)` to the OS and the new
    # thread dereferences it. A stack-allocated `var thread` would become
    # dangling as soon as `watch` returns, causing AV on Windows.
    let threadPtr = cast[ptr Thread[ptr WatchThreadArg]](alloc0(sizeof(Thread[ptr WatchThreadArg])))
    createThread(threadPtr[], watcherThread, argPtr)
