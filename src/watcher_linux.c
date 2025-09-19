// A stupid simple filesystem monitor.
//
//   (c) George Lemon | MIT License
//       Made by humans from OpenPeeps
//       https://gitnub.com/openpeeps/watchout

#include <sys/inotify.h>
#include <unistd.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdio.h>

typedef void (*FileChangedCallback)(char *path, void *watcher);

// Backward compatibility single-dir entry
static void watch_single(char *dir, FileChangedCallback callback, void *watcher) {
    int fd = inotify_init1(0); // blocking
    if (fd < 0) { perror("inotify_init1"); return; }

    int wd = inotify_add_watch(fd, dir,
        IN_CREATE | IN_MODIFY | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO | IN_ATTRIB);
    if (wd < 0) { perror("inotify_add_watch"); close(fd); return; }

    const size_t buf_len = 1024 * (sizeof(struct inotify_event) + NAME_MAX + 1);
    char *buf = (char*)malloc(buf_len);
    if (!buf) { close(fd); return; }

    for (;;) {
        ssize_t len = read(fd, buf, buf_len);
        if (len <= 0) {
            if (len < 0) perror("read");
            break;
        }
        size_t i = 0;
        while (i < (size_t)len) {
            struct inotify_event *ev = (struct inotify_event *)(buf + i);
            if (ev->len > 0) {
                char path[PATH_MAX];
                size_t dlen = strlen(dir);
                if (dlen + 1 + strlen(ev->name) + 1 < sizeof(path)) {
                    strcpy(path, dir);
                    if (dlen > 0 && dir[dlen-1] != '/') strcat(path, "/");
                    strcat(path, ev->name);
                    if (callback) callback(path, watcher);
                }
            }
            i += sizeof(struct inotify_event) + ev->len;
        }
    }
    free(buf);
    close(fd);
}

void watch_path(char *dir, FileChangedCallback callback, void *watcher) {
    watch_single(dir, callback, watcher);
}

void watch_paths(char **dirs, int dirCount, FileChangedCallback callback, void *watcher) {
    if (dirCount <= 0) return;

    int fd = inotify_init1(0); // blocking
    if (fd < 0) { perror("inotify_init1"); return; }

    typedef struct { int wd; char base[PATH_MAX]; } WdMap;
    WdMap *maps = (WdMap*)calloc((size_t)dirCount, sizeof(WdMap));
    if (!maps) { close(fd); return; }

    int added = 0;
    for (int i = 0; i < dirCount; ++i) {
        int wd = inotify_add_watch(fd, dirs[i],
            IN_CREATE | IN_MODIFY | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO | IN_ATTRIB);
        if (wd < 0) { perror("inotify_add_watch"); continue; }
        maps[added].wd = wd;
        strncpy(maps[added].base, dirs[i], sizeof(maps[added].base) - 1);
        maps[added].base[sizeof(maps[added].base) - 1] = '\0';
        added++;
    }
    if (added == 0) { free(maps); close(fd); return; }

    const size_t buf_len = 1024 * (sizeof(struct inotify_event) + NAME_MAX + 1);
    char *buf = (char*)malloc(buf_len);
    if (!buf) { free(maps); close(fd); return; }

    for (;;) {
        ssize_t len = read(fd, buf, buf_len);
        if (len <= 0) {
            if (len < 0) perror("read");
            break;
        }
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
                        if (callback) callback(path, watcher);
                    }
                }
            }
            i += sizeof(struct inotify_event) + ev->len;
        }
    }
    free(buf);
    free(maps);
    close(fd);
}