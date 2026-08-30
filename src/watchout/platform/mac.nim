# A stupid simple filesystem monitor.
#
# (c) George Lemon | MIT License
#     Made by humans from OpenPeeps
#     https://gitnub.com/openpeeps/watchout

## watchout/platform/mac.nim — FSEvents backend for macOS.
##
## All types, constants and handles are declared as pure Nim bindings
## (importc + header pragmas). The watcher thread itself is a small
## C function via a single emit block because CoreFoundation's
## CFRunLoop must run inside a C calling context — Nim's ORC
## frame-tracking crashes when a Nim {.thread.} proc is called from
## CoreFoundation's dispatch path.

import std/os

# ── Linker flags ─────────────────────────────────────────────────────────────

{.passL: "-framework CoreServices -framework CoreFoundation".}

# ── Types ─────────────────────────────────────────────────────────────────────

type
  CFIndex* = clong

  FSEventStreamEventFlags* = uint32
  FSEventStreamEventId* = uint64

  FileChangedCallback* = proc(path: cstring, watcher: pointer) {.cdecl, gcsafe.}

  FSEventStreamContext {.pure, final.} = object
    version*:          CFIndex
    info*:             pointer
    retain*:           pointer
    release*:          pointer
    copyDescription*:  pointer

  CFArrayCallBacks {.importc, header: "<CoreFoundation/CFArray.h>",
                     pure, final.} = object

# ── FSEvents constants ───────────────────────────────────────────────────────

const
  kCFStringEncodingUTF8* = 0x08000100'u32
  kFSEventStreamEventIdSinceNow* = 0xFFFFFFFFFFFFFFFF'u64
  kFSEventStreamCreateFlagFileEvents* = 0x00000010'u32
  # kFSEventStreamCreateFlagIgnoreSelf = 0x00000002
  # Removed: self-generated events must be observed for tests and same-process monitoring

  kFSEventStreamEventFlagItemIsFile*   = 0x00000010
  kFSEventStreamEventFlagItemCreated*  = 0x00000100
  kFSEventStreamEventFlagItemRemoved*  = 0x00000200
  kFSEventStreamEventFlagItemRenamed*  = 0x00000400
  kFSEventStreamEventFlagItemModified* = 0x00000800

# ── Imported vars ────────────────────────────────────────────────────────────

var
  kCFRunLoopDefaultMode {.importc,
      header: "<CoreFoundation/CoreFoundation.h>".}: pointer
  kCFTypeArrayCallBacks {.importc,
      header: "<CoreFoundation/CFArray.h>".}: CFArrayCallBacks

# ── C watcher thread (emit — the only C body) ────────────────────────────────
#
# Types and constants above are pure Nim bindings. The watcher thread
# below is the single emit block: it runs the CFRunLoop, filters
# events, and dispatches through the raw callback pointer.

{.emit: """
#include <CoreServices/CoreServices.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

typedef void (*FileChangedCB)(char *path, void *watcher);
static FileChangedCB gCB = NULL;

typedef struct {
    char **dirs;
    int dirCount;
    void *watcher;
} WatcherArgs;

static void fseventCallback(
    ConstFSEventStreamRef streamRef,
    void *clientCallBackInfo,
    size_t numEvents,
    void *eventPaths,
    const FSEventStreamEventFlags eventFlags[],
    const FSEventStreamEventId eventIds[]
) {
    char **paths = eventPaths;
    unsigned int ignoreMask =
        kFSEventStreamEventFlagHistoryDone |
        kFSEventStreamEventFlagKernelDropped |
        kFSEventStreamEventFlagUserDropped |
        kFSEventStreamEventFlagEventIdsWrapped |
        kFSEventStreamEventFlagRootChanged |
        kFSEventStreamEventFlagMount |
        kFSEventStreamEventFlagUnmount;
    unsigned int itemMask =
        kFSEventStreamEventFlagItemCreated |
        kFSEventStreamEventFlagItemRemoved |
        kFSEventStreamEventFlagItemRenamed |
        kFSEventStreamEventFlagItemModified;
    for (size_t i = 0; i < numEvents; ++i) {
        unsigned int f = eventFlags[i];
        if (f & ignoreMask) continue;
        if (!(f & kFSEventStreamEventFlagItemIsFile)) continue;
        if ((f & itemMask) == 0) continue;
        #ifdef DEBUG_FS
        fprintf(stderr, "[fsevent] path=%s flags=0x%x\n", paths[i], f);
        fflush(stderr);
        #endif
        if (gCB) gCB(paths[i], clientCallBackInfo);
    }
}

static void *watcher_thread(void *arg) {
    WatcherArgs *args = (WatcherArgs *)arg;
    if (args->dirCount <= 0) {
        free(args->dirs);
        free(args);
        return NULL;
    }

    CFMutableArrayRef pathsToWatch = CFArrayCreateMutable(
        NULL, args->dirCount, &kCFTypeArrayCallBacks);
    for (int i = 0; i < args->dirCount; ++i) {
        CFStringRef path = CFStringCreateWithCString(
            NULL, args->dirs[i], kCFStringEncodingUTF8);
        if (path) {
            CFArrayAppendValue(pathsToWatch, path);
            CFRelease(path);
        }
    }

    FSEventStreamContext context = {0, args->watcher, NULL, NULL, NULL};
    FSEventStreamRef stream = FSEventStreamCreate(
        NULL,
        &fseventCallback,
        &context,
        pathsToWatch,
        kFSEventStreamEventIdSinceNow,
        0.05,
        kFSEventStreamCreateFlagFileEvents
    );

    if (!stream) {
        fprintf(stderr, "[watchout] FSEventStreamCreate FAILED\n");
        fflush(stderr);
        CFRelease(pathsToWatch);
        free(args->dirs);
        free(args);
        return NULL;
    }

    FSEventStreamScheduleWithRunLoop(
        stream, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    FSEventStreamStart(stream);
    CFRunLoopRun();

    FSEventStreamStop(stream);
    FSEventStreamInvalidate(stream);
    FSEventStreamRelease(stream);
    CFRelease(pathsToWatch);

    for (int i = 0; i < args->dirCount; ++i) free(args->dirs[i]);
    free(args->dirs);
    free(args);
    return NULL;
}

void watch_paths(char **dirs, int dirCount, void *cb, void *watcher) {
    gCB = (FileChangedCB)cb;
    if (dirCount <= 0) return;
    WatcherArgs *args = (WatcherArgs *)malloc(sizeof(WatcherArgs));
    args->dirCount = dirCount;
    args->watcher  = watcher;
    args->dirs     = (char **)malloc(sizeof(char *) * dirCount);
    for (int i = 0; i < dirCount; ++i) args->dirs[i] = strdup(dirs[i]);
    pthread_t tid;
    pthread_create(&tid, NULL, watcher_thread, args);
    pthread_detach(tid);
}
""".}

proc watchPaths(dirs: ptr cstring, dirCount: cint, cb: pointer,
    watcher: pointer) {.
  importc: "watch_paths".}

# ── Public entry point ──────────────────────────────────────────────────────

proc watch*(dirs: seq[string], cb: FileChangedCallback, watcher: pointer) =
  if dirs.len == 0: return

  # Allocate C strings outside the GC (safe to pass across threads)
  # Use absolute paths so CoreServices resolves them correctly
  let cstrings = cast[ptr UncheckedArray[cstring]](
    alloc0(sizeof(cstring) * dirs.len))
  for i, d in dirs:
    let abs = absolutePath(d)
    let buf = alloc(abs.len + 1)
    copyMem(buf, unsafeAddr abs[0], abs.len)
    cast[ptr UncheckedArray[char]](buf)[abs.len] = '\0'
    cstrings[i] = cast[cstring](buf)

  watchPaths(addr cstrings[0], cint(dirs.len), cast[pointer](cb), watcher)
