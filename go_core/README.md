# go_core

Gomobile wrapper around the Mihomo (Clash Meta) core that exposes a tiny
surface (`Start`, `Stop`, `SetProtector`, `Version`) to the Android app.

## Prerequisites

* Go 1.22+
* Android NDK (set `ANDROID_NDK_HOME`)
* `gomobile` and `gobind`:

```sh
go install golang.org/x/mobile/cmd/gomobile@latest
go install golang.org/x/mobile/cmd/gobind@latest
gomobile init
```

## Build the .aar

From this directory:

```sh
go mod tidy
gomobile bind \
  -target=android \
  -androidapi 29 \
  -ldflags="-s -w" \
  -o ../app/libs/libveer_core.aar \
  .
```

The Android module already declares `implementation(fileTree("libs"))`, so the
generated `.aar` is picked up automatically on the next Gradle sync.

## Exported API (Kotlin view)

After bind, the package is `veercore` with a single static facade class
`Veercore`:

```kotlin
import veercore.Veercore
import veercore.SocketProtector

Veercore.setProtector(object : SocketProtector {
    override fun protect(fd: Int): Boolean = vpnService.protect(fd)
})

Veercore.start(homeDir.absolutePath, "base.yaml", tunFd)
Veercore.stop()
```
