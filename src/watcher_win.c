// A stupid simple filesystem monitor.
//
//   (c) George Lemon | MIT License
//       Made by humans from OpenPeeps
//       https://gitnub.com/openpeeps/watchout

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wchar.h>

typedef void (*FileChangedCallback)(char *path, void *watcher);

static int utf8_to_wide(const char *src, wchar_t *dst, int dstLen) {
    return MultiByteToWideChar(CP_UTF8, 0, src, -1, dst, dstLen);
}
static int wide_to_utf8(const wchar_t *src, char *dst, int dstLen) {
    return WideCharToMultiByte(CP_UTF8, 0, src, -1, dst, dstLen, NULL, NULL);
}

typedef struct {
    char dir[MAX_PATH * 3];
    FileChangedCallback cb;
    void *watcher;
} WatchThreadArg;

static DWORD WINAPI watch_thread_proc(LPVOID param) {
    WatchThreadArg *arg = (WatchThreadArg*)param;

    wchar_t wdir[MAX_PATH];
    if (!utf8_to_wide(arg->dir, wdir, MAX_PATH)) { free(arg); return 0; }

    HANDLE hDir = CreateFileW(
        wdir,
        FILE_LIST_DIRECTORY,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL,
        OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS,
        NULL
    );
    if (hDir == INVALID_HANDLE_VALUE) { free(arg); return 0; }

    BYTE buffer[64 * 1024];
    DWORD bytesReturned;

    for (;;) {
        if (!ReadDirectoryChangesW(
            hDir,
            buffer,
            sizeof(buffer),
            TRUE,
            FILE_NOTIFY_CHANGE_FILE_NAME |
            FILE_NOTIFY_CHANGE_DIR_NAME  |
            FILE_NOTIFY_CHANGE_ATTRIBUTES|
            FILE_NOTIFY_CHANGE_SIZE      |
            FILE_NOTIFY_CHANGE_LAST_WRITE|
            FILE_NOTIFY_CHANGE_CREATION,
            &bytesReturned,
            NULL,
            NULL
        )) {
            break;
        }

        BYTE *ptr = buffer;
        for (;;) {
            FILE_NOTIFY_INFORMATION *fni = (FILE_NOTIFY_INFORMATION*)ptr;

            int wlen = (int)(fni->FileNameLength / sizeof(WCHAR));
            wchar_t wpath[MAX_PATH];
            wcsncpy(wpath, wdir, MAX_PATH - 1);
            wpath[MAX_PATH - 1] = L'\0';
            size_t dlen = wcslen(wpath);
            if (dlen > 0 && wpath[dlen-1] != L'\\') {
                if (dlen + 1 < MAX_PATH) { wpath[dlen++] = L'\\'; wpath[dlen] = L'\0'; }
            }
            if ((int)dlen + wlen < MAX_PATH) {
                wmemcpy(wpath + dlen, fni->FileName, wlen);
                wpath[dlen + wlen] = L'\0';
                char pathUtf8[MAX_PATH * 3];
                if (wide_to_utf8(wpath, pathUtf8, (int)sizeof(pathUtf8)) && arg->cb) {
                    arg->cb(pathUtf8, arg->watcher);
                }
            }

            if (fni->NextEntryOffset == 0) break;
            ptr += fni->NextEntryOffset;
        }
    }

    CloseHandle(hDir);
    free(arg);
    return 0;
}

void watch_paths(char **dirs, int dirCount, FileChangedCallback callback, void *watcher) {
    if (dirCount <= 0) return;
    for (int i = 0; i < dirCount; ++i) {
        WatchThreadArg *arg = (WatchThreadArg*)malloc(sizeof(WatchThreadArg));
        if (!arg) continue;
        lstrcpynA(arg->dir, dirs[i], sizeof(arg->dir));
        arg->cb = callback;
        arg->watcher = watcher;
        HANDLE t = CreateThread(NULL, 0, watch_thread_proc, arg, 0, NULL);
        if (t) {
            CloseHandle(t); // Detach thread, don't block main thread
        } else {
            free(arg);
        }
    }
}