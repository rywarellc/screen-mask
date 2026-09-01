# Screen Mask

A small macOS app for hiding parts of a video — an email address in a terminal,
an API key, a customer name — before you share it.

Masks are rectangles with their own time range, so different things can be
covered during different stretches of the same recording.

## Build and run

```
./build.sh
open ".build/arm64-apple-macosx/release/Screen Mask.app"
```

`swift test` runs the masking tests (coordinate mapping, time gating, and a full
export round-trip that reads pixels back out of the encoded file).

## Using it

1. Drop a video on the window, or **Open Video…**
2. Drag a rectangle over whatever you want hidden. Drag inside it to move,
   drag a corner to resize, and press Delete to remove it.
3. In the sidebar, set when it's visible: scrub to where the thing appears and
   hit **Set In**, scrub to where it goes away and hit **Set Out**. **All**
   covers the whole video.
4. Repeat for each thing you need hidden. The strip under the scrubber shows
   which parts of the timeline each mask covers.
5. **Export…** writes a `.mov` with the masks burned in.

The preview is the export: both run the same composition, so what you see on the
playhead is exactly what lands in the file.

## Pixelate vs. Solid

**Solid** paints an opaque box. **Pixelate** mosaics the region.

Solid masks can be any colour, and the eyedropper next to the colour well
samples one straight off the video — match the terminal background and the
box reads as part of the recording instead of a black rectangle drawn over
it. The eyedropper reads the original frame, so clicking inside a mask you've
already placed samples what's underneath rather than the mask itself.

Use Solid for anything you actually publish. Pixelation of short, predictable
text — an email address, a key with a known format — can sometimes be reversed,
because the mosaic still leaks per-block averages. Pixelate is the right choice
when you want the viewer to see that something is there without reading it.

## Notes

- Export re-encodes with HEVC at highest quality. The source is never modified.
- Masks are stored as fractions of the frame, so they stay put no matter how you
  resize the window.
- Masks are remembered per video between launches. They're stored in
  `~/Library/Application Support/ScreenMask/Masks`, keyed by a hash of the
  video's path, so nothing is written next to your original files. Moving or
  renaming a video starts it fresh.

## Contributing

Fork it and open a pull request. CI has to pass before a PR can be merged —
it runs `swift build`, `swift test`, and assembles the app bundle.

If you're changing masking behaviour, add a test. The ones in
`Tests/ScreenMaskKitTests` cover the parts that fail quietly rather than
loudly: the coordinate flip between the top-left rects the UI works in and
the bottom-left space Core Image draws in, time-range gating, and a full
export that reads pixels back out of the encoded file.
