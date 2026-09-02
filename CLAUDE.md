# Screen Mask

macOS app that hides rectangular regions of a video for part of its timeline —
covering an email address or an API key in a screen recording before sharing it.

## Commands

```bash
swift build                  # compile
swift test                   # run the suite (parallel; fine on real hardware)
swift test --no-parallel     # what CI runs — see "CI is codec-fragile" below
./build.sh                   # assemble the .app bundle, prints its path
open ".build/arm64-apple-macosx/release/Screen Mask.app"
```

The bundle name contains a space on purpose: Finder and the Dock label an app by
its bundle filename, so `ScreenMask.app` displays as "ScreenMask" no matter what
`CFBundleName` says. Quote the path.

`build.sh` compiles `Resources/AppIcon.iconset` into the bundle with `iconutil`.
The `.icns` is generated, never committed.

## Layout

- `Sources/ScreenMaskKit` — model and Core Image pipeline, no UI. Headlessly
  testable, which is why the masking logic lives here rather than beside the views.
- `Sources/ScreenMask` — SwiftUI app. `AppModel` is the single source of truth.
- `Tests/ScreenMaskKitTests` — the pipeline: compositing, persistence, sampling, export.
- `Tests/ScreenMaskAppTests` — depends on the executable target so it can reach
  `AppModel`. Exists because the bugs that shipped were all in this layer.

## Hazards worth knowing before you change things

Each of these cost real debugging time. They are not obvious from reading the code.

**The coordinate flip.** The UI works in normalized (0–1) rects with a *top-left*
origin. Core Image draws in pixels with a *bottom-left* origin. Every conversion
goes through `MaskCompositor.pixelRect` / `MaskCompositor.color`. Get it wrong and
masks land in the wrong corner — mirrored vertically, which looks plausible enough
to miss. `MaskingTests` pins this with a four-colour quadrant fixture.

**`AVPlayerItem.step(byCount:)` does not step frames.** Measured on a 30fps clip it
steps by sync samples: 0.25s per call, ~7 frames. Frame stepping is an
exact-tolerance seek of one frame duration (`minFrameDuration`) instead. Don't
"simplify" it back to `step(byCount:)`.

**SwiftUI `onKeyPress` doesn't reach the arrow keys here.** It only fires while that
exact view holds focus, and focus sits on the scrubber slider or the mask list — a
focused slider consumes arrows itself. Key handling is an AppKit local event monitor
(`AppModel.installKeyMonitor`), which is focus-independent.

**`NSApp` is implicitly unwrapped and is nil when no `NSApplication` exists.** Bind it
(`if let app = NSApp`) rather than dotting through, or tests trap.

**Clearing regions while a video URL is set deletes that video's saved masks.** Saving
an empty region list removes the document by design. `closeVideo()` flushes, then
clears `url`, *then* empties `regions`, and guards the same hazard again with
`isClosing`. The save is debounced, so a test asserting immediately after will pass
even when this is broken — wait past the debounce window.

**Don't reuse one `CVPixelBuffer` across `AVAssetWriterInputPixelBufferAdaptor.append`
calls.** The writer holds appended buffers while encoding; recycling one corrupts them
and segfaults inside Swift's task allocator, which looks nothing like the actual cause.
Pull a fresh buffer from the adaptor's pool per frame.

**CI is codec-fragile.** GitHub's macOS runners use a paravirtualised video encoder
that fails under concurrent load (`Cannot Decode`, `AppleM2ScalerParavirtDriver`).
The suite runs `--no-parallel` for this reason. Adding more codec-heavy tests can
reintroduce the failure even so — prefer extending an existing export test over
adding another full export.

## Conventions

- Colour is sampled and painted through sRGB explicitly. Core Image's working space
  is linear; a colour read in one space and written in the other comes back wrong.
- Masks persist per video in Application Support, keyed by a hash of the video's
  path — never as sidecar files next to the user's recordings. The stored format is
  versioned; additive changes must decode older documents (see the `MaskStyle`
  colour fallback and its test).
- `.gitignore` excludes `*.mov`/`*.mp4`/`*.m4v`. That is a safety rule, not tidiness:
  this repo exists because recordings carry things people didn't mean to publish.

## Verifying changes

`swift test` covers the pipeline well. It does **not** cover SwiftUI view behaviour —
focus, gestures, drag-and-drop, whether an event monitor is live. Both bugs that
reached the user (a dead drop zone, dead arrow keys) were in that gap, and both had
passing tests underneath them. Run the app and drive the actual control you changed.

When a test guards something destructive or subtle, break the code on purpose and
confirm the test fails. Several tests here passed against deliberately broken code
until they were tightened.

## Security posture

`Solid` is the honest redaction mode and the one to recommend. `Pixelate` leaks
per-block averages, which is enough to attack short predictable text like an email
address or a known-format key. Solid masks are always fully opaque — no alpha — so a
redaction box can't be made see-through.
