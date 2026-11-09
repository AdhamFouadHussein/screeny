# Screeny

Screeny turns an Android tablet into a true extended display for a Mac. It is not screen mirroring: macOS sees the tablet as a separate monitor, so you can drag windows onto it and arrange it in System Settings > Displays.

## Status

| Part | State |
| --- | --- |
| Virtual display on macOS 27.0.1 (Apple M4) | Tested |
| Capture and H.264 encoding at 2560×1600 | Tested with a fake client; the stream decoded correctly in `ffmpeg` |
| Keeping the same display across reconnects | Tested with a fake client |
| Android app | Compiles, but has not been run on a tablet yet |
| Touch input | Written, but not tested yet |

## How it works

```
Mac                                              Android tablet
CGVirtualDisplay  (the extra monitor)
      |
ScreenCaptureKit  (captures that monitor)
      |
VideoToolbox      (hardware H.264)
      |
TCP on 127.0.0.1:7878  <---- adb reverse ---->   MediaCodec decoder -> SurfaceView
      |                        (USB)                     |
CGEvent mouse events   <---- touch input -----   TouchTranslator
```

1. The tablet app connects and reports its screen size.
2. The Mac creates a virtual display of exactly that size.
3. The Mac captures only that display, encodes it and streams it to the tablet.
4. Touches on the tablet travel back and become mouse events on the virtual display.
5. When the tablet disconnects, the display stays online, so reconnecting returns to the same screen with its windows in place. Quit `screeny` to remove it, and macOS moves its windows back.

## Requirements

- A Mac with Xcode. Developed on macOS 27 with Swift 6.4.
- An Android tablet running Android 8.0 or newer.
- Android SDK platform tools in `~/Library/Android/sdk`, or set `ANDROID_HOME`.
- JDK 21, only for rebuilding the Android app.

## Setup

1. On the tablet, go to Settings > About tablet and tap Build number seven times. Then turn on USB debugging in Developer options.
2. Connect the tablet to the Mac over USB and accept the debugging prompt on the tablet.
3. On the Mac, grant your terminal app these permissions in System Settings > Privacy & Security:
   - **Screen Recording**, required for the video.
   - **Accessibility**, required for touch input.

## Running

```sh
./run.sh
```

The script installs the tablet app if it is missing, builds the Mac host, sets up `adb reverse`, opens the app on the tablet and starts the display.

| Option | Default | Meaning |
| --- | --- | --- |
| `--mbps N` | `20` | Video bitrate |
| `--fps N` | `60` | Frame rate |
| `--scale 1\|2` | Automatic | `2` gives a sharp Retina-style display; `1` gives more screen space. Automatic uses `2` when the long edge is at least 2400 pixels |
| `--port N` | `7878` | Port on the Mac. The tablet app and `run.sh` also use 7878, so change them too |

## Touch gestures

| Gesture | Action |
| --- | --- |
| One-finger tap | Click |
| Quick repeated taps | Double-click |
| One-finger drag | Click and drag |
| Two-finger drag | Scroll |
| Two-finger tap | Right-click |

## Rebuilding the Android app

```sh
cd android
echo "sdk.dir=$HOME/Library/Android/sdk" > local.properties
JAVA_HOME=/opt/homebrew/opt/openjdk@21 ./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

`run.sh` only installs the app when it is missing, so use `adb install -r` to update it.

## Project layout

| Path | Purpose |
| --- | --- |
| `run.sh` | Builds and starts everything |
| `mac/Sources/CVirtualDisplay/` | Declarations for Apple's private virtual display classes |
| `mac/Sources/screeny/VirtualDisplay.swift` | Creates the extra monitor |
| `mac/Sources/screeny/ScreenCapture.swift` | Captures the monitor |
| `mac/Sources/screeny/H264Encoder.swift` | Encodes the video |
| `mac/Sources/screeny/Server.swift` | Accepts the tablet connection |
| `mac/Sources/screeny/Session.swift` | Runs one tablet connection and defines the wire format |
| `mac/Sources/screeny/InputInjector.swift` | Turns touches into mouse events |
| `android/app/src/main/java/dev/screeny/MainActivity.kt` | Full-screen tablet app |
| `android/app/src/main/java/dev/screeny/StreamClient.kt` | Network connection and video decoding |
| `android/app/src/main/java/dev/screeny/TouchTranslator.kt` | Turns gestures into input messages |

## Wire format

All values are big-endian.

| Direction | Message | Layout |
| --- | --- | --- |
| Tablet to Mac | Hello (once) | `"SCRN"`, u32 version (1), u32 width, u32 height |
| Mac to tablet | Video packet | u8 type (0 = codec config, 1 = frame), u64 timestamp in microseconds, u32 length, Annex-B H.264 data |
| Tablet to Mac | Input | u8 action, f32 a, f32 b |

Input actions are `0` down, `1` drag, `2` up, `3` scroll, `4` right-click and `5` hover. Coordinates and scroll distances are normalized to the display size.

## Limitations

- **Private API:** `CGVirtualDisplay` is undocumented, so a macOS update could break it.
- **USB by default:** the Mac host listens only on loopback, so the unencrypted stream and input channel are not exposed on the network. Android's Wireless debugging may also work through `adb`, but it is untested.
- **One tablet at a time:** further connections are refused while one is active.
- **Touch only:** the tablet does not send keyboard input, stylus pressure or audio.
