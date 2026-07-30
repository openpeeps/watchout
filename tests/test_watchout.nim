import unittest
import std/[os, times, strutils, random, options, osproc]
import watchout

randomize()

proc tempDir: string =
  result = getTempDir() / "watchout_test_" & $rand(high(int))
  createDir(result)

proc spTouch(path: string) =
  discard execCmd("touch " & path.quoteShell)

proc spDelete(path: string) =
  discard execCmd("rm " & path.quoteShell)

suite "Watchout API":
  test "newWatchout with single directory":
    let w = newWatchout(getCurrentDir())
    check w.srcDirs.len == 1
    check w.srcDirs[0] == getCurrentDir()
    check w.pattern == none(string)
    check w.ignoreHidden == true

  test "newWatchout with multiple directories":
    let d1 = tempDir()
    let d2 = tempDir()
    defer: removeDir(d1); removeDir(d2)
    let dirs = @[d1, d2]
    let w = newWatchout(dirs)
    check w.srcDirs == dirs

  test "newWatchout with pattern":
    let w = newWatchout(getCurrentDir(), some("*.nim"))
    check w.pattern == some("*.nim")

  test "newWatchout with empty seq":
    let w = newWatchout(newSeq[string]())
    check w.srcDirs.len == 0
    check w.pattern == none(string)

  test "Watchout defaults":
    let w = newWatchout(getCurrentDir())
    check w.ignoreHidden == true
    check w.onChange.isNil
    check w.onFound.isNil
    check w.onDelete.isNil

suite "Event handling":
  test "new file fires onChange":
    let d = tempDir()
    defer: removeDir(d)
    let f = d / "test.txt"
    writeFile(f, "hello")
    let w = newWatchout(d)
    var changed: seq[watchout.File] = @[]
    w.onChange = proc(f: watchout.File) = changed.add(f)
    handleEvent(w, f)
    check changed.len == 1
    check getPath(changed[0]) == f

  test "modified file fires onChange":
    let d = tempDir()
    defer: removeDir(d)
    let f = d / "test.txt"
    writeFile(f, "hello")
    let w = newWatchout(d)
    var changeCount = 0
    w.onChange = proc(f: watchout.File) = changeCount += 1
    handleEvent(w, f)
    check changeCount == 1
    sleep(1001)
    writeFile(f, "modified")
    handleEvent(w, f)
    check changeCount == 2

  test "unchanged file does not fire onChange again":
    let d = tempDir()
    defer: removeDir(d)
    let f = d / "test.txt"
    writeFile(f, "hello")
    let w = newWatchout(d)
    var changeCount = 0
    w.onChange = proc(f: watchout.File) = changeCount += 1
    handleEvent(w, f)
    handleEvent(w, f)
    check changeCount == 1

  test "getName and getPath from callback":
    let d = tempDir()
    defer: removeDir(d)
    let f = d / "mylib.nim"
    writeFile(f, "code")
    let w = newWatchout(d)
    var captured: watchout.File
    w.onChange = proc(f: watchout.File) = captured = f
    handleEvent(w, f)
    check getPath(captured) == f
    check getName(captured) == "mylib.nim"

  test "deleted file fires onDelete":
    let d = tempDir()
    defer: removeDir(d)
    let f = d / "test.txt"
    writeFile(f, "hello")
    let w = newWatchout(d)
    var deleted: seq[watchout.File] = @[]
    w.onDelete = proc(f: watchout.File) = deleted.add(f)
    handleEvent(w, f)
    removeFile(f)
    handleEvent(w, f)
    check deleted.len == 1
    check getPath(deleted[0]) == f

  test "deleted file is removed from tracking":
    let d = tempDir()
    defer: removeDir(d)
    let f = d / "test.txt"
    writeFile(f, "hello")
    let w = newWatchout(d)
    var changeCount = 0
    var deleteCount = 0
    w.onChange = proc(f: watchout.File) = changeCount += 1
    w.onDelete = proc(f: watchout.File) = deleteCount += 1
    handleEvent(w, f)
    check changeCount == 1
    removeFile(f)
    handleEvent(w, f)
    check deleteCount == 1
    handleEvent(w, f)
    check changeCount == 1
    check deleteCount == 1

  test "non-existent untracked file does nothing":
    let d = tempDir()
    defer: removeDir(d)
    let f = d / "nonexistent.txt"
    let w = newWatchout(d)
    var called = false
    w.onChange = proc(f: watchout.File) = called = true
    w.onDelete = proc(f: watchout.File) = called = true
    handleEvent(w, f)
    check not called

  test "nil callbacks do not crash":
    let d = tempDir()
    defer: removeDir(d)
    let f = d / "test.txt"
    writeFile(f, "hello")
    let w = newWatchout(d)
    handleEvent(w, f)
    removeFile(f)
    handleEvent(w, f)
    check true

  test "onFound is never called":
    let d = tempDir()
    defer: removeDir(d)
    let f = d / "test.txt"
    writeFile(f, "hello")
    let w = newWatchout(d)
    var foundCalled = false
    w.onFound = proc(f: watchout.File) = foundCalled = true
    w.onChange = proc(f: watchout.File) = discard
    handleEvent(w, f)
    check not foundCalled

suite "Watcher integration":
  test "start with empty dirs returns immediately":
    let w = newWatchout(newSeq[string]())
    var called = false
    w.onChange = proc(f: watchout.File) = called = true
    w.start()
    check not called

  test "detects file creation":
    let d = tempDir()
    defer:
      try: removeDir(d)
      except: discard
    let w = newWatchout(d)
    var changed: seq[watchout.File] = @[]
    w.onChange = proc(f: watchout.File) = changed.add(f)
    w.start()
    sleep(1000)
    let f = d / "newfile.txt"
    spTouch(f)
    let deadline = epochTime() + 8.0
    while changed.len == 0 and epochTime() < deadline:
      sleep(50)
    check changed.len > 0
    check getName(changed[0]) == "newfile.txt"

  test "detects file modification":
    let d = tempDir()
    defer:
      try: removeDir(d)
      except: discard
    let f = d / "modfile.txt"
    spTouch(f)
    let w = newWatchout(d)
    var changeCount = 0
    w.onChange = proc(f: watchout.File) = changeCount += 1
    w.start()
    sleep(1000)
    spTouch(f)
    let deadline = epochTime() + 8.0
    while changeCount < 2 and epochTime() < deadline:
      sleep(50)
    check changeCount >= 2

  test "detects file deletion":
    let d = tempDir()
    defer:
      try: removeDir(d)
      except: discard
    let f = d / "delfile.txt"
    spTouch(f)
    let w = newWatchout(d)
    var deleted: seq[watchout.File] = @[]
    w.onDelete = proc(f: watchout.File) = deleted.add(f)
    w.start()
    sleep(1000)
    spDelete(f)
    let deadline = epochTime() + 8.0
    while deleted.len == 0 and epochTime() < deadline:
      sleep(50)
    check deleted.len > 0
    check getName(deleted[0]) == "delfile.txt"

  when defined(linux):
    test "Linux: subdirectory content is NOT watched (non-recursive)":
      let d = tempDir()
      defer:
        try: removeDir(d)
        except: discard
      let w = newWatchout(d)
      var detected: seq[string] = @[]
      w.onChange = proc(f: watchout.File) = detected.add(getPath(f))
      w.start()
      sleep(1000)
      let subdir = d / "subdir"
      createDir(subdir)
      sleep(500)
      let subfile = subdir / "subfile.txt"
      spTouch(subfile)
      sleep(3000)
      check subfile notin detected
  else:
    test "macOS/Windows: subdirectory content IS watched (recursive)":
      let d = tempDir()
      defer:
        try: removeDir(d)
        except: discard
      let w = newWatchout(d)
      var detected: seq[string] = @[]
      w.onChange = proc(f: watchout.File) = detected.add(getPath(f))
      w.start()
      sleep(1000)
      let subdir = d / "subdir"
      createDir(subdir)
      sleep(500)
      let subfile = subdir / "subfile.txt"
      spTouch(subfile)
      let deadline = epochTime() + 8.0
      var found = false
      while not found and epochTime() < deadline:
        for p in detected:
          if p.endsWith("subfile.txt"):
            found = true
            break
        if not found:
          sleep(50)
      check found
