// A stupid simple filesystem monitor.
//
//   (c) George Lemon | MIT License
//       Made by humans from OpenPeeps
//       https://gitnub.com/openpeeps/watchout

#import <CoreServices/CoreServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <string.h>
#include <limits.h>

typedef void (*FileChangedCallback)(char *path, void *watcher);

static FileChangedCallback gCallback = NULL;

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

void watch_path(char *dir, FileChangedCallback callback, void *watcher) {
  gCallback = callback;
  CFStringRef path = CFStringCreateWithCString(NULL, dir, kCFStringEncodingUTF8);
  CFArrayRef pathsToWatch = CFArrayCreate(NULL, (const void **)&path, 1, NULL);

  FSEventStreamContext context = (FSEventStreamContext){0, watcher, NULL, NULL, NULL};
  FSEventStreamRef stream = FSEventStreamCreate(
      NULL,
      &callbackFunc,
      &context,
      pathsToWatch,
      kFSEventStreamEventIdSinceNow,
      0.5, // latency (coalescing window)
      kFSEventStreamCreateFlagFileEvents |
      kFSEventStreamCreateFlagIgnoreSelf // avoid self-generated events
  );

  FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
  FSEventStreamStart(stream);
  CFRunLoopRun();
}

void watch_paths(char **dirs, int dirCount, FileChangedCallback callback, void *watcher) {
  gCallback = callback;

  if (dirCount <= 0) return;

  CFMutableArrayRef pathsToWatch = CFArrayCreateMutable(NULL, dirCount, &kCFTypeArrayCallBacks);
  if (!pathsToWatch) return;

  for (int i = 0; i < dirCount; ++i) {
    CFStringRef path = CFStringCreateWithCString(NULL, dirs[i], kCFStringEncodingUTF8);
    if (path) {
      CFArrayAppendValue(pathsToWatch, path);
      CFRelease(path);
    }
  }

  FSEventStreamContext context = (FSEventStreamContext){0, watcher, NULL, NULL, NULL};
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

  CFRelease(pathsToWatch);

  FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
  FSEventStreamStart(stream);
  CFRunLoopRun();
}