# Screen Studio in Sarvkrit — implementation plan

*Working title for the feature: **Screen Recording** (Capture category). Codenamed `Studio` in
source paths. This document is the approved design; the implementation plan it describes is carried
out one phase per branch, one branch per pull request.*

---

## Context

Sarvkrit already does the hard half of this. `Features/Screenshots` has ScreenCaptureKit behind a
testable protocol, a frozen-screen selection overlay, a window picker, a countdown, and — the part
that matters most — a complete **"put the capture on a beautiful background"** compositor:
`CaptureBackground` (mesh/gradient/solid/image/blurred fills, padding, corner radius, two-layer
shadow, inset, alignment, aspect targets), `BackgroundLayout` (pure layout maths),
`BackgroundCompositor` (the drawing), `MeshRenderer` (dithered mesh gradients), `AutoBalance`
(pick a background from the shot's own colours).

Screen Studio is, structurally, that same compositor **with a time axis** — plus a recorder that
captures not just pixels but *what the user did*, so the editor can re-render the cursor, invent
zooms and draw captions after the fact.

What is missing is: a video recorder, an event log, a project document, a time-varying renderer, an
export pipeline, and an editor window with a timeline. This plan covers all of it.

The goal is parity with Screen Studio on the things that make it feel magic — automatic zoom,
re-rendered cursor with motion blur, karaoke captions, one-click gorgeous backgrounds — held to
Sarvkrit's existing standards: pure testable decision logic, no network, per-feature permissions,
and prose in the codebase that explains *why*.

> **Companion document.** A full feature inventory of Screen Studio 3.7.5 — primary sources, its
> reverse-engineered project schema, its version history and its explicit absences — is at
> `2026-09-05-screen-studio-feature-inventory.md` beside this file. Every claim about "the
> reference" below traces to it. Read it before implementing any feature whose details matter.

---

## Where the work happens

**A dedicated worktree, not this checkout.** This session sits on `feature/update-check`, and
`origin/main` is already 4 commits ahead of it *and* contains it — so `origin/main` is the base.

```sh
git worktree add /Users/apple/Documents/Dev/sarvkrit_wt/studio -b feature/studio origin/main
cd /Users/apple/Documents/Dev/sarvkrit_wt/studio
xcodegen generate          # Sarvkrit.xcodeproj is gitignored; nothing builds without this
```

Directory name is the branch's last path component, matching every existing worktree
(`tray-panel-resize`, `panel-overhaul`, `screenshots`, …). Outside the repo, so no `.gitignore`
entry is needed.

Three things that bite in a fresh Sarvkrit worktree, all of which look like build failures and are
not:

1. **Re-run `xcodegen generate` every time a source file is added.** This plan adds roughly forty.
   Skipping it fails with "cannot find X in scope", which reads as a typo.
2. **Quit `/Applications/Sarvkrit.app` before `make test`.** `LSMultipleInstancesProhibited` makes
   LaunchServices refuse the test host with a bare "Could not launch SarvkritTests". The `test`
   target already `pkill`s for this reason.
3. **Check *which* Sarvkrit is running before believing what the app shows you.** With a dozen
   worktrees around, a dev build left running from another one holds the single-instance slot and
   a freshly launched copy exits silently. `pgrep -lf "Sarvkrit.app/Contents/MacOS/Sarvkrit"`
   prints the full path.

### Branch and PR strategy

`main` takes no direct pushes — server-enforced — and the owner merges every PR. Seven phases in one
pull request would be unreviewable, so:

| Branch | Base | Contents |
|---|---|---|
| `feature/studio` | `origin/main` | The integration branch. Never merged as a whole. |
| `feature/studio-recording` | `origin/main` | Phase 1. First PR. |
| `feature/studio-cursor` | `origin/main` | Phase 2, once Phase 1 has merged. |
| `feature/studio-zoom` | … | Phase 3. |
| … | | one branch, one worktree, one PR per phase |

Each phase branch gets its own worktree under `sarvkrit_wt/` and is rebased on `origin/main` before
its PR. Each PR must pass `make test` locally, fill in the template's *What changed / Why / How it
was verified*, and carry its own tests — the phases are ordered so every one of them is
independently shippable.

The design document is committed on the first branch, at
`docs/superpowers/specs/2026-09-05-screen-recording-studio-design.md`.

---

## The one idea everything else follows from

**A Sarvkrit recording is not a video. It is a bundle.**

```
Meeting demo.sarvrec/            ← the recording (immutable, written once)
  screen.mov                     ← HEVC, showsCursor = false, no zoom, no background
  camera.mov                     ← optional, separate file, its own clock offset
  mic.m4a                        ← optional
  system.m4a                     ← optional
  events.json                    ← the whole point (see below)
  manifest.json                  ← displays, scale, source rect, clock epoch, versions
```

`events.json` is a timestamped log recorded *alongside* the video:

| Event | Fields | Used by |
|---|---|---|
| `cursorMoved` | `t`, `point` (global pt), `cursorType` | cursor layer, auto-zoom |
| `mouseDown` / `mouseUp` | `t`, `point`, `button` | click effect, auto-zoom, auto-cut |
| `scrolled` | `t`, `point`, `delta` | auto-zoom damping |
| `keyDown` | `t`, `keyLabel`, `modifiers` | keystroke layer |
| `appActivated` | `t`, `bundleID`, `name` | chapter markers |
| `windowMoved` | `t`, `windowID`, `frame` | window-follow crop |
| `displayChanged` | `t`, `displayID`, `frame` | multi-display safety |

Because the cursor is **not baked into the video**, the editor can draw it at any size, smooth it,
give it motion blur, swap the glyph, and — critically — keep it sharp when the frame is zoomed 2×.
This is the single difference between "a screen recording with a filter" and Screen Studio.

**The editor is a non-destructive compositor.** One pure function:

```swift
StudioRenderer.frame(of project: StudioProject, at t: CMTime, sources: FrameSources) -> CGImage
```

Preview and export call the same function. If they can diverge, they will, and every "the export
doesn't match what I saw" bug lives in that gap. There is no separate preview path.

### Clock alignment is the make-or-break detail

Every event timestamp and every video PTS must be expressed on **one clock**. The recorder takes
the `CMSampleBuffer` presentation timestamp of the first screen frame as `t = 0`, and converts
`NSEvent`-derived `mach_absolute_time` stamps into the same timebase. Camera and audio get a
measured offset stored in the manifest rather than an assumed zero.

Get this wrong by 80 ms and the cursor visibly lags the thing it is clicking — the most damaging
possible defect in this feature, and one that looks like "the app is slow" rather than a bug. It is
therefore Phase 1 work with its own test, not a Phase 5 polish item.

---

## Reuse map — what already exists

| Need | Reuse verbatim | File |
|---|---|---|
| Background fills, padding, radius, shadow, inset, alignment | `CaptureBackground` | `Features/Screenshots/CaptureBackground.swift` |
| Canvas + image-rect maths | `BackgroundLayout.compute` | `Features/Screenshots/BackgroundLayout.swift` |
| Mesh gradient painting (dithered) | `MeshRenderer` | `Features/Screenshots/MeshRenderer.swift` |
| Shadow / fill drawing | `BackgroundCompositor.drawSurround` | `Features/Screenshots/BackgroundCompositor.swift` |
| Background presets + palette | `BackgroundCatalogue`, `BackgroundPresetStore` | same folder |
| Pick a background from the shot | `AutoBalance` | `Features/Screenshots/AutoBalance.swift` |
| Aspect presets | `AspectRatio` | `Features/Screenshots/CaptureBackground.swift` |
| SCK behind a protocol, stubbed in tests | `ScreenCapturing` / `StubScreenCaptureService` | `Features/Screenshots/ScreenCapturing.swift` |
| Screen-recording permission + relaunch dance | `ScreenRecordingRelaunch`, `Requirement.screenRecording` | `Core/` |
| Region selection overlay on a frozen screen | `CaptureOverlayController`, `SelectionView`, `SelectionGesture` | `UI/Screenshots/` |
| Window picker | `WindowPicker`, `WindowPickerList`, `WindowListFilter` | `Features/Screenshots/`, `UI/Screenshots/` |
| Countdown before capture | `CountdownView` | `UI/Screenshots/CountdownView.swift` |
| Snapshot undo over a value type | `UndoStack<Value>` | `Features/Screenshots/UndoStack.swift` |
| View↔document coordinate mapping | `CanvasTransform` | `Features/Screenshots/CanvasTransform.swift` |
| Stroke smoothing (adapts to cursor smoothing) | `PencilSmoothing` | `Features/Screenshots/PencilSmoothing.swift` |
| Editor window pattern, key routing, dirty-close | `ScreenshotEditorWindowController`, `EditorKeyRouting` | `UI/ScreenshotEditor/` |
| Inspector UI idiom | `BackgroundInspector` (709 lines — read it before writing ours) | `UI/ScreenshotEditor/` |
| Debounced disk writes | `CoalescingSaver` | `Core/CoalescingSaver.swift` |
| Spacing/type/motion tokens | `Theme` | `UI/DesignSystem/Tokens.swift` |
| Feature registration, permissions, tray panel | `Feature`, `FeatureRegistry`, `Requirement` | `Core/` |
| Toasts | `ToastPresenter` | existing |

Additional pieces the exploration turned up, all directly reusable:

| Need | Reuse | File |
|---|---|---|
| The whole session/HUD/`isRunning` shape | `ScrollCaptureSession` — read it first; it is the template | `Features/Screenshots/ScrollCaptureSession.swift` |
| Borderless HUD panel with correct level ordering | `FloatingPanel` (note: `isFloatingPanel` must be set *before* `level`) | `UI/Shared/FloatingPanel.swift` |
| Positioning a HUD on the right screen | `ScreenPlacement.screenUnderPointer` | `UI/Shelf/ScreenPlacement.swift` |
| SCK filter that excludes our own windows | `SCKScreenCaptureService.filter(for:content:options:)` | `Features/Screenshots/` |
| SCK config with sRGB forced + `pointPixelScale` sizing | `SCKScreenCaptureService.configuration(for:options:isWindow:)` | same |
| Pixel-grid snapping, display↔global rect maths | `CaptureGeometry` | `Core/CaptureGeometry.swift` |
| Parking a finished `.mov` on the shelf | `ShelfItem.Kind.files([FileReference])` — bookmark-based, zero new code | `Features/Shelf/ShelfItem.swift` |
| Filename patterns with `{date}`/`{time}`/`{n}` | `CaptureFilename` | `Features/Screenshots/` |
| One render path for canvas *and* export | `AnnotationRenderer.Quality { interactive, export }` — the exact pattern | `Features/Screenshots/AnnotationRenderer.swift` |
| Annotation elements over video | `AnnotationElement`, `RGBAColour`, `StrokeStyle`, `TextElement` | `Features/Screenshots/AnnotationElement.swift` |
| An existing `CIContext` | `PixelFilters.context` | `Features/Screenshots/PixelFilters.swift` |
| `sarvkrit://` URL commands | `CaptureURLCommand` | `Features/Screenshots/` |

**Roughly 40% of this feature already exists.** The plan's job is to add a time axis to it without
forking it.

### Integration points that will break if forgotten

These are the "quiet failure" list — each is something that compiles fine and is wrong:

1. **`CaptureOverlayGuard.dismissEverything()`** — ⌃⇧⎋ is documented in the README as *always
   clears the screen*. The recording HUD and the countdown must register, or the one shortcut that
   promises to work always stops working.
2. **`AppDelegate.capture(...)`** needs an `isRecording` guard mirroring the existing
   `ScrollCaptureSession.shared.isRunning` check, so pressing the shortcut again stops the
   recording rather than starting a second one.
3. **Do not add `.recording` to `CaptureMode`.** Its raw values are persisted in the history index
   and it drives four exhaustive switches plus `CaptureHistoryShelf.availableModes`. A recording is
   not a screenshot mode; it gets its own `RecordingSource` enum.
4. **`CaptureHistoryItem` cannot hold a recording** — no duration, no media discriminator, and
   `CaptureHistoryStore.add` PNG-encodes. Recordings get their own `StudioLibraryStore`, in
   `~/Library/Application Support/Sarvkrit/Recordings/`, following `CaptureHistoryStore`'s shape
   (index JSON + payload files + `CoalescingSaver` + retention) but not its schema.
5. **`QuickAccessController.show(_:)`** takes a `CaptureHistoryItem` and thumbnails via
   `NSImage(contentsOf:)`. A recording's thumbnail needs `AVAssetImageGenerator`. Either generalise
   it or give recordings their own post-capture affordance — the latter, because what you want
   after a recording ("Edit", "Save", "Reveal") is not what you want after a screenshot.
6. **`SelectionView` hides the pointer with a cursor rect, not `NSCursor.hide()`.** The recorder
   must *not* inherit that — the pointer has to stay visible while recording, and the frozen
   overlay is dismissed before the stream starts.
7. **Nothing under `Features/` imports the UI layer.** The recorder reaches its HUD through nullable
   closures set by `AppDelegate`, exactly as `ScreenshotFeature` does.

---

## Platform constraints — verified against the macOS 26.5 SDK

The deployment target is **macOS 14.4** and `project.yml` explains why it must not move (Core Audio
process taps for the volume mixer). Everything below was checked in the SDK headers, not assumed:

| API | Availability | Consequence |
|---|---|---|
| `SCStream.addRecordingOutput` / `SCRecordingOutput` | **macOS 15.0** | ✗ Unusable. Write frames ourselves via `AVAssetWriter`. |
| `SCStreamConfiguration.captureMicrophone` | **macOS 15.0** | ✗ Unusable. Mic via `AVCaptureSession`. |
| `SCStreamConfiguration.capturesAudio` | macOS 13.0 | ✓ System audio. |
| `excludesCurrentProcessAudio` | macOS 13.0 | ✓ Keeps our own beeps out. |
| `showsCursor` | macOS 12.3 | ✓ Set **false** — we draw our own. |
| `SCContentSharingPicker` | macOS 14.0 | ✓ Available, but we use our own overlay for consistency. |
| `SCStreamFrameInfo{Status,ContentRect,ScaleFactor,DirtyRects}` | macOS 12.3 | ✓ Needed to drop idle frames. |
| `preservesAspectRatio`, `streamName`, `ignoreGlobalClipDisplay` | macOS 14.0 | ✓ |
| `includeChildWindows` | macOS 14.2 | ✓ Window mode with sheets/popovers. |
| `SFSpeechRecognizer.requiresOnDeviceRecognition` | macOS 10.15 | ✓ Captions, on-device only. |
| SwiftUI `MeshGradient` | macOS 15.0 | ✗ Already why `MeshRenderer` exists. |

Losing `SCRecordingOutput` is not a hardship — it writes one muxed file, and we *want* separate
tracks so audio can be edited independently.

---

## The renderer

### Layer order

The frame is built bottom-up, and the order is stated once here because every feature below plugs
into a named slot:

```
1. Background fill        static per (canvas size, style) → rendered ONCE, cached
2. Screen shadow          moves with the screen rect → per frame, from a pre-blurred sprite
3. Screen layer           video frame, transformed by the zoom curve, clipped to rounded rect
4. Click effect           ripples/highlights at click points, in screen-layer space
5. Cursor                 vector glyph, screen-layer space, motion-blurred
6. Camera                 own rect, own radius/shadow/shape, canvas space
7. Keystrokes             canvas space, anchored
8. Captions               canvas space, anchored
9. Annotations            canvas space (reuses AnnotationElement from the screenshot editor)
10. Watermark             none. We do not ship one.
```

**The background is time-invariant.** A mesh gradient at canvas resolution is far too slow to paint
at 60 fps in `MeshRenderer`, and completely unnecessary, because it does not change between frames.
It is rendered once when the style changes and blitted thereafter. The same applies to the shadow,
which is rendered once into a small pre-blurred nine-slice sprite and stretched to the moving
screen rect rather than re-blurred 60 times a second.

This is the whole performance strategy: **find what does not change, and stop redrawing it.**
(Measure the actual costs before tuning — `MeshRenderer`'s own doc comment sets the standard:
"Measured, not assumed.")

### One renderer, two backends

`MeshRenderer`'s doc comment records a real finding: Core Image works in a linear space and made
sRGB colours "markedly lighter than their surroundings". That verdict stands for *authoring* the
gradient. It does not stand for *compositing* — a blit, a scale and an alpha blend are colour-space
agnostic if every input is tagged.

So:

- Backgrounds, shadows and cursor glyphs are **authored in CoreGraphics** (unchanged, reusing
  existing code verbatim), producing tagged sRGB `CGImage`s.
- Per-frame compositing runs through **one `CIContext`**, with `workingColorSpace` pinned to sRGB so
  no linearisation happens, writing straight into a `CVPixelBuffer` — no intermediate `CGImage`, no
  CPU round-trip.

There is **one** renderer, not two. The backend is a parameter:

```swift
enum RenderBackend { case gpu, software }   // software == kCIContextUseSoftwareRenderer
```

The app uses `.gpu`; tests use `.software`, which is deterministic. A second CoreGraphics
implementation was considered and rejected: two rasterisers can never agree byte-for-byte on
scaling and antialiasing, so "both paths produce the same bytes" would be an untestable promise,
and maintaining two layer stacks is exactly how preview and export drift apart.

*(A `CIContext` in the test host is fine, incidentally — `PixelFilters.context` is one and
`PixelFiltersTests` runs against it today.)*

The parity test therefore compares **software against GPU within a per-channel tolerance**, while
asserting geometry — cursor centroid, screen-rect bounds, caption baseline — exactly. Geometry is
where the bugs are; a two-LSB difference in a gradient is not.

### Preview

`AVPlayer` supplies the decoded frames and the clock; `StudioRenderer` composites them. The player's
layer is never displayed — an `AVPlayerItemVideoOutput` is attached and a display link driven by
`NSScreen.displayLink(target:selector:)` (macOS 14.0, so available at our target) pulls
`copyPixelBuffer(forItemTime:)` each tick and hands it to the renderer.

This is what the `AVPlayerItemVideoOutput` header itself describes, and it is the right call for a
specific reason: **`AVAssetReader` cannot seek.** A reader-based preview would have to be torn down
and rebuilt on every scrub, decoding from the nearest HEVC keyframe each time — which is precisely
the interaction a timeline is made of. `AVPlayer` gives seeking, rate and scrubbing for free.

`AVAssetReader` remains correct for the **export** path, which is strictly sequential.

Preview at 4K on a busy project will not always hit 60 fps, and that is acceptable — but it must
never *lie*. When the renderer cannot keep up it drops frames; it does not skip layers. A preview
that silently disables motion blur to stay smooth is how you ship an export nobody expected.

---

## Non-goals, and why

Stated up front, in the README's own register, because a plan that quietly omits things reads as an
oversight rather than a decision:

- **No cloud upload, no share links, no "export to a URL".** The README's privacy section says *the
  app contains no network code at all*, and that sentence is worth more than a share button.
  Exporting writes a file; what happens to the file is the user's business.
- **No account, no licence check, no watermark.** Screen Studio watermarks its free tier. Sarvkrit
  has no tiers.
- **No cloud transcription.** Captions use `SFSpeechRecognizer` with
  `requiresOnDeviceRecognition = true`, and when `supportsOnDeviceRecognition` is false the feature
  says so plainly and offers nothing rather than quietly sending audio to Apple.

  **This is a quality decision and it deserves to be visible rather than discovered in Phase 6.**
  The reference bundles Whisper locally, in three model sizes, and gets noticeably better
  transcripts than `SFSpeechRecognizer` does — particularly on technical vocabulary. Whisper is
  equally private; it runs on-device either way. The only argument against it is **size**: a Core ML
  Whisper model adds roughly 150–500 MB to an app whose entire DMG is currently a few megabytes,
  and tripling the download of a menu-bar utility to improve one sub-feature is the wrong trade for
  v1.

  So: `SFSpeechRecognizer` now, with `contextualStrings` doing real work to close the vocabulary
  gap, and **a bundled or separately-downloaded Whisper listed in Phase 7 as an explicit decision**
  rather than a silent limitation. If transcript quality turns out to be the thing people complain
  about, the answer is already scoped.
- **No iPhone/iPad recording in v1.** It is a genuinely separate capture stack
  (`AVCaptureDevice` over USB with the device as an external camera). Listed in Phase 7, not
  pretended away.
- **No background removal on the camera in v1.** `VNGeneratePersonSegmentation` is available and
  good; it is also a per-frame cost on a feature most users will not switch on. Phase 6.
- **No multi-track video / picture-in-picture of a second recording.** One screen, one camera.

---

## How it registers with the app

One file, one line, per the README's own rule:

```swift
// Sources/Sarvkrit/Features/Studio/ScreenRecordingFeature.swift
final class ScreenRecordingFeature: Feature {
    var id: String { "screenRecording" }          // stable — this is the UserDefaults key
    var category: FeatureCategory { .capture }
    var title: String { "Screen Recording" }
    var summary: String { "Record your screen; it edits itself." }
    var symbolName: String { "record.circle" }
    var shortcutHint: String? { "⌃⇧R" }
    var requirements: Set<Requirement> { [.screenRecording] }
    // Camera / microphone / speech are per-sub-feature, requested on first use — see below.
}
```

…plus one line in `FeatureRegistry.makeAll()`, after `ScreenshotFeature()`.

### New `Requirement` cases

`Requirement` currently has three cases. This adds three, each with the same honest `explanation`
prose the existing ones carry:

- `.camera` — `AVCaptureDevice.requestAccess(for: .video)`. Queryable, requestable.
- `.microphone` — `AVCaptureDevice.requestAccess(for: .audio)`. Queryable, requestable.
- `.speechRecognition` — `SFSpeechRecognizer.requestAuthorization`. Queryable, requestable.

And three `Info.plist` keys written in the app's voice, e.g.:

> `NSCameraUsageDescription` — "Sarvkrit needs the camera to record you alongside your screen. The
> video is written to your Mac and never sent anywhere."

`.screenRecording` is reused unchanged, **including its relaunch quirk** — `ScreenRecordingRelaunch`
already handles the fact that macOS will not hand a running process a new grant, and the recorder
gets that behaviour for free by returning `noDisplays` the same way `SCKScreenCaptureService` does.

### Sub-toggles that stay off until asked

The README's Snap Areas precedent: a thing that changes what an ordinary action does stays off
until requested. Two qualify here:

- **Show keystrokes** — needs Accessibility, and watching the keyboard is exactly what a privacy-
  minded user wants to opt into rather than discover. Off by default. When on, it records key
  *labels*, never characters typed into a secure field (see the secure-field note under Files).
- **Captions** — needs Speech Recognition and several seconds of CPU. Off by default.

Mouse clicks need **no permission at all** — `NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown)`
is unprivileged — so the base recorder never touches the event tap. That is worth protecting: it
means recording your screen asks for exactly one grant, the one macOS makes unavoidable.

#### ⚠️ Keystrokes must NOT go in `requirements`

`FeatureCategoryTests.testAccessibilityIsRequiredByTapFeaturesAndOnlyThem` asserts a hard
invariant, not a list:

```swift
XCTAssertEqual(needsIt, feature is EventTapFeature, "\(feature.id): wrong requirement")
```

So `ScreenRecordingFeature` **cannot** declare `.accessibility` — it is not an `EventTapFeature`,
and it should not become one for a sub-toggle most users leave off. Instead, keystroke capture
follows the pattern `.audioCapture` already establishes: it is requested at the point of use.

Turning the sub-toggle on calls `PermissionsManager.request(.accessibility)`; while the grant is
missing the sub-toggle renders a `PermissionBanner` and records nothing. The feature as a whole is
never gated on it. This is both the correct UX and the only shape that keeps the invariant.

Note also that `Feature`'s protocol extension **defaults `requirements` to `[.accessibility]`**, so
the override is mandatory and must carry a comment saying why, exactly as `ScreenshotFeature`,
`ShelfFeature` and `KeepAwakeFeature` do.

### House rules this module must follow

Non-negotiable, taken from the existing code rather than invented here:

- **`Features/` never imports `UI/`.** The recorder reaches its HUD and the editor through optional
  closures set in `AppDelegate.wireStudio()`.
- **Settings are computed properties over an injected `UserDefaults`**, with a same-value `guard` in
  the setter and `objectWillChange.send()` after. Never `@Published`, never `@AppStorage` — the
  reason is recorded in `AppState.swift`: a same-value write through a SwiftUI binding became a
  loop that pinned a core at 100%.
- **Feature `id` and every persisted `rawValue` are permanent.** `RecordingSource`,
  `ZoomSegment.Anchor`, `CursorStyle`, `ExportPreset` all get stable raw values from day one.
- **Design-system tokens only, stock controls only.** No custom `ButtonStyle`/`SliderStyle` — there
  is not one in the whole app and there should not be a first. The timeline is the one exception,
  and it is an `NSView`, not a styled SwiftUI control (same reasoning as `SelectionView`).
- **`.accessibilityLabel` on every composed element**, and `.clickableCursor()` on anything
  plain-styled that responds to a click.
- **Write the comment that says which bug the code prevents.** This is the strongest convention in
  the repo; a new module that does not do it will read as foreign.
- Style: ~100 columns, 4-space indent, `// MARK: -` dividers. There is no SwiftLint config.

### Tests that will break, and must be updated in the same PR

The README's "one file plus one line" is true of the app and false of the suite:

| Test | What to do |
|---|---|
| `FeatureStoreTests.testRegistryIDsAreUniqueAndStable` | Add `"screenRecording"` at the right position in the exact ordered array. |
| `FeatureCategoryTests.testShippingFeaturesLandInTheExpectedCategories` | Add the id→`.capture` row. |
| `FeatureCategoryTests.testOnlyFeaturesThatNeedOneSupplyACustomDetailPane` | Add the id — we do implement `makeDetailView()`. |
| `FeatureCategoryTests.testAccessibilityIsRequiredByTapFeaturesAndOnlyThem` | Passes only if `requirements` excludes `.accessibility`. See above. |
| `ScreenshotShortcutTests.testNoCaptureHotkeyIDCollidesWithAnExistingOne` | Grow `existing` for the new `GlobalHotkey.ID` values — **next free is 15**. |
| `TrayPanelRenderTests.allPanels` | Automatic, but our panel must lay out with *no recordings at all*. |
| `RequirementTests` | Covers the three new cases. |

Prose carrying counts also needs updating: README's "Nineteen features", `Theme.Size.panelMaxContentHeight`'s comment, `TrayPanelStrip`'s "nine of them", `TrayPanelRenderTests`' "eighteen rows and seven headers".

*(While in there: README and CONTRIBUTING both say "846 tests"; the suite is now 1,582 across 144
files, and `Tokens.swift:153` says the deployment target is 14.0 when it is 14.4. Worth fixing,
separately from this work.)*

### Shortcuts

Capture already owns the **⌃⇧ + letter** family (`ScreenshotAction`, ten actions). Recording joins
it rather than claiming a new one:

| Action | Default | `GlobalHotkey.ID` |
|---|---|---|
| Start/stop recording | ⌃⇧R | 15 |
| Record area | ⌃⇧E | 16 |
| Pause/resume | ⌃⇧U | 17 |

`RecordingAction` conforms to `ShortcutOwner`, which gets it the whole `ShortcutConflict.verdict`
policy — refusals, warnings, and the shortcut recorder UI — for free.

R, E and U are verified free: `ScreenshotAction` claims ⌃⇧ + **A W F 5 S T Z H P Y**, and ⌃⇧⎋ is
`dismissAllOverlays`.

### The two in-app surfaces

**Tray panel** (`trayPanels()`, id `"recording"`, symbol `record.circle`). The README's rule is that
the menu bar is a dashboard, not a switchboard — so this panel leads with the thing you came for:

- A **Record** button, plus the source/camera/mic pickers inline, so a recording can start without
  the pre-record bar at all.
- The **three most recent recordings** as rows: thumbnail (`AVAssetImageGenerator`), duration, age,
  and a click to open the editor.
- While recording: elapsed time and a Stop button, replacing the above.

It must lay out with **no recordings at all** — `TrayPanelRenderTests` sweeps every contributed
panel and the existing suites deliberately exercise the empty case.

**Detail pane** (`makeDetailView()` — remember to add the id to
`FeatureCategoryTests`' `needsOwnPane` set). A `Form`/`.formStyle(.grouped)` pane with sections for:
quality (fps, resolution cap, HEVC/H.264 for the intermediate), defaults applied to new projects
(background, cursor style, auto-zoom on/off), the sub-toggles (captions, keystrokes) with their
`PermissionBanner`s, the shortcut recorders, retention and the current library size, and the export
folder and filename pattern (reusing `CaptureFilename`).

---

## Files

### New — Phase 1 only

```
Sources/Sarvkrit/Features/Studio/
  ScreenRecordingFeature.swift        Feature conformance, settings, hotkeys, UI closures
  ScreenRecording.swift               the protocol, RecordingRequest/Handle, RecordingError
  SCKScreenRecordingService.swift     the only file importing ScreenCaptureKit for streaming
  RecordingWriter.swift               AVAssetWriter, fragmented MP4, back-pressure, PTS rebasing
  EventLog.swift                      the serial writer + Codable event types
  GeometrySidecar.swift               per-frame contentRect/scaleFactor
  RecordingBundle.swift               .sarvrec layout, manifest, recovery
  RecordingSource.swift               display | window | area — stable raw values
  RecordingAction.swift               ShortcutOwner conformance, GlobalHotkey.ID 15–17
  StudioProject.swift                 the document; Codable with unknown passthrough
  Timeline.swift                      pure: clips, split, trim, speed, sourceTime(forOutput:)
  StudioRenderer.swift                pure: frame(of:at:sources:), the layer order
  StudioLibraryStore.swift            index, payloads, age + size retention
  ExportPreset.swift                  pure

Sources/Sarvkrit/UI/Studio/
  StudioEditorWindowController.swift  modelled on ScreenshotEditorWindowController
  StudioEditorView.swift              rail, canvas, transport
  StudioTimelineView.swift            NSView — ruler, tracks, playhead
  StudioPreviewView.swift             AVPlayerItemVideoOutput + display link
  PreRecordBar.swift                  FloatingPanel
  RecordingHUD.swift                  FloatingPanel
  StudioTrayView.swift                trayPanels()
  ScreenRecordingDetailView.swift     makeDetailView()

Tests/SarvkritTests/
  StubScreenRecordingService.swift    + a small fixture bundle
  TimelineTests.swift  RecordingClockTests.swift  RecordingRecoveryTests.swift
  StudioProjectCodingTests.swift  StudioLibraryStoreTests.swift  ExportPresetTests.swift
  StudioRenderSnapshotTests.swift  StudioChromeSnapshotTests.swift
```

Later phases add `CursorGlyph`, `CursorPath`, `ClickEffect`, `CursorSet` (2); `ZoomPlanner`,
`ZoomEase`, `ZoomSegment` (3); `StudioKeyRouting`, `SilenceDetector`, `TypingDetector` (4);
`CameraSegment`, `Ducker`, `LoudnessMeter`, `StudioMask` (5); `CaptionGrouper`, `CaptionStyle`,
`Transcriber`, `KeystrokeOverlay` (6) — each with its test file.

### Existing files touched

| File | Change |
|---|---|
| `Core/Feature.swift` | three `Requirement` cases: `.camera`, `.microphone`, `.speechRecognition` |
| `Core/FeatureRegistry.swift` | one line, after `ScreenshotFeature()` |
| `Core/GlobalHotkey.swift` | `ID` 15–17 |
| `Core/FocusedRoleCache.swift` | add a focused-element **secure field** check (see below) |
| `App/AppDelegate.swift` | `wireStudio()` + one call in `applicationDidFinishLaunching` |
| `UI/Screenshots/CaptureOverlayGuard.swift` | register the HUD and pre-record bar |
| `Resources/Info.plist` | `NSCameraUsageDescription`, `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription` |
| `Features/Screenshots/CaptureBackground.swift` | `AspectRatio`: append `fourFive`, `threeFour`, `custom` |
| `Features/Screenshots/AnnotationElement.swift` | Phase 7 only: time ranges on elements |
| `README.md` | the feature entry, the permissions section, the feature count |
| Five test files | see the breakage table above |

**On the secure-field check.** `ClipboardPrivacyFilter` is *not* the right utility — it reads
pasteboard markers (`org.nspasteboard.ConcealedType`), which says nothing about where a keystroke
was typed. There is no secure-field test in the codebase today. `FocusedRoleCache` already watches
the focused AX element and exposes `isTextFieldFocused`; it gains a sibling that reports whether
that element's role or subrole is `AXSecureTextField`. Keystrokes are dropped while it is true.

---

## Phase plan

Each phase ends somewhere shippable. Phase 1 alone is already better than QuickTime.

| Phase | Goal | Ships |
|---|---|---|
| **1** | Record → composite → export | Area/window/display recording, background, padding, radius, shadow, aspect, MP4 export |
| **2** | The cursor | Re-rendered cursor, smoothing, size, click effects, cursor hiding |
| **3** | Automatic zoom | Zoom track, auto-generation, manual editing, easing |
| **4** | Timeline editing | Trim, split, delete, speed, playback, keyboard shortcuts |
| **5** | Audio + camera + masks | Mic, system audio, waveforms, volume, silence trimming, camera track, masks |
| **6** | Captions + keystrokes | On-device transcription, karaoke rendering, transcript editor, key display |
| **7** | The long tail | Presets, annotations, GIF, ProRes, vertical templates, iPhone capture |

---

## Phase 1 — Record, composite, export

### 1.1 The recorder

`Features/Studio/Recording/`

```swift
/// Everything that streams from ScreenCaptureKit, behind one protocol.
///
/// Sibling of `ScreenCapturing`, and for exactly the same reason: `SarvkritTests` is hosted
/// inside `Sarvkrit.app`, so a live SCStream in a test either prompts or hands back denied
/// results. `StubScreenRecordingService` replays a fixture bundle instead.
protocol ScreenRecording: AnyObject {
    func start(_ request: RecordingRequest) async throws -> RecordingHandle
}
```

**Configuration, and the reasoning for each choice:**

| Setting | Value | Why |
|---|---|---|
| `showsCursor` | `false` | We draw it. This is the feature. |
| `minimumFrameInterval` | 1/60 (user: 30/60) | 60 is the point; 30 offered for long recordings. |
| `queueDepth` | 8 | 5 is the SCK floor for smooth 60 fps; 8 gives headroom. |
| `pixelFormat` | `kCVPixelFormatType_32BGRA` | What CI wants; ties to the sRGB working space. |
| `colorSpaceName` | `CGColorSpace.sRGB` | Matches `MeshRenderer`'s output exactly. One pipeline. |
| `width`/`height` | source × backing scale | Retina, full resolution. Never downscale at capture. |
| `capturesAudio` | user | System audio. |
| `excludesCurrentProcessAudio` | `true` | Our own toasts must not land in the recording. |
| `includeChildWindows` | `true` (window mode) | Otherwise a menu or sheet vanishes mid-demo. |
| `preservesAspectRatio` | `true` | |
| Excluded windows | `AppIdentity.bundleID` | Same one line that keeps the overlay out of screenshots. |
| `hidesDesktopIcons` | user, default on | Already in `CaptureOptions`; the filter builder already implements it. Free. |

**Writing.** `AVAssetWriter` with `AVVideoCodecType.hevc`, `AVVideoQualityKey` 0.9, and
`kVTCompressionPropertyKey_RealTime = true`. HEVC over H.264 because a 4K/60 screen recording is
enormous and the source is already Apple Silicon with a hardware encoder. The recording is an
intermediate the user rarely keeps, so quality beats compatibility here — the *export* is where
H.264 compatibility matters.

**Dropping idle frames.** `SCStreamFrameInfoStatus` reports `.idle` when nothing changed. Those
frames are not written; the next real frame carries a longer duration instead. For a recording of a
mostly-still screen this is a large saving and nothing about playback changes — measure the actual
ratio on a real demo before quoting one.

**Back-pressure.** If the writer cannot keep up, frames are dropped at the *tail*, a counter is
incremented, and the count is shown when recording stops ("4 frames dropped"). Silently producing
a stuttering file is the failure mode to avoid.

**Files over 4 GB.** Verify a >4 GB recording plays back. This is the class of bug that only appears
after someone's longest and most valuable take, so it gets checked rather than assumed.

### 1.1a Not losing a recording

The single worst outcome this feature has is a lost take, so it gets designed for rather than hoped
about.

- **Crash recovery, via fragmented MP4.** Set `AVAssetWriter.movieFragmentInterval` to ~2 s. The
  writer then flushes a self-contained fragment twice a second's worth, so a file whose
  `finishWriting` never ran is still playable up to the last fragment. This is how the reference
  does it (its bundles contain fragmented segments and playlists written live) and it is far more
  robust than trying to repair a conventional MP4 whose `moov` atom was never written.

  `manifest.json` is written *at start* with `state: "recording"`. On next launch any bundle still
  marked `recording` is recovered: the fragmented file is remuxed to a clean MP4 and the event and
  geometry sidecars — appended continuously, not held in memory — are truncated to the last
  fragment's PTS. The user is told a recording was recovered and how long it is.

  **This also gives pause/resume and low-disk shutdown for free**, since all three are the same
  question: what does the file look like if we stop unexpectedly?
- **Disk space.** Estimate bytes-per-second from the configuration and refuse to start when free
  space is under two minutes' worth, with the number stated. Warn at ten minutes' worth. Stop
  cleanly — finishing the file — when space runs out mid-recording, rather than failing the write
  and losing everything.
- **The event log is flushed periodically**, not only on stop, for the same reason.
- **Display reconfiguration** (a monitor unplugged, resolution changed) stops the recording cleanly
  and keeps what exists, rather than continuing with a stream whose geometry no longer matches the
  sidecar. `CaptureOverlayController` already takes the "cancel rather than recover" line on
  `didChangeScreenParametersNotification`; recording takes "stop and keep" instead, because there
  is something worth keeping.

### 1.2 The event log

A serial-queue writer appending to a preallocated buffer, flushed to `events.json` on stop.

Cursor position is **sampled at the display's refresh rate** via
`NSScreen.displayLink(target:selector:)` (macOS 14.0; `CVDisplayLink` is deprecated from 15) rather
than taken from move events, because move events stop arriving when the mouse is still — and a
cursor that only has samples while moving cannot be interpolated across a pause.

Every sample is stamped with **`mach_absolute_time()` directly**, not `NSEvent.timestamp`, so it
shares a timebase with the `CMSampleBuffer` PTS with no conversion to get wrong.

**Cursor identity: match a kind, and keep the bitmap when you cannot.**

`NSCursor.currentSystem` hands back an *image*, not an identifier. It is compared against the known
system cursors (`arrow`, `iBeam`, `pointingHand`, `openHand`, `closedHand`, `crosshair`,
`resizeLeftRight`, `resizeUpDown`, `resizeDiagonal`, `notAllowed`, `contextualMenu`) by hashing the
bitmap, giving a stable `CursorKind` for the overwhelmingly common case.

When nothing matches — Figma, Photoshop, Blender, a game, any app shipping its own pointers — the
**bitmap is stored**, deduplicated by that same hash, in `cursors/` inside the bundle. The renderer
then draws the vector glyph when a kind matched, and the captured bitmap when it did not, with
smoothing and motion blur applied either way.

This is the correction to an obvious-sounding rule. "Never store the bitmap, always draw vectors"
gives a beautiful pointer in Safari and **an arrow where the brush was** in every Photoshop demo,
which is worse than a slightly soft custom cursor. A demo of a design tool is exactly the kind of
recording this feature is for. Storing costs a handful of small PNGs, because a session uses a
dozen distinct cursors at most and they are hashed.

**Outside the recorded region.** In area and window modes the pointer spends time outside what is
being recorded. Those samples are recorded with an `isInside: false` flag; the renderer hides the
cursor while it is false (fading, not popping), and `ZoomPlanner` ignores clicks that land outside.
Without this, a multi-display recording immediately shows a cursor pinned to the edge of the frame
and zooms that aim at nothing.

### 1.3 The per-frame geometry sidecar

**Window mode moves.** With `SCContentFilter(desktopIndependentWindow:)` the captured frame is
window-relative, and the window can be dragged mid-recording — so a global cursor coordinate cannot
be mapped into frame space by a single constant.

Each frame's `SCStreamFrameInfoContentRect` and `SCStreamFrameInfoScaleFactor` are therefore
recorded into a `geometry.json` sidecar keyed by PTS, and the renderer maps cursor and click points
through *that frame's* rect. Display and area modes write a single constant entry, so there is one
code path rather than a special case.

Window mode also captures **shadowless and on a transparent background** —
`ignoreShadowsSingleWindow`, `backgroundColor = .clear`, `pixelFormat = 32BGRA`, which
`SCKScreenCaptureService.configuration(for:options:isWindow:)` already sets — so the compositor's
own rounded corners and two-layer shadow apply to it. That is what produces the reference's frame
10: a real window floating on a gradient with a shadow that follows its corner radius.

### 1.4 Pause and resume

⌃⇧U pauses. Both the screen stream and the audio tracks stop together; events during the pause are
discarded; and on resume the writer **rebases PTS** by the paused duration so the output has no gap.
Rebasing rather than writing a gap matters because a gap means every downstream time — zoom
segments, captions, the timeline — has to know about it, and none of them should.

The HUD shows elapsed *recorded* time, not wall-clock, so a paused recording does not appear to be
still running.

### 1.5 Picking what to record

Reuses the screenshot path almost entirely. `CaptureMode` gains no cases — instead a parallel
`RecordingSource` enum (`display`, `window`, `area`) drives the same overlay:

- **Area** — `CaptureOverlayController` on a frozen screen, `SelectionView` for the drag, snapped to
  even pixels (an odd width breaks HEVC macroblock alignment and costs quality for nothing).
  `SelectionGesture` already supports an aspect constraint and `SelectionHandles` already supports
  resizing, so an aspect-locked area picker with typed dimensions is mostly wiring. Add rule-of-
  thirds guides while dragging — free to draw, and framing a recording is a composition decision in
  a way framing a screenshot is not.
- **Window** — `WindowPickerList`, unchanged.
- **Display** — the display under the cursor, or picked when there is more than one.

The *countdown* is `CountdownView`, already written, already tested.

### 1.6 The two recording surfaces

Both are `FloatingPanel`s, both modelled on `ScrollCaptureSession`'s HUD, and **both must register
with `CaptureOverlayGuard`** — ⌃⇧⎋ is documented as always clearing the screen and this feature
must not be the exception.

#### The pre-record bar

Appears on ⌃⇧R, positioned by `ScreenPlacement.screenUnderPointer()`. One row, left to right:

| Control | Behaviour |
|---|---|
| **Source** — Display · Window · Area | Segmented. Choosing Area opens the frozen overlay; Window opens the picker. The chosen source is remembered, like `CaptureModeMemory`. |
| **Camera** ▾ | Off + every `AVCaptureDevice`. Selecting one shows a small live preview inside the bar so you can frame yourself before recording, not after. |
| **Microphone** ▾ | Off + every input device, with a live level meter — reuses `AudioDevice`/`MixerLevels` from the Sound feature. |
| **System audio** | Toggle. |
| **Countdown** ▾ | None · 3 s · 5 s · 10 s. |
| **Record** | Primary button. |

The bar accepts key (Escape cancels) and is dismissed before the stream starts, so it is never in
the recording — though `excludedBundleIDs` already guarantees that.

**The camera preview is the point of this bar.** Discovering your camera was off, or pointed at the
ceiling, after a ten-minute take is the single most costly failure this feature can have.

#### The during-recording HUD

Small, unobtrusive, on the display being recorded but excluded from it:

- Elapsed **recorded** time (not wall-clock — see pause, above).
- Pause/resume, Stop, **Restart** and **Discard**. "That take was rubbish, go again" is a daily
  action and routing it through stop-then-delete-the-file is friction on the thing people do most.
  Discard asks once, because it is not undoable.
- A live mic level, when the mic is on. Silence here is the second-most costly failure.
- A dropped-frame count, shown **only if non-zero**.

Stop tears down the stream, flushes the event log and the geometry sidecar, and hands off to the
post-record flow.

**The camera preview**, when a camera is on, is a small floating window so you can see yourself
while recording. It is excluded from capture like everything else of ours — but say plainly in the
UI that it *covers* part of the screen and what is underneath is still recorded, because "why is
there a hole in my recording" is otherwise a confusing few minutes.

#### Recording flags

⌃⌥⌘F during a recording drops a marker. Flags land on the editor's ruler, so "I fluffed that line"
is one keystroke at the time instead of a hunt afterwards. Written to `flags.json` in the bundle.

This is a small feature with a large effect on how a long take feels to record, and it costs
almost nothing: a timestamp, a list, and a tick mark.

### 1.7 After the recording stops

This is Screen Studio's magic moment and it should be ours: **stopping opens the editor with the
project already good.** `AutoBalance` has picked a background from the first frame, padding and
radius are set, and the preview is playing. From Phase 3 onward `ZoomPlanner` has run too; in Phase
1 the editor opens with the background and a trim-only timeline, which is already the useful part.

Alongside it, a single **"Export with defaults"** action — 1080p H.264 to the capture folder — for
the large fraction of recordings nobody wants to edit at all. A tool that demands an editing session
for a thirty-second bug repro has misjudged what most recordings are for.

The alternative (a Quick Access thumbnail like screenshots get) is deliberately not the default:
what you want after a recording is to watch it, and what you want after a screenshot is to send it.

### 1.8 Where recordings live

`StudioLibraryStore`, in `~/Library/Application Support/Sarvkrit/Recordings/`, following
`CaptureHistoryStore`'s shape — an index JSON, payload directories, `CoalescingSaver`, a retention
window — but not its schema (`CaptureHistoryItem` has no duration and no media discriminator).

**Retention has to be size-aware, not just age-aware.** Screenshots are kilobytes and a 30-day
window is free; recordings are hundreds of megabytes and the same window is tens of gigabytes of
someone's disk. So: default **7 days**, plus a total-size cap (default 10 GB) that evicts oldest
first, and the settings pane states the current total in plain numbers. A utility that quietly eats
a disk is worse than one that forgets something.

`CaptureRetention.Window` gains no cases; recordings get their own `RecordingRetention` with both
axes, and the two stores stay independent.

### 1.9 Export

`AVAssetWriter` again, driven by `StudioRenderer`. Presets:

| Preset | Codec | Notes |
|---|---|---|
| MP4 · H.264 | `h264` | The default. Plays everywhere, including Slack previews and PowerPoint. |
| MP4 · HEVC | `hevc` | Half the size, not universally playable. Says so in the UI. |
| MOV · ProRes 422 | `proRes422` | For handing to a real editor. Huge, and the UI says how huge. |
| GIF | — | Phase 7. Needs its own quantiser to not look terrible. |

Resolution presets are computed from the canvas aspect: 4K, 1440p, 1080p, 720p, plus "Original".
fps 60 or 30. Export runs off the main actor with a determinate progress sheet and a working
Cancel — one that actually tears down the writer and deletes the partial file rather than just
hiding the sheet.

**Named export presets**, because "which of these numbers do I want" is not a question most people
can answer:

| Preset | Settings |
|---|---|
| **Web** | 1080p, H.264, 60 fps, ~8 Mbps. The default. |
| **Social** | 1080p, H.264, 30 fps, 4:5 or 9:16 canvas, captions forced on. |
| **For an editor** | Original resolution, ProRes 422, 60 fps, audio tracks kept separate. |
| **Small** | 720p, H.264, 30 fps. For a bug report in a chat window. |

Plus **Copy to clipboard** — exports to a temporary file and puts it on the pasteboard as a
`public.file-url`, so a short recording can be pasted straight into Slack or a PR comment. This is
the fastest path from "record" to "sent" and it is worth having as a first-class action.

`CaptureFilename` supplies the naming, so `{date}`, `{time}` and `{n}` work exactly as they do for
screenshots.

### Phase 1 acceptance

- Record a 30-second window capture; the `.sarvrec` bundle contains video, events and manifest.
- Open it; the editor shows the recording on a mesh background with padding and shadow, and the
  frame at t=10s is pixel-identical between the CI and CG render paths.
- Export 1080p H.264; the output opens in QuickTime, is 30 s ± 1 frame, and matches the preview.
- **The clock test:** a synthetic recording whose events place the cursor at a known point at a
  known time renders the cursor within 1 px of that point in the exported frame at that time.

---

## Phase 2 — The cursor

Frames 2, 3, 7 and 8 of the reference recording show four different cursor glyphs (arrow, crosshair,
pointing hand, arrow again), all rendered large, crisp and clean, and frame 7 shows one smeared by
motion blur during a fast move. This is the single most visible piece of craft in the product.

### 2.1 Glyph assets

Vector, drawn in code, not PNGs. Each cursor is a `CGPath` plus a fill and a stroke, so it is sharp
at any size and any zoom level — the same argument `CaptureBackground`'s doc comment makes about
gradients being data rather than image assets, for the same reason.

The macOS arrow is a specific shape and getting it wrong is uncanny: a 12-point path, black fill,
1.25 px white stroke, and a soft shadow (`blur 6, opacity 0.25, offsetY 2`). `CursorGlyph` is a pure
enum returning `(path, hotspot)` in a 24×24 unit box, exhaustively snapshot-tested — this is
precisely the kind of thing that regresses invisibly.

**Cursor sets.** The glyph set is a `CursorSet` — a named collection covering every `CursorKind` —
so more can be added without touching the renderer. Ship two: **macOS** (faithful, the default) and
**Bold** (heavier stroke, higher contrast, for recordings that will be watched small). Each set is
paths and colours in the `BackgroundCatalogue` mould, not image assets, for the same reasons.

An unknown set id in a project falls back to `macOS` and the project keeps the unknown value, so a
file written by a later build round-trips — the `.unknown` passthrough contract `CaptureBackground`
already establishes.

### 2.2 Smoothing

The raw 120 Hz path has hand jitter that is invisible at 1× and obvious at 2.5× zoom.

`CursorPath` reuses the algorithm `PencilSmoothing` already establishes — **RDP then Catmull-Rom**,
in that order, for the reasons its doc comment gives — with one addition: a critically-damped
spring (`ζ = 1.0`, ω tuned so a 500 px jump settles in ~90 ms) applied *after* interpolation.

The spring is what makes the cursor feel like it has weight. It also introduces lag, which is the
tension: too little and the cursor jitters, too much and it arrives after the click it made. So the
spring is **suspended within 120 ms of a click event** and the cursor snaps to the true position.
A click that lands somewhere the cursor visibly is not is worse than any amount of jitter.

`Smoothing` is a user setting: Off / Light / Standard / Heavy, mapping to spring stiffness. Off is
genuinely off — the raw path — because some recordings (drawing apps, precise dragging) are made
worse by any smoothing at all.

### 2.3 Motion blur — on three channels

Frame 7 is the evidence this exists. The reference applies it independently to **cursor movement**,
**screen zooming** and **screen panning**, and that separation is right: a blurred cursor over a
sharp frame is correct when only the mouse moved, and a blurred *frame* is correct when the zoom
raced somewhere. One global slider cannot express both.

So: a master intensity, plus three per-channel amounts.

- **Cursor** — sample the smoothed path at 4 sub-positions across the frame's duration and
  composite the glyph at each with ¼ alpha. Degrades to a single sharp glyph when the cursor is
  still, with no branch needed.
- **Zooming** and **panning** — the screen layer's transform is likewise sampled across the frame
  and accumulated. Only active while the zoom curve is actually moving, so a static zoomed frame
  costs nothing.

On by default. It is the difference between 60 fps looking smooth and looking sampled — and it is
also what hides the fact that a 60 fps timeline is being resampled through a speed change.

### 2.4 Size, and the zoom relationship

Cursor size is a multiplier (0.5× – 3.0×, default 1.6×) applied in **canvas** space, not screen-layer
space. This matters: if the cursor scaled with the zoom, a 2.5× zoom would give a comically large
pointer. Screen Studio keeps it roughly constant on screen, and so do we — the cursor grows
slightly with zoom (`pow(zoom, 0.25)`) so it does not look detached, but nowhere near linearly.

### 2.5 Click effects

Four options, defaulting to the first:

- **Ripple** — an expanding ring at the click point, 320 ms, ease-out, fading. Radius scales with
  cursor size.
- **Highlight** — a soft filled circle that fades over 200 ms.
- **Shrink** — the cursor itself scales to 0.85× for 90 ms and back. Subtle, and the one that
  reads as "the mouse was pressed" rather than "an effect played".
- **None.**

Left and right clicks get different tints. A click *held* (drag) shows the effect on down and a
faint trail until up.

Optionally, a **click sound** — a soft tick mixed into the exported audio. Off by default, because a
recording with narration does not want it and one without narration often does.

### 2.5a Rotation, and two things to filter out

**Rotation.** A cursor tilted a few degrees into its direction of travel while moving fast reads as
momentum. Capped at ±12°, eased in over 80 ms, and returning to upright when the speed drops —
uncapped rotation looks like a bug, and it is a genuinely small effect that is felt more than seen.

**Shake-to-locate.** macOS enlarges the pointer when you shake it. We are not capturing the system
cursor bitmap so the size does not leak in, but the *path* does — a violent zigzag that
`ZoomPlanner` would read as activity and the smoother would chase. `CursorPath.removingShakes`
detects rapid direction reversals (four or more within 350 ms within a small radius) and replaces
the span with a straight interpolation. Pure, and easy to test with a synthetic zigzag.

**An enlarged system cursor.** If the user has raised the pointer size in Accessibility settings,
our size multiplier compounds with theirs and the result is absurd. Read
`NSWorkspace`/`defaults` for the accessibility cursor scale at record time, store it in the
manifest, and divide it out. When it is far above normal, say so in the pre-record bar rather than
silently correcting — the user may have set it deliberately.

### 2.6 Hiding

`Hide cursor when idle` — after N seconds of no movement (default 3), fade out over 400 ms; fade
back in on the first movement. This is what makes a recording that pauses on a diagram not have a
pointer sitting in the middle of it.

Also: hide entirely, and hide during a specified time range (a timeline-level override).

### 2.7 Loop the cursor back

For a recording meant to loop — a demo GIF, a landing-page hero — the cursor ending far from where
it started makes the seam obvious. `Loop cursor` interpolates the path over the last N seconds
(default 1.0) so it arrives back at its opening position, easing rather than sliding linearly.

Purely a render-time transform on the path; the events are untouched, so it can be switched off
again. Pure function, testable: `CursorPath.looped(_:over:)`.

### Phase 2 tests

- `CursorGlyph` — snapshot each glyph at 1×/2×/3×.
- `CursorPath.smoothed` — pure over a fixture path; asserts jitter reduction, and asserts the
  click-snap suspension puts the cursor exactly on the click point at the click time.
- `ClickEffect.state(at:)` — pure; asserts the ripple's radius/alpha curve at sampled times.

---

## Phase 3 — Automatic zoom

The reference recording's whole feel comes from this. Frames 1 → 4 → 7 zoom progressively into the
cursor's region; frame 9 shows the zoom-out in flight with the shadow and rounded corners visible.

### 3.1 The zoom track

```swift
struct ZoomSegment: Codable, Equatable, Identifiable {
    var id: UUID
    var start: TimeInterval
    var end: TimeInterval
    var level: Double            // 1.0 … 4.0
    var anchor: Anchor           // .followCursor | .fixed(CGPoint) | .region(CGRect)
    var easeIn: TimeInterval     // default 0.6
    var easeOut: TimeInterval    // default 0.5
    var isAutomatic: Bool        // generated, and re-generatable, until the user edits it
}
```

Segments are non-overlapping and sorted. The renderer resolves the transform at time `t` by finding
the covering segment and evaluating the ease.

**`isAutomatic` is load-bearing.** It is what lets "Re-detect zooms" replace generated segments
while leaving hand-made ones alone — the alternative is a button the user cannot press twice
without losing work.

### 3.2 Generation

`ZoomPlanner` — pure, over the event log alone, no video, no AV types. This is the
`RuleMatcher`/`AutoBalance` pattern: taste as a testable function.

The algorithm, stated concretely because "it decides where to zoom" is not a specification:

1. **Cluster clicks.** Clicks within 1.5 s and 200 px of each other form one *activity*.
2. **Extend by dwell.** An activity's window extends to cover cursor dwell before the first click
   (up to 1.2 s) and after the last (up to 0.8 s) — you look before you click, and you look at what
   happened after.
3. **Drop the too-short.** An activity spanning under 1.0 s produces no zoom. A zoom that ends
   before the eye has arrived is worse than no zoom; this is the rule that stops the output
   feeling frantic.
4. **Merge the too-close.** Two activities separated by under 0.8 s merge rather than producing a
   zoom-out-zoom-in, which is nauseating.
5. **Choose the level** from the activity's spatial extent: the zoom is whatever makes the
   activity's bounding box occupy ~60% of the frame, clamped to 1.2× – 2.5×. A single click in one
   spot gets 2.5×; a drag across half the screen gets 1.3×.
6. **Anchor.** `.followCursor` when the activity moves more than 15% of the frame, `.fixed` at the
   centroid otherwise. Following a cursor that barely moves reads as drift.
7. **Cap the density.** No more than one zoom per 4 s of timeline; beyond that, merge. Screen
   Studio's own failure mode when a demo is click-heavy.

Every threshold above is a named constant in one struct (`ZoomPlanner.Tuning`) with a documented
default, so the taste can be adjusted without touching the algorithm.

**Typing is activity too.** A burst of `keyDown` events with no clicks is someone filling in a form
or writing code, and it deserves a zoom as much as a click does — anchored on the caret's last
known position, which is the last click or, failing that, the cursor. Clusters of 5+ keystrokes
within 2 s form a typing activity and go through steps 2–7 unchanged. Without this, the most common
thing in a software demo produces no zoom at all.

*(Keystrokes are only available when the keystroke sub-toggle was on during recording. When it was
off, zoom planning uses clicks alone and that is a documented consequence of the privacy default,
not a bug.)*

### 3.3 Following the cursor

A `.followCursor` segment does not track the cursor exactly — that produces seasickness. It tracks a
**heavily damped** version (ω roughly 1/8 of the cursor spring) and only moves at all once the cursor
leaves a dead-zone of 25% of the frame from centre. Inside the dead-zone the frame is still.

The pan is also **clamped so the screen layer never shows past its own edge** — no black bars, no
background bleeding through the middle of a zoom. At 1.0× the clamp is identity, which is why
zooming out always lands exactly where the un-zoomed frame is.

### 3.4 Easing

`ZoomEase` is a pure curve. Screen Studio's feel is a soft, slightly overshooting ease — not
`easeInOut`, which reads as mechanical. The default is a critically-damped spring evaluated over
the ease duration, with an `easeOut` shorter than the `easeIn` (0.5 vs 0.6): you can leave faster
than you arrive without it feeling abrupt.

Per-segment override: Smooth (default), Linear, Instant. Instant is for cuts.

**A zoom that starts at t = 0 opens already zoomed** rather than animating in from 1×. Nobody wants
their video to begin by moving; if the first thing you want shown is a close-up, it should simply be
there on frame one.

### 3.5 Manual editing

The zoom track in the timeline is directly manipulable, which is the whole reason it is a separate
track rather than a property:

- Drag a segment's body to move it; drag its edges to retime it.
- Double-click to open a small inspector: level slider (1×–4×, live preview), anchor picker, ease.
- Drag on the *preview canvas* while a segment is selected to reposition a `.fixed` anchor, with the
  frame showing the result live.
- `+` adds a segment at the playhead; `⌫` deletes the selected one.
- **Number keys `1`–`9` set the selected segment's level** directly (1 = 1×, 2 = 1.25×, … up to 4×),
  because adjusting zoom is the single most repeated action in this editor and a slider is the
  slowest way to do it.
- **⌘C / ⌘V on a segment** copies its level, anchor and easing onto another — the settings you tuned
  once are the settings you want on the next twelve.
- **"Apply to all"** pushes the selected segment's settings onto every automatic segment.
- "Re-detect" regenerates the automatic ones.

### 3.6 Advanced easing controls

The default spring is tuned and most people should never see its parameters. Behind a disclosure,
for the people who will: **mass**, **stiffness** and **damping**, with a live preview curve. Exposing
the actual model rather than three vague sliders labelled "smoothness" is both more honest and more
useful, and it costs nothing — the spring is already parameterised.

### Phase 3 tests

`ZoomPlannerTests` is the big one, and it is pure: fixture event logs (a slow demo, a click-storm, a
long drag, a single click, an empty log) asserted against expected segment counts, levels and
bounds. This is exactly the `RuleEngineTests`/`SnapZoneTests` shape the repo already uses.

`ZoomEaseTests` asserts monotonicity, endpoint exactness (`ease(0) == from`, `ease(1) == to` — an
ease that does not land precisely leaves a visible jolt), and clamp behaviour at the frame edges.

---

## The editor window

*This section is cross-cutting: it appears here because Phases 4–7 all describe controls that live
in it. The window itself is built in Phase 1, initially with only the canvas tab and a trim-only
timeline, and gains tabs and tracks as each phase lands.*

Modelled on `ScreenshotEditorWindowController` — a real `NSWindow`, not a `FloatingPanel`; through
`ActivationPolicyLease`; keys via a local `NSEvent` monitor because there is no main menu.
`contentMinSize` is 1100 × 700 (the timeline and the inspector both have a floor below which they
start hiding controls silently, which is the one thing this window must not do).

Layout, matching the reference:

```
┌──────────────────────────────────────────────────────────────────────────┐
│ ○○○  📁 🗑   Meeting demo.sarvstudio   ↶ ↷   ✨ Presets ▾  ▥  ⏱   [Export]│  titlebar
├──────────────────────────────────────────────────────────────┬───────────┤
│                                                          ▣ │ Background  │
│                                                          ↖ │ ┌─────────┐ │
│                    PREVIEW CANVAS                        ▣ │ │Wallpaper│ │  inspector
│               (background + screen + cursor              💬│ │Gradient │ │
│                + camera + captions)                      🔊│ │Color    │ │
│                                                          ⌘ │ │Image    │ │
│                                                          ⤳ │ └─────────┘ │
│                                                     rail   │  swatches…  │
├──────────────────────────────────────────────────────────────┴───────────┤
│ ▥ Wide 16:9 ▾   ⧉ Crop      ⏮  ⏸  ⏭        ✂   ↔ ────●────              │  transport
├──────────────────────────────────────────────────────────────────────────┤
│ ✂5s │      1s      2s      3s      4s      5s      6s          │ 2s✂     │  ruler
│ ┌────────────────────────────────────────────────────────────────────┐   │
│ │ ▤ Clip                      7s ⏱1x        ∿∿∿ waveform ∿∿∿        │   │  clip track
│ └────────────────────────────────────────────────────────────────────┘   │
│ ┌────────────────────────────────────────────────────────────────────┐   │
│ │ ⊡ Zoom                      🔍2x  🖱Auto                            │   │  zoom track
│ └────────────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────────┘
```

### The rail

Seven icons, each selecting what the inspector shows. Selection is a single source of truth
(`@Published var inspector: InspectorTab`), and a small dot marks a tab whose settings differ from
the default — the reference has one beside the canvas icon, and it is a genuinely good idea: it
tells you where your changes live before you go looking.

`canvas` · `cursor` · `camera` · `captions` · `audio` · `keystrokes` · `effects`

Tabs whose source is absent (no camera recorded, no audio track) are shown **disabled with a
reason on hover**, not hidden. A control that vanishes teaches nothing.

### The transport bar

- **Aspect** — `AspectRatio`, reused. It already has `original`, `square`, `fourThree`, `threeTwo`,
  `sixteenNine` and `nineSixteen`; add `fourFive` (the Instagram portrait crop) and `threeFour`, and
  give each a friendly name beside the numbers the way the reference does — **Auto · Wide 16:9 ·
  Vertical 9:16 · Square 1:1 · Classic 4:3 · Tall 3:4 · Portrait 4:5** — plus a genuinely custom
  entry, which the reference lacks. Raw values are persisted, so the new cases append; nothing is
  renamed.
  Changing it re-runs `BackgroundLayout` and the preview reflows immediately.
- **Always keep zoomed in** — a toggle that holds the frame at the current zoom rather than
  returning to 1× between segments. For a vertical export of a wide screen this is not an
  embellishment, it is the only way the content is legible.
- **Crop** — a drag-handle overlay on the canvas, writing `cropRect` the way `AnnotationDocument`
  already models it, with an aspect lock, typed numeric fields, and rule-of-thirds guides.
  Non-destructive, like everything else here; cancelling restores the previous crop rather than
  clearing it.
  **Suggested crops** for common browser chrome: when the recorded window's owning bundle is Safari,
  Chrome, Arc or Firefox, offer a one-click crop that removes the toolbar and URL bar. The
  `owningBundleID` is already on `CapturableWindow`, and the inset per browser is a small table.
  This is a tiny feature that saves a fiddly manual crop on a large fraction of all demos.
- **Transport** — prev/play/next. Space plays; `←`/`→` step one frame; `⇧←`/`⇧→` one second;
  `,`/`.` step frames the way editors expect.
- **Split (✂)** — cuts the clip at the playhead.
- **Timeline zoom** — fit button plus a slider. Fit is `↔`.

### The timeline

An `NSView`, not SwiftUI, for the same reason `SelectionView` is: it redraws on every mouse-moved
over a waveform that may be tens of thousands of samples, and SwiftUI's diffing is the wrong tool.
It draws:

- A **ruler** with adaptive tick density (1 s / 5 s / 10 s / 30 s depending on zoom), labelled.
- **Trim handles** at both ends, each with a scissors badge showing how much is trimmed
  (`5s` / `2s` in the reference). Trimming is non-destructive — the source is untouched and the
  badge is what tells you so.
- The **clip track**: amber, rounded, with the audio waveform drawn inside it, the source
  timecodes at its corners (`0:05` … `0:12`) and its duration and speed in the middle (`7s ⏱1x`).
- The **zoom track**: indigo segments, each labelled with its level and anchor mode (`🔍2x 🖱Auto`).
- A **playhead** the full height, draggable, snapping to clip edges and zoom boundaries when within
  4 px (hold ⌥ to suspend snapping).

Waveform data is computed once on open by an `AVAssetReader` pass into a min/max envelope at
several resolutions (a mip-chain), cached in the project bundle and computed lazily per visible
span for a long recording. Recomputing it on every zoom change is the obvious wrong answer and the
one that makes a timeline feel heavy.

**Audio scrubbing.** Dragging the playhead plays the audio under it at a rate proportional to the
drag speed, in both directions. Finding the exact frame between two words is the single most common
precise edit anyone makes, and doing it by eye on a waveform is guesswork — this is how every real
editor solves it and it costs one `AVAudioUnitVarispeed`.

**Trim bubbles.** A trimmed end shows a rounded badge with a scissors glyph and the trimmed
duration — exactly as in the reference — and clicking one *undoes that trim*. It is both the
indicator that something is hidden and the control that brings it back, which is why trimming never
needs to feel committal.

`⌘⌥⌫` resets every trim and cut on the timeline at once, for when an edit has gone wrong enough
that undo is the slower route.

### The inspector

Reuses `BackgroundInspector`'s idiom directly — `SettingsModule` cards, `SectionHeader`, stock
sliders, and swatches drawn through the **same** `BackgroundCompositor` code path as the export, so
a swatch cannot lie about what it produces. `BackgroundInspector` is 709 lines and already solves
wallpaper import, mesh editing, preset save/load and the padding/inset/corner/shadow sliders with
sensible maxima derived from the short side. Read it before writing the canvas tab; most of it
transfers with the image size swapped for the canvas size.

Three additions, all of which improve the screenshot editor too and should be built there so both
get them:

- **Favourites** — star a background; starred ones sort first. With a catalogue of any size this is
  the difference between a picker and a haystack.
- **Randomise** — one button. Useful more often than it sounds, because "any of these is fine" is
  the honest state most of the time.
- **A larger catalogue.** Twenty built-in meshes is thin next to the reference's hundred-plus. They
  are data — a `MeshSpec` is nine colours — so this is taste and an afternoon, not engineering.
  Group them into named collections rather than one long grid.

Note the reference credits its gradients to raycast.com. Anything adopted from elsewhere carries
its attribution in the UI, as theirs does.

### Project file

`Meeting demo.sarvstudio` is a **package directory** (`NSFileWrapper`, `UTType` declared as a
package), containing the `.sarvrec` bundle plus `project.json`. A package rather than a flat file
because the recording is hundreds of megabytes and re-serialising it on every autosave would be
absurd; and a directory the user can open shows them exactly what the app is keeping.

`project.json` is `Codable` with a `formatVersion`, hand-written `init(from:)` that defaults
missing keys rather than throwing, and an `unknown` passthrough for forward compatibility — the
exact contract `AnnotationDocument` and `CaptureBackground.Fill` already implement. A project
written by a newer build must open, not error.

Autosave through `CoalescingSaver`. Undo through `UndoStack<StudioProject>` — snapshot undo over a
value type, depth 200, transactions around drags, exactly as the screenshot editor does it. The
project is geometry and numbers, never bitmaps, so snapshots stay cheap.

### Project management

- **Recent projects**, in the tray panel and on `⌘O`.
- **Duplicate project** — cheap, because the recording bundle is hard-linked rather than copied.
- **Open an existing video** (`.mp4`, `.mov`) as a project. Everything that depends on the event log
  — cursor rendering, auto-zoom, keystrokes — is unavailable and *says so*, greyed with a reason,
  rather than appearing and doing nothing. Everything else (background, crop, trim, speed, captions
  from the audio, camera overlay, masks) works. This is a genuinely useful mode: it makes the
  compositor available to footage recorded anywhere.
- **Drag a video onto the app** does the same.
- **Presets** — `.sarvpreset` files holding canvas + cursor + camera + caption settings, saved,
  named, applied in one click, and set as the default for new recordings.
  `BackgroundPresetStore` is the model, including its "an unreadable file is logged and left in
  place, never overwritten" rule.
- **⌘K command menu** — a searchable list of every editor action with its shortcut. This is the
  cheapest possible discoverability for a window that has a hundred of them, and it is the thing
  that stops the keyboard map being knowledge only the author has.
- **Export several projects at once**, queued, with one progress list.
- **Extract the raw files** — write the untouched screen, camera and audio tracks out of the bundle.
  The recording is the user's; the app should never be the only thing that can open it.

---

## Phase 4 — Timeline editing

### The clip model

```swift
struct Clip: Codable, Equatable, Identifiable {
    var id: UUID
    var sourceStart: TimeInterval        // into the recording
    var sourceEnd: TimeInterval
    var speed: Double = 1.0              // 0.25 … 4.0
    var volume: Double = 1.0             // microphone
    var systemAudioVolume: Double = 1.0  // separate — see below
    var isMuted: Bool = false
    /// Per-clip cursor overrides. Both exist because both have a real use.
    var hidesCursor: Bool = false
    var disablesCursorSmoothing: Bool = false
}
```

The two cursor overrides earn their place: **hide** is for a stretch where the pointer is parked
over the thing being discussed, and **disable smoothing** is for a stretch where precision matters
more than grace — walking down a menu, dragging a handle — and interpolation makes the cursor
appear to hover between items it never touched.

The two volumes are separate because "mute the video I was demoing but keep my narration" is the
common case, and a single volume cannot express it.

The timeline is `[Clip]`. Trimming moves `sourceStart`/`sourceEnd`; splitting replaces one clip with
two; deleting removes one and everything after slides left. **Nothing is ever removed from the
recording** — trim is a view onto it, which is what makes "un-trim" free and is why the trim badge
can honestly say "5s".

`Timeline` is a pure struct with the whole edit vocabulary, and it is where the tests live:

```swift
func split(at t: TimeInterval) -> Timeline
func delete(id: Clip.ID) -> Timeline
func trim(id: Clip.ID, start: TimeInterval?, end: TimeInterval?) -> Timeline
func setSpeed(id: Clip.ID, _ speed: Double) -> Timeline
func sourceTime(forOutput t: TimeInterval) -> (clip: Clip, sourceTime: TimeInterval)?
var duration: TimeInterval
```

`sourceTime(forOutput:)` is the function the renderer and the exporter both call, and it is where
speed changes become correct or subtly wrong. A clip at 2× consumes source twice as fast; the
cursor events, the zoom segments and the captions must all be looked up through *the same*
mapping, or a sped-up section desynchronises everything but the video. One function, one test
suite, no second implementation.

### Which clock every track is on

Stated once, because getting it wrong is invisible until an edit is made:

> **Every track — zoom, camera, masks, keystrokes, captions — is stored in *source* time**, and is
> resolved for rendering through `Timeline.sourceTime(forOutput:)`.

That is what makes trimming the start of a recording leave the zooms attached to the moments they
were built for, rather than sliding them all two seconds early. It is also what makes deleting a
clip in the middle simply skip the zooms inside it.

Two consequences that must be handled explicitly, and both belong in `ZoomEaseTests`:

**Ease durations are in *output* time.** A zoom-in specified as 0.6 s inside a clip sped up to 4×
would occupy 0.15 s of the finished video and read as a jump cut. So the ease is evaluated against
output time and the source lookup follows, not the reverse.

**A cut inside a zoom segment must blend, not pop.** Splitting mid-zoom leaves the transform at one
value on the outgoing frame and a different value on the incoming one. The rule: at a clip
boundary the renderer re-eases **from the transform it was actually showing** to the incoming
segment's target over 0.3 s of output time. Cutting the middle out of a zoomed passage is a normal
edit and it must not flash.

### Speed

Per-clip, 0.25× – 4×. Audio is time-stretched with `AVAudioUnitTimePitch` (pitch preserved) rather
than resampled, because a sped-up voice that also goes up a fifth is unusable.

**Speed ramps are Phase 7.** A constant-speed clip is a lookup; a ramp is an integral, and getting
the integral wrong desynchronises audio in a way that is very hard to see coming. Not worth
carrying into the phase that has to be right first.

### Silence trimming

`SilenceDetector` — pure over an amplitude envelope, no AV types:

```swift
static func silences(in envelope: [Float], sampleRate: Double,
                     threshold: Float, minimumDuration: TimeInterval) -> [Range<TimeInterval>]
```

Defaults: −45 dBFS, 0.6 s minimum. The UI offers "Remove silences" as a one-shot that inserts cuts
you can then undo or adjust individually — **not** a live filter. A live filter means the timeline
does not show what will be exported, which breaks the promise the whole editor rests on.

Each removed silence leaves a **0.15 s pad** at each edge, because cutting exactly at the threshold
clips the attack of the next word and makes speech sound gasped.

### Speed up the typing

The other half of the same idea, and the one the reference actually ships: **watching someone type
is boring at 1× and fine at 4×.** `TypingDetector` finds runs of keystrokes (5+ within 2 s, gaps
under 800 ms) and proposes a speed change over each.

Presented as **suggestions**, not applied: each proposed run is highlighted on the timeline with an
accept/adjust/dismiss control, plus "apply to all". A speed change silently inserted into someone's
timeline is exactly the kind of helpfulness that makes a tool untrustworthy.

Default 4×, adjustable per run. Available only when keystrokes were recorded.

### Minimums

A clip cannot be shorter than **100 ms** and a zoom segment cannot be shorter than **100 ms** —
below that they are unselectable with a mouse and produce nothing visible. Enforced in `Timeline`
and `ZoomSegment`, so a drag clamps rather than creating something the user cannot get rid of.

### Keyboard

The shortcuts an editor's muscle memory expects, routed through a `StudioKeyRouting` enum in the
`EditorKeyRouting` mould (pure, exhaustively tested):

`Space` play/pause · `←`/`→` frame · `⇧←`/`⇧→` second · `,`/`.` frame · `⌘B` split ·
`⌫` delete selected · `I`/`O` set in/out · `⌘Z`/`⌘⇧Z` undo/redo · `⌘E` export · `⌘S` save ·
`⌘0` fit timeline · `⌘+`/`⌘-` timeline zoom · `Z` add zoom at playhead · `⌘W` close.

**J / K / L shuttle**, because anyone who has used an editor reaches for it without thinking: `L`
plays forward and each further press doubles the rate (1×, 2×, 4×, 8×), `J` does the same
backwards, `K` stops. Holding `K` with `J` or `L` scrubs slowly. Preview playback rate is also
settable directly (0.25× – 2×) for reviewing fast passages.

`X` is **ripple delete** — remove the selected clip and close the gap — distinct from `⌫`, which
lifts it and leaves the gap. Both are wanted and conflating them is a daily annoyance.

`⌘L` toggles **loop playback**, which is how you judge whether a zoom's easing is right: you watch
the same two seconds twenty times.

### The tracks

Five, top to bottom, each independently collapsible:

1. **Clip** — video with its waveform, trim handles, speed.
2. **Zoom** — the segments.
3. **Camera** — layout segments (Phase 5).
4. **Keystrokes** — one tick per recorded key, so a keystroke overlay can be trimmed or deleted
   individually. Present only when keystrokes were recorded.
5. **Audio** — mic and system as separate lanes when both exist.

Collapsing is remembered per project. A five-track timeline in a 700 px window is unusable
otherwise, and hiding tracks the project does not use is the difference between "capable" and
"cluttered".

### Copy and paste clip settings

`⌥⌘C` / `⌥⌘V` copies speed, volume and mute from one clip to another — the same argument as for
zoom segments.

### Preview quality — three named modes

A preview that silently degrades is ruled out; one the user *chose* is fine, and none of them
affect the export.

| Mode | What it does |
|---|---|
| **Quality** | Preview matches the export exactly, motion blur included. The default. |
| **Performance** | Half resolution and motion blur off, for a higher frame rate. Says so in the UI while active, so nobody judges the blur from it. |
| **Power saving** | Quarter resolution, 30 fps, playback idles after 30 s of no interaction. For editing on battery. |

Naming them beats a "reduced quality" checkbox: the modes have different reasons, and a user with a
2019 Intel Mac and a user on a train want different ones.

### Multi-select and batch edits

⌘-click selects several clips, zooms or masks; the inspector then edits what they have in common,
and ⌫ removes all of them. Setting the same zoom level on twelve segments one at a time is the
fastest way to make an editor feel hostile.

### Copy the current frame

`⌘C` with nothing selected copies the **composited** frame at the playhead as a PNG — background,
cursor, camera and all. Reuses `CaptureWriter.copyToPasteboard`. A screen recording is very often
where a screenshot was actually wanted, and this makes that a keystroke instead of a re-shoot.

### `⌘/`

Opens a sheet listing every editor shortcut, generated from `StudioKeyRouting` rather than
hand-written, so it cannot drift from what the keys actually do.

---

## Phase 5 — Audio, camera and masks

### Audio capture

Two independent tracks, recorded separately and kept separate:

- **System audio** — `SCStreamConfiguration.capturesAudio` (macOS 13+, verified available), with
  `excludesCurrentProcessAudio = true`. Arrives as `CMSampleBuffer` on the SCK output queue.
- **System audio from one app only** — Sarvkrit already has this machinery.
  `Features/Sound/AudioProcessTap.swift` is a Core Audio process tap built for the volume mixer, and
  a per-process tap is exactly what "record only Safari's audio" needs. This is a genuine advantage
  over doing it from scratch: the hard part is written, tested and shipping.
- **Microphone** — `AVCaptureSession` with an `AVCaptureAudioDataOutput`, *not*
  `SCStreamConfiguration.captureMicrophone`, which is macOS 15. Device is user-selectable and the
  list reuses `AudioDevice`/`AudioDeviceMonitor` from the Sound feature, so the picker matches the
  one the app already has. Recorded in **stereo** where the device offers it.

  **Automatic gain control is switched off by default**, with a toggle. macOS's AGC rides the input
  level during a take, so a narration that starts quiet gets pushed up mid-sentence and the result
  cannot be normalised cleanly afterwards. A constant input level and one correction in the editor
  is the better order of operations, and it is the reference's default too.

Keeping them separate is not incidental: it is what lets the editor mute system audio and keep the
voice-over, duck one under the other, and export a mix the user chose rather than the one that
happened.

Note that the app already holds an `NSAudioCaptureUsageDescription` and the `.audioCapture`
`Requirement`, complete with its documented "macOS refuses this one silently" behaviour. The
recorder inherits that: if the system-audio track is all zeroes when it should not be, say so
afterwards rather than shipping a silent file.

### Audio editing

Per-track: volume (0–200%, reusing `SoftClip` from the mixer for anything above 100% — the same
limiter, the same "quiet material at 200% is bit-for-bit untouched" property), mute, and a
waveform.

**Ducking** — when both tracks exist, optionally attenuate system audio while the mic is above a
threshold. Attack 80 ms, release 400 ms, depth adjustable, default −12 dB. `Ducker` is pure over
two envelopes.

**Noise removal** — `AVAudioUnitEQ` high-pass at 80 Hz plus a spectral gate. Modest and honest; we
do not claim to do what a dedicated tool does.

**Background music** — an optional third audio lane holding a file the user supplies, with its own
volume, fade in/out and loop-to-length. Sarvkrit ships **no music library**: bundling licensed audio
is a licensing and download-size question this app has no reason to take on, and every user already
has music they are allowed to use.

**Voice normalisation** — measure integrated loudness over the mic track and apply one constant
gain to reach a target (default −16 LUFS, the streaming convention), then hand anything that would
clip to `SoftClip`. One gain for the whole track, not a compressor: a demo recorded slightly too
quiet is the actual problem, and dynamic-range compression on speech is a taste decision this app
should not make silently. `LoudnessMeter` is pure over an envelope and exhaustively testable.

### Camera

`AVCaptureSession` with `AVCaptureVideoDataOutput`, written to its own file. Resolution follows the
device, capped at 1080p — a 4K webcam feed for a 300 px circle is pure waste.

Editor controls, all per-project:

| Control | Range / options | Default |
|---|---|---|
| Shape | Circle · Squircle · Rectangle · Full-frame | Squircle |
| Corner radius | 0 – 50% (squircle/rect) | 26% |
| Size | 10 – 40% of canvas height | 22% |
| Position | 9-way grid + free drag | bottom-leading |
| Margin | 0 – 8% of canvas | 3% |
| Shadow | reuses `CaptureBackground.Shadow` | on |
| Border | width + colour | off |
| Mirror | on/off | on (front cameras look wrong un-mirrored) |
| Zoom / crop | 1× – 2.5×, draggable framing | 1× |
| Size during zoom | shrink · hold · grow | **shrink**, `pow(zoom, −0.2)` |
| Aspect | 1:1 · 4:3 · 16:9 · free | 1:1 |
| Fade in / out | 0 – 2 s | 0.35 s |
| Capture resolution | 720p · 1080p · device max | 1080p |

The reference's PiP is a squircle with a continuous corner curve, and the difference between a
`RoundedRectangle(style: .continuous)` and the circular default is visible at this size — use the
continuous curve.

**The camera shrinks when the frame zooms in, it does not grow.** This is the opposite of the
instinct and the reference states the reason plainly: a zoom exists to show something, and the
camera covering it defeats the zoom. Hold and grow are offered because a talking-head intro wants
them, but shrink is the default.

Two more things the shape controls should get right: the camera keeps a **constant margin from the
canvas edge regardless of the project's padding** (otherwise raising padding appears to move the
camera), and the corner radius is computed from the *shorter* side so a non-square camera does not
end up with lozenge ends.

**Background removal** is Phase 6: `VNGeneratePersonSegmentationRequest` (macOS 12+, verified) at
`.balanced`, matted with a 2 px feather. It is a per-frame cost and it is not always good, so it is
off by default and labelled for what it is.

### The camera track

Camera *layout* changes over time, so it belongs on the timeline rather than in a single settings
panel. A third track holds `CameraSegment`s:

```swift
struct CameraSegment: Codable, Equatable, Identifiable {
    var id: UUID
    var start: TimeInterval
    var end: TimeInterval
    var layout: Layout          // .pip | .fullFrame | .hidden
    var transition: TimeInterval  // default 0.45, eased
}
```

This is what makes the standard shape of a good demo possible: **full-frame camera for a five-second
intro, PiP for the walkthrough, hidden while a dense diagram is on screen.** Doing it with a single
"camera position" setting cannot express any of that.

Transitions between layouts animate position, size and corner radius together on one curve, so a
full-frame camera *becomes* the PiP rather than cutting to it.

### Masks — hiding what should not be in the recording

Regions that obscure part of the frame for a time range: an API key, a customer name, a Slack
sidebar.

**One mask holds a list of rectangles**, not a single one, so "hide every price in this table" is
one object with one time range rather than nine to keep in sync. Ellipses too, reusing
`PixelFilterElement.isEllipse`.

**This is where Sarvkrit is already better than what it is copying, and it should stay that way.**
The README argues at length that an ordinary blur is reversible and pixelation is recoverable when
the alphabet is small — which is exactly the password case — and `PixelFilterElement` already
implements a `.secureBlur` mode that keeps nothing but the region's mean colour, with texture
generated from a seed rather than from the pixels. That model, that renderer and that argument
transfer to video unchanged; a mask gains a start and an end and nothing else.

Modes: `secureBlur` (default), `smoothBlur`, `pixellate`, `solid`, and **`highlight`** — the
inverse, dimming everything *outside* the region to draw the eye to it, which is `SpotlightElement`
from the screenshot editor with a time range added. Each is named for what it actually does. The video case adds one thing stills do not need — **follow a window**, driven by the
`windowMoved` events, so a sidebar stays covered through a whole demo without keyframing it by hand.

A mask that is set to follow a window and whose window disappears **stays put and stays opaque**
rather than uncovering what it was hiding. That is the only safe failure direction and it should be
a test.

---

## Phase 6 — Captions and keystrokes

### Transcription

`SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`, run over the mic track (or the
system track when there is no mic). `supportsOnDeviceRecognition` is checked first, and when it is
false the feature says plainly that on-device recognition is unavailable for the chosen language
and offers nothing — it does not fall back to the network. That is the whole reason this is the
implementation and not a nicer-sounding API.

`SFTranscriptionSegment` gives per-word `timestamp` and `duration`, which is exactly what the
karaoke rendering needs. `addsPunctuation = true`.

Output model:

```swift
struct Caption: Codable, Equatable, Identifiable {
    var id: UUID
    var words: [Word]                     // each with start, duration, text
    var start: TimeInterval               // derived, cached
    var end: TimeInterval
}
```

### Grouping words into caption lines

`CaptionGrouper` — pure, and this is where the quality is:

1. Break at a pause longer than 0.45 s.
2. Break at sentence-ending punctuation.
3. Otherwise accumulate up to `maxCharacters` (default 42) and at most `maxWords` (default 9).
4. Never leave an orphan of one word — merge it backwards.
5. Prefer breaking at a clause boundary (`, ; : and but so because`) when a break is needed
   mid-sentence.

The reference's lines — "you press command and just drag it", "down here and now we format it to",
"show US dollars." — are exactly this: short, breath-length, broken where a person would pause.

### Rendering

Karaoke highlighting, confirmed in every frame of the reference: spoken words in white, upcoming
words in grey (~#9A9A9A), switching at each word's `start`. `CaptionStyle`:

| Control | Options | Default |
|---|---|---|
| Font | System / Rounded / Mono / any installed | Rounded |
| Weight | regular … heavy | semibold |
| Size | 2 – 8% of canvas height | 4.2% |
| Spoken colour | picker | white |
| Upcoming colour | picker | 60% white |
| Background | none / solid / blur | solid #000 @ 78% |
| Corner radius | 0 – 24 | 14 |
| Padding | 0 – 32 | 16 × 12 |
| Position | top / centre / bottom + offset | bottom, 8% up |
| Max width | 40 – 100% of canvas | 72% |
| Highlight mode | word / line / none | word |

Text is laid out with Core Text into a cached `CGImage` per caption line, re-tinted per frame
rather than re-laid-out — laying out text 60 times a second for a line that changes once a second
is the obvious waste.

### The transcript editor

A panel listing every caption line with its timecode, editable inline. Fixing "shows" to "show"
must not re-run recognition, and re-timing must be possible by dragging a line's edges in the
timeline. Also: delete a line, merge two, split one at the cursor.

**A vocabulary field.** `SFSpeechRecognitionRequest.contextualStrings` takes words to bias
recognition towards — product names, library names, people's names, jargon. One text field labelled
for what it is ("Words to expect"), pre-filled with the project name. This is the difference between
a transcript that says "Sarvkrit" and one that says "sav credit", and it is three lines of code.

**Language** is chosen explicitly rather than guessed, from
`SFSpeechRecognizer.supportedLocales()` filtered to those that support on-device recognition —
showing a language we cannot actually run offline would be a promise we break at the last moment.
The default is the system language when it qualifies.

**Export SRT and VTT** alongside the video. Cheap, and it is what makes a recording accessible
somewhere other than the file we produced.

### Speaker notes

A per-project text panel, shown in the editor and **never rendered into the video**. Two uses, and
the second is the one that matters: notes about what still needs re-recording, and a script to read
from. When notes exist, an option shows them full-screen on a chosen display during recording — a
teleprompter — excluded from capture by `excludedBundleIDs` like everything else of ours.

### Keystroke display

Off by default; requests Accessibility on first enable (see the requirements note above).

Renders recent keys as pills — `⌘` `⇧` `K` — in a configurable corner, each appearing on keydown
and fading after 1.6 s, with repeated keys collapsing into a counter rather than stacking.

Keys are captured with `NSEvent.addGlobalMonitorForEvents(matching: .keyDown)` under Accessibility
trust — **not** through the shared `EventTapService`. That is the whole point of keeping this
feature off the `EventTapFeature` path: a global monitor observes without consuming, so nothing this
feature does can ever swallow a keystroke from the app the user is demonstrating.

**What is never recorded**: anything typed while the focused element is a secure text field (the
`FocusedRoleCache` check described under Files), and, when "modifiers only" is chosen, plain
characters.
The default is **modifier combinations only** — ⌘C, ⌃⇧R — because that is what a demo needs to
show, and recording every letter someone types is a different and much larger promise.

---

## Phase 7 — The long tail

- **Presets** — a named bundle of canvas + cursor + camera + caption settings, applied in one
  click. `BackgroundPresetStore` is the model to copy, including its "an unreadable file is logged
  and left in place, never overwritten" rule.
- **Annotations over video** — reuse `AnnotationElement` wholesale, with each element gaining a
  time range. Arrows, text, shapes, counters, spotlight, blur — all of it already exists and all of
  it is already tested; it needs a start and an end.
- **GIF export** — needs its own palette quantiser and dithering to not look terrible; treat it as
  a real piece of work, not a format flag.
- **Vertical / square templates** — 9:16 and 1:1 with the screen scaled and the camera enlarged, as
  a preset rather than a separate mode. Note that zoom levels tuned for 16:9 are wrong at 9:16 —
  `ZoomPlanner` targets a *fraction of the frame*, so it re-solves correctly when the aspect
  changes, and the vertical export must re-run it rather than reuse the landscape segments.
- **Device frames** — draw the recording inside a MacBook, iPhone or iPad bezel. A vector frame
  (paths and a screen rect, in the `BackgroundCatalogue` mould — data, not PNG assets, for the same
  reasons its comment gives), with colour variants. For a Mac recording the model can be detected
  from the hardware identifier and the display's aspect; for iPhone capture the device reports
  itself. Detection is a *default*, never a lock — the picker always wins.
- **Chapter markers** from `appActivated` events.
- **iPhone/iPad recording** — the device appears as an `AVCaptureDevice` over USB. A separate
  capture path, sharing the editor unchanged. **State the limits up front**: macOS cannot report
  finger taps the way it reports mouse clicks, so there is no cursor and no automatic zoom on an
  iOS recording. Manual zooms, background, masks, captions and trimming all work. Saying this in
  the UI when the source is a device is better than letting someone discover that the auto-zoom
  toggle does nothing.
- **`sarvkrit://` commands** — `record`, `stop`, `openRecording`, extending `CaptureURLCommand`.

---

## Coverage against the reference

Every feature found on screen.studio's site and changelog, and where it lands here. The point of
this table is that omissions are visible.

| Reference feature | Here |
|---|---|
| Screen / window / area recording | Phase 1.5 |
| Multi-display | Phase 1.5, cursor `isInside` in 1.2 |
| Fullscreen-app recording | Phase 1.5 (window mode, `includeChildWindows`) |
| Camera recording, 720p–4K | Phase 5 |
| Microphone recording | Phase 5 |
| System audio, all apps | Phase 5 (`capturesAudio`) |
| System audio, selected apps | Phase 5 (`AudioProcessTap`, already in the app) |
| Pause / resume | Phase 1.4 |
| Countdown | Phase 1.5 (`CountdownView`, exists) |
| Recording widget / HUD | Phase 1.6 |
| Recording recovery (fragmented MP4) | Phase 1.1a |
| Low disk space warnings | Phase 1.1a |
| Recording flags / markers | Phase 1.6 |
| Camera preview while recording | Phase 1.6 |
| Precise window sizing before recording | Reuses `WindowManipulator` (exists) |
| Area picker with grid guides, typed dimensions | Phase 1.5 |
| Hide desktop icons | Phase 1.1 (`CaptureOptions`, exists) |
| Auto gain control off | Phase 5 |
| Stereo microphone | Phase 5 |
| Automatic zoom on clicks | Phase 3.2 |
| Automatic zoom on typing | Phase 3.2 |
| Manual zoom ranges, duration | Phase 3.5 |
| Zoom speed / animation / instant | Phase 3.4 |
| Zoom level by number key | Phase 3.5 |
| Copy/paste zoom, apply to all | Phase 3.5 |
| Spring mass/tension controls | Phase 3.6 |
| Smooth cursor movement | Phase 2.2 |
| Cursor size, auto and manual | Phase 2.4 |
| Motion blur | Phase 2.3 |
| Click effects: ripple / shockwave / circle | Phase 2.5 |
| Click sounds | Phase 2.5 |
| Hide cursor when idle | Phase 2.6 |
| Cursor loop to start | Phase 2.7 |
| Cursor rotation when moving fast | Phase 2.5a |
| Shake-to-locate removal | Phase 2.5a |
| Enlarged-system-cursor detection | Phase 2.5a |
| Custom cursor sets | Phase 2.1 |
| Captured cursor bitmaps for non-system cursors | Phase 1.2 |
| Zoom starting at t=0 opens already zoomed | Phase 3.4 |
| Blended zoom across a cut | Phase 4 § clocks |
| Restart / discard a take | Phase 1.6 |
| Backgrounds: wallpaper / gradient / colour / image | Reuses `CaptureBackground` |
| Favourites, random, larger catalogue | Editor § inspector |
| Padding, inset, corner radius, shadow | Reuses `CaptureBackground` |
| Background blur | Reuses `CaptureBackground.Fill.blurred` |
| Aspect ratios incl. 9:16, 4:5, 1:1, custom | Reuses `AspectRatio`, extended |
| Crop, aspect-locked, numeric | Editor § transport |
| Device mockups, colours, models, auto-detect | Phase 7 |
| Camera shape, size, position, radius, shadow | Phase 5 |
| Camera fullscreen / hidden segments | Phase 5 § camera track |
| Camera fade in/out | Phase 5 |
| Camera background removal | Phase 6 |
| Volume normalisation | Phase 5 |
| Noise reduction | Phase 5 |
| Per-clip volume, mute | Phase 5 |
| Waveforms | Editor § timeline |
| Ducking | Phase 5 |
| Silence removal | Phase 4 |
| Background music | Phase 5 |
| Transcription, on-device | Phase 6 |
| Language selection | Phase 6 |
| Transcript editing | Phase 6 |
| Captions styling and position | Phase 6 |
| Word-level highlighting | Phase 6 |
| SRT / VTT export | Phase 6 |
| Speaker notes / teleprompter | Phase 6 |
| Keystroke display | Phase 6 |
| Keystroke timeline track | Editor § tracks |
| Trim, split, delete, ripple delete | Phase 4 |
| Speed per clip | Phase 4 |
| Copy/paste clip settings | Editor § timeline |
| Multi-track timeline | Editor § tracks |
| J/K/L, frame stepping, loop | Phase 4 |
| Timeline zoom, ⌘-scroll, pinch | Editor § transport |
| Masks, blur/obscure, custom shapes | Phase 5 § masks |
| Highlight mask | Phase 5 § masks |
| Presets, save / share / default | Editor § project management |
| Recent projects, duplicate, drag-drop | Editor § project management |
| Create project from an existing video | Editor § project management |
| Command menu ⌘K | Editor § project management |
| Auto-save, project recovery | Editor § project file, Phase 1.1a |
| MP4 up to 4K60, quality presets | Phase 1.9 |
| GIF with palette | Phase 7 |
| Copy to clipboard | Phase 1.9 |
| Export presets: web / social / editor | Phase 1.9 |
| Batch export | Editor § project management |
| Quick export after recording | Phase 1.7 |
| Files over 4 GB | Phase 1.1 |
| Raw file extraction | Editor § project management |
| Preview quality reduction | Editor § timeline |
| Motion blur on cursor / zoom / pan | Phase 2.3 |
| Antialiasing, texture caching | The renderer |
| Lazy waveforms | Editor § timeline |
| Audio scrubbing | Editor § timeline |
| Trim bubbles, click to undo a trim | Editor § timeline |
| Reset all trims and cuts | Editor § timeline |
| Multi-select, batch edits | Editor § timeline |
| Copy current frame as an image | Editor § timeline |
| `⌘/` shortcut sheet | Editor § timeline |
| Preview quality / performance / power saving | Editor § timeline |
| Per-clip hide cursor, disable smoothing | Phase 4 § clip model |
| Separate mic and system volume per clip | Phase 4 § clip model |
| Speed up typing segments | Phase 4 |
| Minimum clip / zoom duration | Phase 4 |
| Transcription vocabulary hints | Phase 6 |
| Browser chrome crop suggestions | Editor § transport |
| "Always keep zoomed in" | Editor § transport |
| Masks holding several rectangles | Phase 5 § masks |
| iPhone / iPad recording | Phase 7 |
| Device frames for iPhone/iPad | Phase 7 |
| Menu bar access | Feature § tray panel |
| Customisable shortcuts | Feature § shortcuts |
| **Shareable links, cloud hosting, comments, view counts** | **Excluded — see Non-goals** |
| **Licence keys, subscriptions, activation** | **Excluded — Sarvkrit has no tiers** |
| **Dock icon toggle** | N/A — `LSUIElement` with `ActivationPolicyLease` |
| **VPN / proxy handling** | N/A — no network code |

### Where this plan goes further

Parity is the floor, not the ceiling. Nine places where Sarvkrit should end up ahead, mostly because
the screenshot editor already solved the problem:

1. **Secure blur.** The reference's mask is a numeric blur amount. An ordinary blur is a linear
   convolution and is routinely inverted; `PixelFilterElement.secureBlur` already keeps nothing but
   a region's mean colour. For hiding an API key on video that is not a refinement, it is the
   difference between working and not.
2. **Masks that follow a window.** The reference states its masks are stationary and do not follow
   scrolling. We have `windowMoved` events; a mask pinned to a window stays put when the window
   does not.
3. **Real caption styling.** The reference offers size and visibility. We have font, weight, colour,
   background, radius, padding, position, width and highlight mode — because `TextElement` and
   `TextPreset` already exist.
4. **Silence removal.** The reference has none.
5. **Zoom on typing, not only on clicks.** The reference is explicit that a zoom with no click under
   it does nothing. Filling in a form is a demo too.
6. **Annotations.** Arrows, text, shapes, counters and highlights are Paused on the reference's own
   roadmap. `AnnotationElement` is shipped and tested here; it needs a time range.
7. **Auto Balance.** Choosing a background from the recording's own colours already exists.
8. **ProRes export and separate audio tracks**, for handing a recording to a real editor. The
   reference exports MP4 and GIF only.
9. **No account, no network, no export paywall.** The reference gates export behind a subscription
   and hosts shared links in its cloud. Sarvkrit contains no network code at all, and this feature
   must not be the thing that changes that.

---

## Verification

### Automated — `make test`

Pure logic, exhaustively, in the house style (no AV, no CG, no filesystem):

`ZoomPlannerTests` · `ZoomEaseTests` · `TimelineTests` · `CursorPathTests` (smoothing, click-snap,
shake removal, loop-back) · `CursorGlyphTests` · `ClickEffectTests` · `SilenceDetectorTests` ·
`TypingDetectorTests` · `CaptionGrouperTests` · `DuckerTests` · `LoudnessMeterTests` ·
`MaskGeometryTests` (including: a follow-a-window mask whose window vanishes stays opaque) ·
`CameraLayoutTests` · `StudioKeyRoutingTests` · `StudioProjectCodingTests` (round-trip +
forward-compat `unknown` passthrough) · `RecordingClockTests` · `RecordingRecoveryTests` (a
truncated fragmented file recovers, and the sidecars truncate to match) · `ExportPresetTests` ·
`StudioLibraryStoreTests` (age *and* size eviction)

Rendering, through the existing snapshot harnesses:

- `StudioRenderSnapshotTests` — a fixture project rendered at fixed times, written to
  `PreviewDirectory` under `make preview`, asserted differentially (zoomed ≠ un-zoomed, captions on
  ≠ off, cursor styles differ from each other).
- `StudioChromeSnapshotTests` — the editor window in both appearances. **Use the real off-screen
  `NSWindow` at (−30000, −30000)**, not the windowless `NSHostingView`: this UI is built on
  semantic colours and stock controls, and the windowless helper renders those transparent and
  renders AppKit controls as placeholder blocks. `TrayPanelRenderTests` documents both traps.
- `StudioRendererParityTests` — the software and GPU backends agree within a per-channel tolerance,
  and the geometry assertions (cursor centroid, screen-rect bounds, caption baseline) are exact.
  Geometry is where the bugs are.
- `StudioRenderGeometryTests` — the same `render(project:at:)` call used by preview and export
  produces the same transform for the same time. This is what keeps "preview matches export" true;
  it is one function, so this is cheap to assert and catches any future fork immediately.

Hardware-touching code goes behind `ScreenRecording` and is stubbed by `StubScreenRecordingService`,
which replays a fixture bundle. No test may open a real `SCStream` or `AVCaptureSession` — the test
host lives inside `Sarvkrit.app` and would prompt for TCC or hang. A `CIContext` *is* fine
(`PixelFiltersTests` already uses one) provided it is the `.software` backend, so the result does
not depend on which GPU ran it.

Remember `AppIdentity.isRunningTests`: nothing here may write the pasteboard, post events or open a
window during a test run.

### Manual

0. In `sarvkrit_wt/studio` (or the phase's own worktree): `xcodegen generate`, and confirm with
   `pgrep -lf "Sarvkrit.app/Contents/MacOS/Sarvkrit"` that no other worktree's build is running.
1. `make test` — the whole suite, with a running Sarvkrit quit first.
2. `make preview` — open `build/preview/` and look at the rendered frames. Several classes of bug
   in this feature (a cursor one pixel off, a caption clipped, a shadow tracing square corners) are
   invisible to assertions and obvious in a picture. This is why the harness exists.
3. `make install && open /Applications/Sarvkrit.app` — permissions are keyed to location, and
   Screen Recording will need the relaunch dance on first grant.
4. Record a 30-second demo of a real app with clicks, typing, scrolling and a window drag.
5. Confirm, in order: the recording opens; auto-zoom found the click clusters and not the idle
   stretches; the cursor is sharp at 2.5× and lands exactly on what it clicked; captions match the
   speech and highlight word by word; trimming the ends does not move the zooms; exporting 1080p
   H.264 produces a file that matches the preview frame for frame.
6. ⌃⇧⎋ during recording clears everything.
7. Revoke Screen Recording in System Settings and confirm the feature says so rather than
   producing black frames.

---

## Sequencing note

Phase 1 is the risky one and it is the one to build first, in full, including the clock test. The
zoom planner and the cursor renderer are pure functions over data — they can be written and tested
before there is a single frame of real video, and they should be, because they are where the taste
lives and taste needs iteration.

Everything after Phase 3 is additive: a project with no captions, no camera and no audio renders
correctly through the same pipeline, so each later phase adds a layer rather than changing one.


