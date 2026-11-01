# Rivulet on Apple Vision Pro

The visionOS app is the iOS app (`Rivulet iOS` target) built for the `xros`
SDK: same SwiftUI views, same `RivuletCore`, same AetherPlayer. It runs as a
native visionOS window (not "Designed for iPad"). AetherEngine, FFmpegBuild,
LibDovi, LibTrueHD and Sentry all ship visionOS slices, so nothing in the
package graph changes.

## Build and run

1. Open `Rivulet.xcodeproj` in Xcode 26 or later, with the visionOS platform installed
   (Xcode → Settings → Components).
2. Select the **Rivulet iOS** scheme (the **Rivulet** scheme is the tvOS app and fails for visionOS) and an **Apple Vision Pro** destination
   (simulator or a paired device).
3. For a device, set your own team under Signing & Capabilities and, if
   needed, a unique bundle identifier. The checked-in team is the upstream author's.
4. Run. Sign in to Plex from the account button, the same as on iPad.

## What differs on visionOS

| Area | visionOS behaviour |
| --- | --- |
| Window | Opens at 1366×900 (iPad-like regular width), freely resizable. |
| Player | Same full-window player and chrome. While playing, the window takes the video's aspect ratio (no black bars) and keeps it when resized; the previous size returns on close. AirPlay button hidden. PiP is gated by `AVPictureInPictureController.isPictureInPictureSupported()`, so it doesn't appear. |
| Downloads | Work via the background `URLSession`; no continued-processing Live Activity (iOS-only API). |
| App icon | Layered `AppIconVision.solidimagestack` (starfield back, ribbon front). No alternate icons, so the picker is hidden. |
| Plex identity | `X-Plex-Device` is "Apple Vision Pro"; platform stays "iOS" so the server picks the same transcode profile. |

All platform branches live in `RivuletiOS/`. `RivuletCore/` stays free of
`#if os(...)`, per the platform boundary rule in `CLAUDE.md`.
