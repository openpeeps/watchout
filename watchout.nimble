# Package

version       = "0.1.0"
author        = "George Lemon"
description   = "⚡️ Just... yellin' for changes! File System Monitor for devs"
license       = "MIT"
srcDir        = "src"
bin           = @["watchout"]
binDir        = "bin"

# Dependencies

requires "nim >= 1.6.0"


task dev, "Compile for development":
    echo "\n✨ Compiling for dev" & "\n"
    exec "nimble build --gc:arc -d:useMalloc"