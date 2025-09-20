// A stupid simple filesystem monitor.
//
//   (c) George Lemon | MIT License
//       Made by humans from OpenPeeps
//       https://gitnub.com/openpeeps/watchout

#import <CoreServices/CoreServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <string.h>
#include <limits.h>
#include <pthread.h>

typedef void (*FileChangedCallback)(char *path, void *watcher);

static FileChangedCallback gCallback = NULL;

typedef struct {
    char **dirs;
    int dirCount;
    FileChangedCallback callback;
    void *watcher;
} WatcherPathsThreadArgs;

void callbackFunc(
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

        // Ignore non-item or administrative events
        if (f & (kFSEventStreamEventFlagHistoryDone |
                 kFSEventStreamEventFlagKernelDropped |
                 kFSEventStreamEventFlagUserDropped |
                 kFSEventStreamEventFlagEventIdsWrapped |
                 kFSEventStreamEventFlagRootChanged |
                 kFSEventStreamEventFlagMount |
                 kFSEventStreamEventFlagUnmount)) {
            continue;
        }

        // Only care about files (skip directory-only notifications)
        if (!(f & kFSEventStreamEventFlagItemIsFile)) continue;

        // Only forward create/remove/modify/rename
        if (!(f & (kFSEventStreamEventFlagItemCreated |
                   kFSEventStreamEventFlagItemRemoved |
                   kFSEventStreamEventFlagItemRenamed |
                   kFSEventStreamEventFlagItemModified))) {
            continue;
        }

        if (gCallback) gCallback(paths[i], clientCallBackInfo);
    }
}

void *watcher_paths_thread_func(void *arg) {
    WatcherPathsThreadArgs *args = (WatcherPathsThreadArgs *)arg;
    gCallback = args->callback;

    if (args->dirCount <= 0) {
        free(args->dirs);
        free(args);
        return NULL;
    }

    CFMutableArrayRef pathsToWatch = CFArrayCreateMutable(NULL, args->dirCount, &kCFTypeArrayCallBacks);
    if (!pathsToWatch) {
        free(args->dirs);
        free(args);
        return NULL;
    }

    for (int i = 0; i < args->dirCount; ++i) {
        CFStringRef path = CFStringCreateWithCString(NULL, args->dirs[i], kCFStringEncodingUTF8);
        if (path) {
            CFArrayAppendValue(pathsToWatch, path);
            CFRelease(path);
        }
    }

    FSEventStreamContext context = (FSEventStreamContext){0, args->watcher, NULL, NULL, NULL};
    FSEventStreamRef stream = FSEventStreamCreate(
        NULL,
        &callbackFunc,
        &context,
        pathsToWatch,
        kFSEventStreamEventIdSinceNow,
        0.5,
        kFSEventStreamCreateFlagFileEvents |
        kFSEventStreamCreateFlagIgnoreSelf
    );

    FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    FSEventStreamStart(stream);
    CFRunLoopRun();

    CFRelease(pathsToWatch);
    FSEventStreamInvalidate(stream);
    FSEventStreamRelease(stream);

    for (int i = 0; i < args->dirCount; ++i) {
        free(args->dirs[i]);
    }
    free(args->dirs);
    free(args);
    return NULL;
}

void watch_paths(char **dirs, int dirCount, FileChangedCallback callback, void *watcher) {
    pthread_t tid;
    WatcherPathsThreadArgs *args = malloc(sizeof(WatcherPathsThreadArgs));
    args->dirCount = dirCount;
    args->callback = callback;
    args->watcher = watcher;
    args->dirs = malloc(sizeof(char *) * dirCount);
    for (int i = 0; i < dirCount; ++i) {
        args->dirs[i] = strdup(dirs[i]);
    }
    pthread_create(&tid, NULL, watcher_paths_thread_func, args);
    pthread_detach(tid);
}