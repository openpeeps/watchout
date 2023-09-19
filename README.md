<p align="center">
    <img src="https://raw.githubusercontent.com/openpeep/watchout/main/.github/watchout-logo.png" width="170px"><br>
    🐕 Fast, small, language agnostic <strong>File System Monitor for devs</strong><br>
    ⚡️ Just... yellin' for changes! (WIP)
</p>
<p align="center">
  <a href="https://openpeeps.github.io/watchout/theindex.html">API reference</a> | <a href="#">Download</a> (not yet)<br>
  <img src="https://github.com/openpeeps/watchout/workflows/test/badge.svg" alt="Github Actions">  <img src="https://github.com/openpeeps/watchout/workflows/docs/badge.svg" alt="Github Actions">
</p>

## 😍 Key Features
todo
- [x] Open Source | `MIT` license

## Installing
```
nimble install watchout
```

## Examples
```nim
import watchout

proc onFound(file: File) =
  echo "Found"
  echo file.getPath

proc onChange(file: File) =
  echo "Changed"
  echo file.getPath

proc onDelete(file: File) =
  echo "Deleted"
  echo file.getPath

var w = newWatchout("../tests/*.nim", onChange, onFound, onDelete)
w.start(waitThreads = true)
```


### ❤ Contributions & Support
- 🐛 Found a bug? [Create a new Issue](https://github.com/openpeeps/watchout/issues)
- 👋 Wanna help? [Fork it!](https://github.com/openpeeps/watchout/fork)
- Create a Syntax Highlighter for your favorite code editor. 
- 😎 [Get €20 in cloud credits from Hetzner](https://hetzner.cloud/?ref=Hm0mYGM9NxZ4)
- 🥰 [Donate to OpenPeeps via PayPal address](https://www.paypal.com/donate/?hosted_button_id=RJK3ZTDWPL55C)

### 🎩 License
Watchout [MIT license](https://github.com/openpeeps/watchout/blob/main/LICENSE).<br>
Copyright &copy; 2023 OpenPeeps & Contributors &mdash; All rights reserved.
