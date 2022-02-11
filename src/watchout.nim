# import klymene
import watchout/monitor
from std/os import execShellCmd
from std/strutils import `%`

export monitor

proc yelling() =
    proc watchoutCallback(file: FileObject) {.gcsafe, closure.} =
        discard execShellCmd("clear")                           # TODO Watchout for "cleanScreen"
        echo "✨ Watchout is yelling for changes..."
        echo "\"$1\" has been updated" % [file.getName()]
    
    var monitor = Watchout.init()
    monitor.addFile("sample.txt", watchoutCallback)
    monitor.start(ms = 400)

when isMainModule:
    # TODO implement klymene for CLI usage
    # and calls from other programming languages
    # 
    # TODO separate CLI version from Nim library
    # via nimble flags
    yelling()