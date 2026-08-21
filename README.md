<p align="center">
    <img src="https://raw.githubusercontent.com/openpeep/watchout/main/.github/watchout-logo.png" width="170px"><br>
    A fast, small, lightweight filesystem monitor. Yellin' for changes!
</p>
<p align="center">
  <a href="https://openpeeps.github.io/watchout/theindex.html">API reference</a> | <a href="#">Download</a> (not yet)<br>
  <img src="https://github.com/openpeeps/watchout/workflows/test/badge.svg" alt="Github Actions">  <img src="https://github.com/openpeeps/watchout/workflows/docs/badge.svg" alt="Github Actions">
</p>

## Key Features
- Cross-platform (macOS, Linux, Windows)
- Glob pattern filtering
- Ignore hidden files
- Zero external dependencies

## Installing
```
nimble install watchout
```

## Examples
```nim
import watchout

let w = newWatchout("/path/to/watch")

w.onChange = proc(file: File) =
  echo "Changed: ", file.getName()

w.onDelete = proc(file: File) =
  echo "Deleted: ", file.getName()

w.start()
```

### Pattern filtering
```nim
# Only watch .nim files
let w = newWatchout("/path/to/watch", some("*.nim"))
```

### Multiple directories
```nim
let w = newWatchout(@["/path/a", "/path/b"], some("*.txt"))
```

### Configure hidden file handling
```nim
let w = newWatchout("/path/to/watch")
w.ignoreHidden = false  # Include hidden files
```

## Requirements
- Nim >= 2.0.0

### Contributions & Support
- Found a bug? [Create a new Issue](https://github.com/openpeeps/watchout/issues)
- Wanna help? [Fork it!](https://github.com/openpeeps/watchout/fork)

### License
Watchout [MIT license](https://github.com/openpeeps/watchout/blob/main/LICENSE).<br>
Copyright &copy; 2023 OpenPeeps & Contributors &mdash; All rights reserved.
