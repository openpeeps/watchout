import watchout/monitor
from std/strutils import `%`
export monitor

# proc watchoutCallback(file: FileObject) {.gcsafe, nimcall.} =
#     echo "\n✨ Watchout is yelling for changes..."
#     echo "\"$1\" has been updated" % [file.getName()]

# proc yelling() =    
#     var monitor = Watchout.init(cleanOutput = false)
#     monitor.addFile("sample.txt")
#     monitor.start(ms = 400, watchoutCallback)