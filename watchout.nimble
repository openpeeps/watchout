# Package

version       = "0.3.0"
author        = "George Lemon"
description   = "A stupid simple filesystem monitor"
license       = "MIT"
srcDir        = "src"

# Dependencies

requires "nim >= 2.0.0"

# Testing

task test, "Run tests":
  exec "nim c -r --path:src tests/test_watchout.nim"
