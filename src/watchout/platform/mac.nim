# watchout - macOS FSEvents backend
#
# Uses inline C via emit, similar to the original watcher_macos.c
# but compiled as part of the Nim compilation unit.

{.emit: """
#include <CoreServices/CoreServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <pthread.h>
#include <string.h>
#include <stdlib.h>

typedef void (*WatchCallback)(const char *path, void *watcher);

static WatchCallback gCallback = NULL;
static void *gWatcher = NULL;

static void fseventCallback(
    ConstFSEventStreamRef streamRef,
    void *clientCallBackInfo,
    size_t numEvents,
    void *eventPaths,
    const FSEventStreamEventFlags eventFlags[],
    const FSEventStreamEventId eventIds[]
) {
    char **paths = eventPaths;
    for (size_t i = 0; i < numEvents; ++i) {
        FSEventStreamEventFlags f = eventFlags[i];
        if (f & (kFSEventStreamEventFlagHistoryDone |
                 kFSEventStreamEventFlagKernelDropped |
                 kFSEventStreamEventFlagUserDropped |
                 kFSEventStreamEventFlagEventIdsWrapped |
                 kFSEventStreamEventFlagRootChanged |
                 kFSEventStreamEventFlagMount |
                 kFSEventStreamEventFlagUnmount)) {
            continue;
        }
        if (!(f & kFSEventStreamEventFlagItemIsFile)) continue;
        if (!(f & (kFSEventStreamEventFlagItemCreated |
                   kFSEventStreamEventFlagItemRemoved |
                   kFSEventStreamEventFlagItemRenamed |
                   kFSEventStreamEventFlagItemModified))) {
            continue;
        }
        if (gCallback) gCallback(paths[i], clientCallBackInfo);
    }
}

typedef struct {
    char **dirs;
    int dirCount;
    void *watcher;
} WatcherArgs;

static void *watcher_thread(void *arg) {
    WatcherArgs *args = (WatcherArgs *)arg;
    if (args->dirCount <= 0) {
        free(args->dirs);
        free(args);
        return NULL;
    }

    CFMutableArrayRef pathsToWatch = CFArrayCreateMutable(NULL, args->dirCount, &kCFTypeArrayCallBacks);
    for (int i = 0; i < args->dirCount; ++i) {
        CFStringRef path = CFStringCreateWithCString(NULL, args->dirs[i], kCFStringEncodingUTF8);
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
        0.5,
        kFSEventStreamCreateFlagFileEvents |
        kFSEventStreamCreateFlagIgnoreSelf
    );

    if (!stream) {
        CFRelease(pathsToWatch);
        free(args->dirs);
        free(args);
        return NULL;
    }

    FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    FSEventStreamStart(stream);
    CFRunLoopRun();

    FSEventStreamInvalidate(stream);
    FSEventStreamRelease(stream);
    CFRelease(pathsToWatch);

    for (int i = 0; i < args->dirCount; ++i) {
        free(args->dirs[i]);
    }
    free(args->dirs);
    free(args);
    return NULL;
}

void watch_paths(char **dirs, int dirCount, void *cb, void *watcher) {
    gCallback = (WatchCallback)cb;
    gWatcher = watcher;
    if (dirCount <= 0) return;

    WatcherArgs *args = (WatcherArgs *)malloc(sizeof(WatcherArgs));
    args->dirCount = dirCount;
    args->watcher = watcher;
    args->dirs = (char **)malloc(sizeof(char *) * dirCount);
    for (int i = 0; i < dirCount; ++i) {
        args->dirs[i] = strdup(dirs[i]);
    }

    pthread_t tid;
    pthread_create(&tid, NULL, watcher_thread, args);
    pthread_detach(tid);
}
""".}

proc watchPaths(dirs: ptr cstring, dirCount: cint, cb: pointer,
                watcher: pointer) {.cdecl, importc: "watch_paths".}

type FileChangedCallback* = proc(path: cstring, watcher: pointer) {.cdecl.}

proc watch*(dirs: seq[string], cb: FileChangedCallback, watcher: pointer) =
  if dirs.len == 0: return
  var cpaths = newSeq[cstring](dirs.len)
  for i, d in dirs:
    cpaths[i] = cstring(d)
  watchPaths(addr cpaths[0], cint(dirs.len), cast[pointer](cb), watcher)
