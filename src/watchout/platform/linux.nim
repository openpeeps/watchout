# watchout - Linux inotify backend
#
# Uses inline C via emit for the threaded watcher loop.

{.passL: "-lrt".}

type FileChangedCallback* = proc(path: cstring, watcher: pointer) {.cdecl.}

{.emit: """
#include <sys/inotify.h>
#include <unistd.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

typedef void (*WatchCallback)(const char *path, void *watcher);

static WatchCallback gCallback = NULL;

typedef struct { int wd; char base[PATH_MAX]; } WdMap;

static void *watcher_thread(void *arg) {
    char **dirs = ((char ***)arg)[0];
    int dirCount = ((int *)(((char ***)arg) + 1))[0];
    void *watcher = ((char ***)arg)[1];

    if (dirCount <= 0) {
        free(arg);
        return NULL;
    }

    int fd = inotify_init1(0);
    if (fd < 0) { free(arg); return NULL; }

    WdMap *maps = (WdMap *)calloc((size_t)dirCount, sizeof(WdMap));
    if (!maps) { close(fd); free(arg); return NULL; }

    int added = 0;
    for (int i = 0; i < dirCount; ++i) {
        int wd = inotify_add_watch(fd, dirs[i],
            IN_CREATE | IN_MODIFY | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO | IN_ATTRIB);
        if (wd < 0) continue;
        maps[added].wd = wd;
        strncpy(maps[added].base, dirs[i], sizeof(maps[added].base) - 1);
        maps[added].base[sizeof(maps[added].base) - 1] = '\\0';
        added++;
    }
    if (added == 0) { free(maps); close(fd); free(arg); return NULL; }

    const size_t buf_len = 1024 * (sizeof(struct inotify_event) + NAME_MAX + 1);
    char *buf = (char *)malloc(buf_len);
    if (!buf) { free(maps); close(fd); free(arg); return NULL; }

    for (;;) {
        ssize_t len = read(fd, buf, buf_len);
        if (len <= 0) break;
        size_t i = 0;
        while (i < (size_t)len) {
            struct inotify_event *ev = (struct inotify_event *)(buf + i);
            if (ev->len > 0) {
                const char *base = NULL;
                for (int j = 0; j < added; ++j) {
                    if (maps[j].wd == ev->wd) { base = maps[j].base; break; }
                }
                if (base) {
                    char path[PATH_MAX];
                    size_t dlen = strlen(base);
                    if (dlen + 1 + strlen(ev->name) + 1 < sizeof(path)) {
                        strcpy(path, base);
                        if (dlen > 0 && base[dlen-1] != '/') strcat(path, "/");
                        strcat(path, ev->name);
                        if (gCallback) gCallback(path, watcher);
                    }
                }
            }
            i += sizeof(struct inotify_event) + ev->len;
        }
    }
    free(buf);
    free(maps);
    free(arg);
    close(fd);
    return NULL;
}

typedef struct {
    char **dirs;
    int dirCount;
    void *watcher;
} WatcherArgs;

void watch_paths(char **dirs, int dirCount, void *cb, void *watcher) {
    gCallback = (WatchCallback)cb;
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

proc watch*(dirs: seq[string], cb: FileChangedCallback, watcher: pointer) =
  if dirs.len == 0: return
  var cpaths = newSeq[cstring](dirs.len)
  for i, d in dirs:
    cpaths[i] = cstring(d)
  watchPaths(addr cpaths[0], cint(dirs.len), cast[pointer](cb), watcher)
