# Screen Studio — Exhaustive Feature Inventory (research for clone-implementation spec)

Research date: 2026-09-05. Current shipping version at time of research: **3.7.5-4595** (released 2026-08-05).

Confidence markers used throughout: **[P]** = primary source (screen.studio / its docs / changelog / privacy policy), **[R]** = reverse-engineered from a third-party tool that drives the real app, **[3]** = third-party review (lower trust), **[BETA]** = on the vendor's own beta/roadmap, not shipped.

---

## 0. Source URLs

Primary:
- https://screen.studio/ (homepage; pricing lives at the `#pricing` anchor — there is **no** `/pricing` page, it 404s)
- https://screen.studio/guide (docs index, ~60 articles)
- https://screen.studio/changelog (full history back to 2.5.7, May 2023)
- https://screen.studio/roadmap
- https://screen.studio/download
- https://screen.studio/legal/privacy-and-cookie-policy
- https://screen.studio/dashboard (account/licence/shareable-link management)
- https://hub.screen.studio/ (public feedback board), https://hub.screen.studio/changelog (empty)
- https://preview.screen.studio/guide/... (a preview docs mirror; content matched production)

Guide articles cited individually in the sections below (all under `https://screen.studio/guide/<slug>`).

Reverse-engineering sources (high value, they drive the actual shipping binary):
- https://github.com/HyperfocuSam/screenstudio-agent — CLI driving Screen Studio over Chrome DevTools Protocol; verified against 3.7.3-4475. README + `src/cli/commands/*.ts` + `skills/screenstudio-cli/SKILL.md`
- https://github.com/ShawnPana/screenstudio-cli — upstream of the above
- https://codeforcreatives.com/blog/reverse-engineering-file-formats-with-claude/ — `.screenstudio` bundle layout
- https://github.com/crafter-station/open-screenstudio — an open clone attempt (README only, no internals)
- https://www.raycast.com/screen-studio/screen-studio — official Raycast extension

Third-party reviews consulted (treat pricing claims in these as **stale/wrong** — see §21):
dockshare.io, denshub.com, saastreats.net, datastudios.org, creatoreconomytools.com, alternativeto.net news posts for 3.0 / 3.1 / 3.2.

---

## 1. Product identity and platform

- macOS-only screen recorder + opinionated post-production editor. No Windows/Linux. "Is the Windows version ready?" is a standing FAQ item on the homepage. [P]
- Author: Adam Pietrasiak (indie/small team). Payments via **Lemon Squeezy**. Support: team@screen.studio.
- **System requirements** [P] (`/guide/system-requirements`):
  - macOS **Ventura 13.1 or later**
  - Apple **M1 or later preferred**; Intel supported on MacBook Pro 2018+, MacBook Air 2020+
  - **8 GB RAM minimum**
  - Separate Apple Silicon and Intel builds are distributed (from `screenstudioassets.com`). A crash affecting Intel machines was fixed in 2.22.9; 3.4.2 added "ensure correct app version architecture for device".
- Per-feature OS floors:
  - System audio recording requires macOS 13.0+ (2.16.7 fixed a UI state that let you try on older macOS).
  - Recording-control widget is excluded from the capture only on **macOS 12.3+** (`/guide/managing-recording-in-progress`).
  - **iPhone Mirroring** capture requires **macOS Sequoia 15+** (`/guide/iphone-mirroring`).
  - **Apple Speech Recognition** transcription engine requires **macOS 26.0+** (`/guide/captions`).
- A **beta channel** exists as a separate download (`/download`).

---

## 2. Architecture (reverse-engineered — important for a clone)

Evidence: screenstudio-agent drives the shipping app through `--remote-debugging-port`. [R]

- **Screen Studio is an Electron app.** It accepts `--remote-debugging-port=9222`, exposes `/json` page listing, and its renderer is inspectable over CDP.
- Renderer is **React** — the CLI walks `document.getElementById("root")[__reactContainer…]`'s fiber tree looking for components with `memoizedProps.label` of `"Record display"`, `"Record window"`, `"Record area"` and calls their `onClick`.
- State is **MobX**: `$projects` is an "MobX ObservableMap of all open projects"; `window.$project` is the active one. The SKILL warns "Screen Studio can crash if MobX state becomes inconsistent."
- Main↔renderer IPC is **electronTRPC** — `bridge.client.query/mutation/subscription`. Known procedures include `capture.finish`. Notably **no** state query exists: `capture.state`, `capture.status`, `capture.getState`, `capture.isRecording`, `capture.info`, `capture.current`, `capture.get`, `recording.state` all return *"No query-procedure on path"*.
- Renderer has **Node integration disabled** (`require`/`process`/`module`/`__dirname` undefined); the privileged preload bridge is still reachable over the port.
- `electronEnv` global exposes app version and flags.
- Undo/redo is an explicit snapshot API: `project.history.update()` is called *before* each mutation; `project.canUndo` / `project.canRedo`.
- `project.serialize()` returns project JSON. `project.updateConfig({...})` applies config live.
- The **preview canvas is a DOM canvas element** rendered at 2x — the CLI screenshots "just the canvas element from Screen Studio's preview renderer at 2x resolution". So preview compositing is done in the renderer (WebGL/Canvas), not by a native player.
- The recorder core is separate and native-ish: logs land in `polyrecorder.log`, and changelog entries repeatedly say things like "updated the version of the core of Screen Studio recorder", "reworked recorder core library", "beta experimental: used a different version of core of our recorder".
- **There are two capture engines, and the user can switch.** 2.25.2 [P]: *"Speaker notes feature is disabled when Screen Capture Kit is turned off (cannot be used in this case)."* A user-facing toggle to disable **ScreenCaptureKit** therefore exists, implying a legacy fallback capture path (almost certainly CGDisplayStream/AVFoundation) for older macOS or problem hardware. A clone should plan for the same split — and note that window-exclusion features (speaker notes, the recording widget) only work on the SCK path.
- **App UI is English-only.** No evidence anywhere of UI localization; "multi-language" in Screen Studio refers exclusively to caption/transcript languages (§12).

---

## 3. Project file format — `.screenstudio` bundle [R] + [P]

`.screenstudio` is a **macOS bundle (a directory Finder shows as one file)**, not a single file. `/guide/sharing-your-project` [P] confirms: *"Some applications or cloud services that don't recognize this extension might treat it as a folder containing separate files"* and recommends right-click → Compress before sharing.

Root level:
- `meta.json` — version number, required version, creation date
- `project.json` — the edit document; Screen Studio writes it when the bundle is opened
- `recording-markers.json` — recording flags (see §5)
- `recording/` — the raw capture

Inside `recording/`:
- **Hundreds of `.m4s` fragmented-MP4 segments plus `.m3u8` playlists** — i.e. the recorder writes HLS-style fragmented segments live, which is how it survives crashes and supports pause/resume and recovery.
- `channel-<N>-display-<M>.mp4` — a flattened per-channel screen video. The CLI globs `channel-*-display-*.mp4` because the channel number varies per recording. This implies **multiple video channels** (screen, camera, external device) each tagged by display.

> **Caveat on the two media layouts.** The `.m4s`/`.m3u8` segment list comes from the codeforcreatives teardown; the `channel-N-display-M.mp4` flat file comes from screenstudio-agent verified against **3.7.3-4475**. These are different sources and possibly different app versions. They may coexist (segments written live, then muxed into a flat per-channel MP4 on finish — which would explain both the recovery behaviour and the CLI being able to hand a single file to ffmpeg), or one layout may predate the other. Do not treat this as one verified layout.
- `.m4a` audio files (microphone / system audio as separate assets)
- `cursors/` — **cursor images captured during recording** (every distinct system cursor bitmap seen)
- `metadata.json`
- `keystrokes-0.json`
- `mouseclicks-0.json`
- `polyrecorder.log`

Event schemas (read directly by the CLI's `analyze` command) [R]:
```
keystrokes-0.json : [{ processTimeMs: number, character: string, type: string }, …]
mouseclicks-0.json: [{ processTimeMs: number, button: string, x: number, y: number }, …]
```
Mouse *positions* are a separate stream from clicks (the app exposes `recording.mouseEvents` and `recording.hasCursor`).

`project.json` is hand-editable: *"If you corrupt state, it persists to disk. You may need to manually edit `project.json` inside the `.screenstudio` bundle to fix it."*

Projects **auto-save** (added 2.25.10). Default projects folder is `~/…Screen Studio Projects…` (observed as `~/Screen Studio Projects/`); the location is configurable in Settings (added 2.22.0). Save = `⌘S`, Save As = `⌘⇧S`.

**There is no project library / browser UI.** Projects are plain bundles in a folder. Discovery routes are: **File → Open Recent** (the list is existence-checked and self-updating, 2.22.0; large project icons in it were fixed in 3.5.1), the recording modal, the **system tray menu** ("open projects from the system tray menu", 2.26.0), **drag & drop** onto the editor or menu-bar icon (2.26.0), and Finder. The web **dashboard** manages licences, devices and shareable links only — **not** projects.

---

## 4. In-memory project object model [R]

This is the closest thing to a schema for a clone. All from screenstudio-agent's `state.ts`, `zoom.ts`, `slice.ts`, `mask.ts`.

```
project
  .name .id .path
  .playbackDurationMs        // duration of the EDIT
  .isDirty .canUndo .canRedo .hasAudio
  .config                    // 68 keys, flat, primitives/arrays/objects
  .scenes[]                  // in practice one scene, scenes[0]
  .recording
  .history.update()
  .updateConfig({...}) .serialize()

recording
  .recordingPath             // path to recording/ inside the bundle
  .durationMs
  .mode                      // display | window | area | device
  .hasCamera .hasAudio .hasCursor .hasKeystrokes .hasMicrophone .hasSystemAudio
  .keystrokes[] .mouseEvents[]

scene
  .id .name
  .slices[]
  .zoomRanges[]
  .masks[]
  .update({ zoomRanges, masks, … })
  .findSliceAtTime(ms)
  .addMaskAt(ms) .updateMask(id, {...}) .removeMask(id)
  .addZoomRangeAt(ms)        // creates a ~3s default range; known to overwrite adjacent ranges

slice                        // a timeline clip
  .id .index
  .sourceStartMs .sourceEndMs        // position in the ORIGINAL recording
  .playbackStartMs .playbackEndMs    // position in the EDITED output
  .speed                             // derived
  .timeScale                         // STORED value; timeScale = 1 / speed  (4x → 0.25, 0.5x → 2)
  .volume
  .systemAudioVolume                 // separate from .volume — mic and system audio are independent per slice
  .hideCursor                        // per-slice cursor hiding
  .splitAt(ms) .remove() .mergeWithNext()
  .canSplitAt(ms)
  .update({ sourceStartMs, sourceEndMs, timeScale, volume, hideCursor, … })

zoomRange
  .id                        // 10-char alphanumeric
  .type                      // "auto" | "manual"
  .isAuto .isManual
  .zoom                      // magnification multiplier, e.g. 2, 2.5, 3
  .startTime .endTime        // source ms  (read back as sourceStartTime/sourceEndTime)
  .duration
  .manualTargetPoint         // { x: 0-1, y: 0-1 } normalised to the FULL recording frame
  .snapToEdgesRatio          // CLI writes 0.25 on creation
  .glideDirection            // null | direction — CLI writes null
  .glideSpeed                // CLI writes 0.3 on creation
  .isDisabled                // disable without deleting
  .isSystem                  // app-generated vs user — CLI writes false
  .hasInstantAnimation       // true = cut to the zoom with no animation ("Instant Zoom") — CLI writes false
```
> **Caveat on those numbers.** `snapToEdgesRatio: 0.25`, `glideSpeed: 0.3`, `glideDirection: null`, `isSystem: false`, `hasInstantAnimation: false` are the values screenstudio-agent's zoom-construction template writes when creating a new zoom. They very likely mirror the app's own defaults (the template was built by observing real zooms), but they were **not** read out of the app's default config — treat them as strong hints, not verified defaults. Same for mask `blur: 20`.
```

mask
  .id
  .type                      // "sensitive-data" (blur mask); highlight is the other type
  .startTime .endTime        // source ms (read back as sourceStartTime/sourceEndTime)
  .bounds                    // ARRAY of { x, y, width, height } — multiple rects per mask
  .blur                      // numeric blur amount, CLI default 20
```

**Coordinate spaces** (documented explicitly in the agent SKILL) [R]:
- *Recording coordinate space* — what the metadata reports, e.g. `2560 × 1353`. **Mask `bounds` are in this space.**
- *Video file pixel space* — the actual raw `.mp4` dimensions, e.g. `4096 × 2164`.
- They differ by a `recordingScale` factor (observed **0.625**): `video_px = recording_px × (1 / 0.625) = × 1.6`.
- Zoom `manualTargetPoint` is normalised 0–1 so it is space-independent.
- Zoom crop maths: at zoom level Z the viewport is `(videoWidth/Z, videoHeight/Z)` centred at `(targetX × videoWidth, targetY × videoHeight)`, and **the crop is clamped to the video bounds** — so `x`/`y` of 0 or 1 pin the viewport flush to an edge rather than running off it. At 2× on a 4096×2304 source the visible area is exactly 2048×1152, i.e. one quadrant-pair. [R]

`config` is **68 flat keys** [R]. Confirmed key names seen in the wild: `backgroundColor`, `cursorSize`, `hideCursor`. The rest map to the sidebar controls enumerated in §8–§13.

---

## 5. Recording

### 5.1 Capture targets [P]
Opened via a **recording picker modal** (auto-shown at launch; reopen with **`⌥⌘↩`**, or via the menu-bar icon, or the system tray menu). Modes:

| Mode | Behaviour |
|---|---|
| **Display** | Move the mouse to the target display and click to confirm. Multi-display supported. If only one display, it is auto-selected (2.8.1). Ultra-wide/ultrawide handled specially — video is scaled down to avoid crashing the encoder (2.26.0), and 4K export from ultrawide with auto aspect was a fixed bug (2.25.10). |
| **Window** | Click a window to pick it, or **right-click the `Window` button for a list**. Full-screen apps are selectable (2.6.3) but the docs advise using `Display` for a full-screen app. Windows can be **resized precisely before recording** (2.6.2) with size presets including smaller sizes and a 16:10 preset (2.6.4). The chosen window is focused before recording starts (2.10.8) — this needs Accessibility permission. |
| **Area** | Drag the area, or **type exact dimensions**. Guide lines appear while picking (2.26.0); a **25% / 50% / 75% grid** is shown (2.25.18); the input form dodges the centre of the area so you can align on centre. Area dimensions can be **saved and reused as an aspect ratio** (2.25.10). Max dimensions are surfaced (2.25.2). |
| **iPhone / iPad** | See §5.6. |

Other picker affordances: "Start recording" button sits next to the picked target (2.10.8). Unrecorded area is dimmed; the dim can be disabled (2.20.0). Recording can be started, and projects opened, from the **system tray menu** (2.26.0).

### 5.2 Camera & microphone at capture time [P] (`/guide/webcam-microphone`)
- **Camera**: click the camera icon → pick device. A live preview window appears. *"The preview remains visible during recording but doesn't appear in the final output. Screen areas covered by the preview are still captured."* Right-click → **"Hide camera preview"**. 3.4.7 added a **full-frame camera preview before recording**.
- **Camera capture quality**: **720p / 1080p / 4K** selectable ("High quality camera format", 3.4.5; 1080p and 4K support landed 3.2.2). Ideal webcam FPS set to **30** (3.4.10).
- **Microphone**: click the mic icon → pick device. *"The white bar under the microphone icon shows if your microphone is working and collecting sound."*
- **Stereo microphone support** added 3.4.7; a "stereo mode option for microphones" was fixed in 3.7.1. Historically the exported mic stream was converted to **mono** (2.25.2) and stereo mix was corrected in 2.22.0.
- **Auto gain control is disabled** by default (2.25.10) with an option to toggle it — important, macOS AGC otherwise changes input volume mid-take.
- Camera without a microphone is allowed; a warning appears if you select a camera and no mic (2.22.14).
- Warning shown if the mic is muted because the laptop lid is closed (2.22.0).
- **macOS Video Effects** pass through and are controlled from the system menu-bar camera icon, not from Screen Studio: **Background (wallpapers), Portrait (background blur), Studio Light** (`/guide/camera-settings`), and **Reactions** (`/guide/reactions-`) which must be turned **off** there to keep emoji/hand-gesture effects out of a recording. Screen Studio has **no built-in background blur** of its own in the shipping version.

### 5.3 System audio [P] (`/guide/recording-system-audio`)
- Click the **`system audio`** button, then choose **all apps** or **a selected group of apps** — "the rest of them will be ignored". Per-app system-audio capture is a real feature, not just a global tap.

### 5.4 Recording controls in progress [P] (`/guide/managing-recording-in-progress`, `/guide/starting-finishing-the-recording`)
- A floating **recording control widget** with: **finish**, **pause**, **resume**, **restart**, **delete/cancel**, plus an **elapsed-time counter**.
- Right-click the widget → **"Hide current recording control"**. On macOS 12.3+ the widget is excluded from the captured video. (3.0.1 explicitly "removed recording controls from recording output".)
- **Pause/resume shipped in 3.2.0** (April 2025) along with a **keyboard shortcut for pausing**.
- Four ways to stop: the widget's `Stop Recording` icon; the **menu-bar icon** (noted as possibly hidden behind a MacBook notch); **right-click the Dock icon → `Finish Recording`**; or the **global Start/Stop shortcut** set during onboarding and editable in Settings.
- A **`Magnetic multifunction button`** was added in 3.5.0.
- **Countdown**: a countdown runs between the record click and the first frame — the docs don't state the duration, but measurement by screenstudio-agent puts the gap at a consistent **~4.2 s** from click to first frame, of which ~1.6 s is after the picker closes. [R] Countdown bugs appear in the changelog (2.8.1 "avoid incorrect timeout error stopping recording countdown"; 2.6.3 freeze on full-screen apps).
- Low-disk-space checks before and during recording; friendly error codes; project **recovery** if a recording stops unexpectedly (2.26.0, 3.2.0 "improved recording recovery system").
- Only one recording session at a time is enforced (3.0.0-3181).
- **Hide Dock icon**: Settings → General → **"Hide Dock Icon"** — hidden when no project is open and no recording is running (`/guide/hiding-dock-icon`).
- **Notifications**: suppressed by default. To let them through, enable macOS System Settings → Notifications → **"Allow notifications when mirroring or sharing display"** (`/guide/capturing-notifications`).

### 5.5 Recording flags [P] (`/guide/recording-flag`)
- Press **`⌃⌥⌘F`** (customisable, Settings → Shortcuts → "Create recording flag") during a take to drop a marker. Flags appear on the editor timeline. Persisted as `recording-markers.json`.

### 5.6 iPhone / iPad [P]
Two distinct paths:

**A. Direct device capture** (`/guide/recording-iphone-ipad`) — since 2.15.3 (July 2023):
- Over **USB cable**; *"USB-C to Lightning cable is strongly recommended instead of USB-A to Lightning"*; docking stations discouraged; connect directly.
- Unlock the device first, trust the Mac when prompted, and **don't lock the device during recording**.
- **Audio from the iPhone itself** is recordable since **3.2.0**. Mac mic and webcam can be recorded simultaneously.
- **Device mockups/frames**: auto-detected model, changeable in the editor ("Device frame" tab), with **colour variants** per model; mockups can be **disabled entirely** (2.25.2). Mockup library seen in the changelog: iPhone 11, 12, 13, 14, 15 (all models' bezels), 16, 16 Plus, 16 Pro, 17 Pro, 17 Pro Max, iPhone Air; iPad Pro 11", iPad Pro 12, horizontal iPad mockups. Device list is ordered chronologically (3.5.1). Corner radius is matched to the real device (2.26.0). Rotating the device mid-recording is handled (2.25.2).
- **Hard limits**: *"Screen Studio cannot record your finger taps the same way it can record your mouse clicks and movement."* Therefore **automatic zooms are not supported** and **no cursor is drawn**. Workaround suggested: pair a Bluetooth mouse — but *"Screen Studio will not be able to make its movement smooth like on desktop recordings."*

**B. iPhone Mirroring capture** (`/guide/iphone-mirroring`) — added 3.5.0:
- Requires **macOS Sequoia 15+** and Apple's iPhone Mirroring app.
- You record the **iPhone Mirroring app's window** using normal *Window* mode; Screen Studio then still offers the **"Device frame"** tab to skin it as an iPhone.
- Mic and webcam can be layered on.

### 5.7 Importing existing video [P] (`/guide/creating-project-from-existing-video`)
- **File → "Create project from video…"**. Accepts **.mp4** (2.25.18) and **.MOV** (3.2.0). Audio is carried across if present.
- Everything visual works (zooms, background, etc.). **Unavailable**: mouse-cursor animations and the selfie camera — because those come from capture-time metadata that an imported file doesn't have. (2.26.0 explicitly hardened against crashing "if there are no cursors, e.g. when importing external video".)

### 5.8 Speaker notes / teleprompter [P] (`/guide/speaker-notes-`) — since 2.18.1
- Recording modal → settings icon → **"Show Speaker Notes"**.
- Start with **"Start Prompter"** or **`⌘⌥.`**.
- Settings (top-right of the notes window): **scrolling speed** (a faster option added 3.4.4), **opacity**, **font size**.
- Notes are invisible in the recording *even though they cover what you're recording* — this is a real compositing exclusion, not just a window level. Consequently the feature is **disabled when ScreenCaptureKit is turned off** (2.25.2), which strongly implies it relies on SCK's window-exclusion list.
- Visible in fullscreen presentations (3.1.0); visible when using DisplayLink (3.4.6).

### 5.9 Resolution / frame rate / HDR
- **Export** is stated at up to **4K 60 fps** [P, homepage]. Frame-rate choices at export are **60** vs **24–30** [P, `/guide/explanation-of-export-settings`].
- Capture side: recorded display FPS is detected and displayed (rounded up, 2.22.0). Retina is handled via a `recordingScale` factor (0.625 observed) between recording coordinate space and the raw file's pixel space [R] — i.e. the raw file is captured at higher-than-logical resolution and the edit model works in logical points.
- **No HDR.** Nothing in any primary source mentions HDR capture or export; the app targets SDR H.264-class MP4. Treat HDR as unsupported.
- **No 120 Hz / ProMotion capture** — 60 fps is the ceiling. [3, but consistent with all primary material]

### 5.10 macOS permissions required [P] (`/guide/setting-up-permissions`)
On first launch it requests **Accessibility**, **Camera**, **Microphone**, and **Screen Recording**. Accessibility is specifically for **focusing and resizing recorded windows** (2.16.6 added an explicit toggle for that in recorder settings, and 2.10.8 added clearer prompts). Keystroke capture also implies an input-monitoring/event-tap path, though the docs don't name it separately.

---

## 6. Captured metadata (the thing that makes Screen Studio Screen Studio)

**Confirmed: the cursor is NOT baked into the recorded video.** Primary-source quote, changelog 2.18.1 [P]:

> "raw screen recording file will not include your mouse cursor as it is not directly recorded by Screen Studio — it is re-added later basing on your mouse position data."

What is captured alongside the video, per the bundle contents and the runtime object model:

| Data | Where | Notes |
|---|---|---|
| **Mouse positions** (continuous) | a JSON file in `recording/`; surfaced at runtime as `recording.mouseEvents` | Filename **not confirmed** — only `keystrokes-0.json` and `mouseclicks-0.json` are named by any source. The `-0` suffix implies a per-channel/per-display index, so expect something like `mousemoves-0.json`. Used for smoothing, auto-zoom panning, cursor re-rendering |
| **Mouse clicks** | `mouseclicks-0.json` → `{processTimeMs, button, x, y}` | Button identity is captured, so left/right clicks are distinguishable. Drives auto-zoom and click effects |
| **Keystrokes** | `keystrokes-0.json` → `{processTimeMs, character, type}` | Drives the on-screen shortcut overlay AND typing-segment detection |
| **Cursor bitmaps** | `recording/cursors/` | The actual system cursor images encountered, so the correct arrow/I-beam/pointer/resize cursor is re-drawn. Texture caching added 2.22.16; "support for system cursor variants" 3.4.7; missing-cursor fallback 3.2.3 |
| **Cursor type changes** | implied | There's an "Optimize original cursor types" toggle that smooths rapid type transitions, and a fixed bug where the cursor stayed a pointer after clicking a link |
| **Recording flags** | `recording-markers.json` | User-dropped markers |
| **Device/frame metadata** | `metadata.json` | Frame size, `recordingScale`, mode, device model for iOS |
| **Channel/display mapping** | filenames `channel-N-display-M.mp4` | Multi-channel, multi-display aware |
| Capability flags | `recording.has{Camera,Audio,Cursor,Keystrokes,Microphone,SystemAudio}` | |

Not captured: **window bounds / app-switch events**. No evidence anywhere for these; auto-zoom is purely click-driven (see §7).

---

## 7. Automatic zoom

### 7.1 How it decides [P] (`/guide/auto-zoom`)
> "The Auto zoom option focuses on the areas where clicks occurred during your recording. It automatically detects the click positions and zooms in on those areas."

And the crucial constraint:
> "if you add auto-zoom where no mouse click occurs, it will not zoom to any area."

So: **the trigger is a mouse click, full stop.** Not window focus, not text entry, not app switching. Zoom ranges are created automatically at capture/import time and each is typed `auto` or `manual`. (An `isSystem` boolean exists on the model; that app-generated zooms set it `true` is my inference from the field's existence, not something observed.) An `auto` range resolves its target from the clicks inside its own time range; a `manual` range uses a fixed `manualTargetPoint`.

Once zoomed, the viewport **follows the cursor** — panning is driven by the mouse-position stream, with `glideSpeed` (default **0.3**) and `glideDirection` controlling the follow, and `snapToEdgesRatio` (default **0.25**) pulling the frame to screen edges so you don't get a sliver of desktop. There is an "Always keep zoomed in" toggle (see §9) and a fixed bug for "following cursor when zooming" (3.5.0).

### 7.2 Zoom parameters [R]/[P]
- **`zoom`** — magnification multiplier. Manual creation defaults to **2**; values like 2, 2.5, 3 are normal. The UI exposes a zoom-level control at the top of the zoom editor (moved there in 2.25.18).
- **`manualTargetPoint` {x, y}** — normalised 0–1 over the full recording frame; UI shows it as a draggable **purple dot** in the preview. The picker **displays the % values being picked and snaps to 50% within ±1%** (2.25.18).
- **Duration** — drag either edge of the zoom on the timeline. **Minimum zoom duration was reduced from 1 s to 0.1 s** (2.25.30); an earlier change had *increased* the minimum to 1 s (2.25.10).
- **`hasInstantAnimation`** — **Instant Zoom** (`/guide/instant-zoom`): cut straight to the zoom with no animation. Exposed as a toggle in the zoom settings panel and also as an option in Animations (3.4.4).
- **`isDisabled`** — right-click a zoom → **`Disable`** or **`Remove`** (disable-without-delete added 2.11.1).
- **`glideSpeed`** — exposed to automation; the UI-visible "glide options" were **removed from the UI layer in 2.22.0** but the property survives in the model.

### 7.3 Zoom editing UX [P]
- Zooms live on their own **zoom track** in the timeline. The track stays active even when empty (2.25.18).
- **Set zoom level with number keys `0–9` while hovering a zoom** (2.12.5).
- **"Apply zoom level of one zoom to all other zooms"** (2.12.5), with a toast confirming the apply-to-all (2.25.18).
- **Duplicate** a zoom (2.10.6); duplication is blocked if there isn't room before the next zoom (2.25.10).
- **Copy/paste zoom ranges and slice settings** (2.25.18 / 2.26.0).
- **Multi-select with ⌘-click, then batch actions on multiple zoom ranges** (2.25.18).
- If the first zoom starts on frame 0, the video **starts already zoomed** rather than animating in (2.11.2).
- Cutting the video mid-zoom **blends** the zoom/cursor animation correctly rather than popping (2.25.2).
- Disabling automatic zoom creation: **Settings → Recording → "Create zooms automatically"** (`/guide/disable-automatic-zooms-`). A second, related label appears on the feedback board as Settings → Editing → *"Create initial zooms automatically"*. Also, vertical mode has an "always on" zoom that can be separately disabled (2.17.12).
- `scene.addZoomRangeAt(ms)` creates a **~3-second** default range and is known to overwrite adjacent ranges; the robust path is replacing the whole `zoomRanges` array. [R]
- **No shortcut to drop a zoom during recording** — that's an open feature request ("Manual zoom by shortcut", In Review, 6 upvotes) at hub.screen.studio.

### 7.4 Easing / animation engine
- **Spring physics**, not bezier easing. The changelog references "object mass" ("fixed infinite animation simulation if 'object mass' is set to 0"), "auto number spring simulation", and "properly simulates springs that are 'slow' to move without stopping the simulation too quickly". The animations engine core was **rewritten in 2.25.2** for performance and export speed.
- **Screen animation style** (`/guide/animations`), advanced: **`Focused`** — "stabilizes quickly for readable content" — vs **`Smooth`** — "fluid motion suited for creative presentations".
- **Motion blur** — see §8.

---

## 8. Cursor

### 8.1 Core model
Cursor is **re-rendered at composite time from captured positions plus captured cursor bitmaps** (§6). This is why cursor size, style, smoothing and hiding are all post-recording decisions, and why they're unavailable on imported video.

### 8.2 Controls [P] (`/guide/cursor`, `/guide/animations`, `/guide/mouse-click-sound`)

Standard:
| Control | Type | Notes |
|---|---|---|
| **`Hide cursor`** | toggle | Removes the cursor entirely |
| **`Cursor size`** | slider/number | `cursorSize` config key; e.g. `2.0` |
| **`Cursor type`** | picker | **macOS** or **Touch** styles, plus **custom cursor sets** (3.0.0) — "a large collection of cursor sets", incl. a **macOS Tahoe cursor set** (3.4.8) auto-selected on matching OS, **Halloween cursor set** (3.5.0), high-resolution **Figma cursors** (2.18.1). Missing cursors for older macOS added (3.4.8); fallback for a missing custom cursor (3.2.3). Hover-preview of cursors in the sidebar (2.25.2) |
| **`Always use default system cursor`** | toggle | Ignore all other cursor types (2.7.7) |
| **`Hide cursor if it's not moving`** | toggle | Auto-hide when idle (2.14.0) |
| **`Loop cursor position`** | toggle | Near the end of the video, the cursor returns to its position at the start — makes a clip loop seamlessly (2.14.0) |

Advanced (behind an `Advanced` disclosure):
| Control | Notes |
|---|---|
| **`Rotate cursor while moving`** | Slight rotation at speed (2.7.3) |
| **`Stop cursor movement at the end of the video`** | |
| **`Remove cursor shakes`** | Detects and removes shakes caused by external accessibility apps controlling the mouse (2.17.12) |
| **`Optimize original cursor types`** | Smooths rapid cursor-type transitions; can be disabled (2.20.0) |

Per-slice:
- **`Hide mouse cursor`** — right-click a timeline fragment (`/guide/hiding-the-cursor-in-specific-sections`); model field `slice.hideCursor`. Shipped 3.1.0.
- **`Disable smooth mouse movement`** — per-fragment toggle in cursor settings; removes interpolation so dropdown-menu interactions read accurately (`/guide/disable-smooth-mouse-movement`).

### 8.3 Smoothing & motion blur [P]
- **`Cursor animation style`**: **`Smooth`**, **`Medium`**, **`Rapid`**, **`None`** — four discrete presets, not a slider.
- **Motion blur**: an intensity **slider**, with three independent advanced channels:
  - **`Cursor movement`** — blur on the cursor itself
  - **`Screen zooming in`** — blur during zoom in/out
  - **`Screen moving`** — blur while panning under a zoom
  - The motion-blur engine was **rewritten in 2.25.2** "for more accurate results and better performance".
  - Preview quality setting can **disable motion blur in the preview** for smoother scrubbing (§16).

### 8.4 Click effects [P]
Three named effects, added over time:
- **Ripple** (2.25.2, with an explicit enable/disable UI; weakened in 2.25.25)
- **Circle** (2.25.25)
- **Shockwave** (2.26.0)
- 3.0.0 grouped these as "custom cursors and click effects". Ripple is being **reworked** in the current beta.
- **Mouse click sound effects** (3.3.0): editor → **`Cursor`** tab → **`Click sound`** section → choose from a set of click sounds (previewable) and set a **volume**.

### 8.5 Spotlight / highlight
There is **no cursor spotlight/vignette that follows the mouse**. The closest shipping feature is the static **Highlight** mask (§14) which dims everything outside a fixed rectangle for a fixed time range.

---

## 9. Background / canvas [P] (`/guide/background`, `/guide/aspect-ratio`, `/guide/cropping-the-recording`)

### 9.1 Background type
- **Wallpaper** — a large curated library: macOS native wallpapers (Sonoma 2.10.1, Sequoia 2.25.2, **Tahoe** 3.4.0), **iPadOS 17** wallpapers, **100+ wallpapers by Blue Pixel Studio** (2.17.0), wallpapers from **Raycast** (2.22.19), and **Glassmorphism wallpapers** (3.4.11). Library has **categories** and **favourites** (2.17.0), plus a **"pick random wallpaper"** button (2.17.3). Default wallpaper changed to **Tahoe Light** in 3.5.0.
- **Gradient** — generated from a chosen colour.
- **Color** — single solid; hex or palette. Colour pickers accept **paste from clipboard** (2.6.0) and **hex codes without the `#`** (3.4.0).
- **Image** — upload your own. Custom-image proportions and duplicate-filename handling were both bug-fixed; if the app loses access to a custom image it falls back to the default wallpaper (2.25.5).

### 9.2 Frame geometry
| Control | Type | Notes |
|---|---|---|
| **Padding** | slider | Space around the recording. **At 0 the background is entirely hidden.** Initial padding is set automatically based on recording type (2.10.4) |
| **Rounded corners** | slider | Smoother rounded-corner rendering (2.25.2); aliasing on light backgrounds fixed 3.1.0; for iPad/iPhone the radius is matched to the real device |
| **Inset** | slider + colour | A border/inset around the recorded screen (2.8.0). **Real-time inset colour changes** (3.4.10) |
| **Shadow** | toggle/slider | Screen shadow. Fixed for large displays (2.25.2), for crop with radius 0 (2.25.10), for external devices without a mockup (2.25.30), and for the webcam with border radius (3.4.2) |
| **Background move on zoom** | removed | The background used to shift during a zoom; that was **removed** in 2.25.30 (background is now static under zoom) |

**No background blur control exists** — background blur is only obtainable via the macOS camera Portrait effect, and only for the camera. Confirmed absent.

**No "auto-balance" feature exists.** Searched specifically; nothing in the docs, changelog or roadmap. Treat as not a Screen Studio feature.

### 9.3 Aspect ratio [P]
Six presets, with these exact labels:
| Label | Ratio |
|---|---|
| **`Auto`** | original aspect ratio of the recording |
| **`Wide`** | 16:9 |
| **`Vertical`** | 9:16 |
| **`Square`** | 1:1 |
| **`Classic`** | 4:3 |
| **`Tall`** | 3:4 |

Plus **4:5** support added in 3.0.0-3301 (so 4:5 exists even though the guide page lists six). **No 3:2 and no free-form custom project aspect ratio** in the guide. There *is* a **custom aspect ratio for the webcam** (2.25.18) and a **saved recording-area aspect ratio** (2.25.10).

Additional toggle: **`Always keep zoomed in`** — affects how the chosen aspect ratio crops the visible area (fixed for window/area sources in 3.5.0).

Vertical mode has an "always on" zoom that can be disabled (2.17.12).

### 9.4 Crop [P]
- Open with the **`Crop`** button. Two current guide pages conflict over `C`: the crop page says `C` opens crop, the trimming page says `C` cuts at the playhead. The changelog settles it — 2.25.18: *"`C` is now used to cut clip at current time instead of opening crop tools."* **Treat the crop page as stale: `C` = cut at playhead**, and crop has no documented shortcut (2.22.9 also fixed "a crop shortcut that was triggered while renaming a file", so one existed historically).
- Drag edges **or type exact numeric values**; **fixed crop aspect ratio** selectable (2.18.1 "Precise Crop Tools").
- **25% / 50% / 75% grid lines** while cropping (2.25.18) and guide lines (2.26.0).
- **Crop suggestions for Google Chrome and Safari** (2.10.6) — e.g. to cut off the browser chrome/URL bar automatically.
- Crop changes the **final frame only**, not the project aspect ratio.
- Closing the crop editor without confirming **restores** the previous crop (2.10.8). Playback stops when the crop tool opens.

---

## 10. Camera / webcam in the editor [P] (`/guide/camera`, `/guide/dynamic-camera-layouts-`)

### 10.1 Floating camera controls
| Control | Notes |
|---|---|
| **Hide camera** | |
| **Position** | Where the camera sits in the frame. The small webcam **keeps a constant distance from the edge regardless of project padding** (2.25.18) |
| **Size** | |
| **Roundness** | Corner radius. Radius for **non-square** webcam shapes is computed correctly (2.25.23) |
| **Mirror camera** | Horizontal flip |
| **Custom aspect ratio for the webcam** | 2.25.18 |
| **Shadow** | Present (a shadow-with-border-radius bug was fixed in 3.4.2) |
| Antialiasing | Improved 2.25.10 |

**Shapes**: there is **no explicit shape picker** (circle / square / rounded-rect). Shape is emergent from **size + custom aspect ratio + roundness** — a 1:1 aspect at full roundness gives a circle, other aspects give rounded rectangles. 2.25.23's fix ("properly calculate rounded corners radius for webcam in non square shape") confirms non-square is a supported, first-class state.

### 10.2 Camera behaviour under zoom [P]
> "when there is a zoom in the recording, we decrease the size of your camera frame to avoid covering the content of your recording."

You can **set the camera size during zooms** independently, or **disable the automatic resize** to keep a constant size. (This is the "webcam overlay with auto zoom-out" advertised on the homepage.)

### 10.3 Dynamic camera layouts [P] — shipped 3.0.0
- A **separate "Layouts" timeline track**, edited the same way as zooms — add layout segments over time.
- Layout states: **fullscreen camera**, **`Default`** (camera + screen together, i.e. the floating overlay, where you can also reposition per moment), and **hidden** ("hide the camera view altogether for parts of the recording").
- Intended use: full-screen camera intro → cut to screen. 3.0.0's announcement: *"You can create video intros with fullscreen camera or hide the camera entirely for portions of the video."*
- Conflicting `1/2/3` shortcuts between the zoom and layout editors were fixed (2.25.25), which implies **`1`/`2`/`3` select tracks or layout modes**; **`4`** activates the **mask timeline** (`/guide/adding-a-mask-and-highlight`).

### 10.4 Not shipped (beta only)
**Background removal, smooth face tracking, camera cropping, LUTs, and split-screen camera layout with smooth transitions are all on the beta/roadmap, not in 3.7.5.** [BETA, https://screen.studio/roadmap]

---

## 11. Audio

### 11.1 Tracks
Independent audio streams, kept separate through to export:
- **Microphone** — separate `.m4a`, `slice.volume`
- **System audio** — separate, `slice.systemAudioVolume` (a genuinely separate per-slice property)
- **Background music** — a third, project-level track
- **Click sound effects** — synthesised at composite time from click events
- **Camera** audio is not separate; the raw webcam file has no audio (see §17.4).

### 11.2 Controls [P]
- **Waveform** on the timeline for mic and system audio (2.10.6). Rewritten waveform engine (2.26.0), lazy-loaded for huge projects (2.25.18), **waveform height reflects the volume setting** (2.20.4 / 2.25.18).
- **`Set volume`** — right-click a timeline part → `Set volume` → pick a level. Applies to the whole recording or a single slice. Checkmark shown in the context menu for the current volume/speed (2.25.18).
- **Mute** microphone audio (2.13.0); **mute external audio from the sidebar** (3.2.2); audio-channel muting fixes in 3.7.1.
- **Automatic microphone improvements** — **volume normalization** and **noise reduction**, on by default, toggleable in the editor's **Audio tab** (2.10.6, made toggleable 2.18.1). Homepage calls these "voice normalization" and "background noise removal".
- **Auto gain control** disable option (2.25.10).
- **Audio scrubber** (`/guide/scrubber`) — a strip above the timeline; drag the playhead and audio plays at a speed proportional to drag speed, forward or backward, for finding an exact edit point. Toggleable; it has its own export interaction bugs historically.
- Speed changes preserve audio pitch reasonably — "fixed robotic audio at 1.2x speed" (3.4.4), "enhanced audio quality when using preview playback speeds above x1" (3.7.1).

### 11.3 Background music [P] (`/guide/background-music`) — shipped 3.4.0/3.4.6/3.4.9
- **Built-in royalty-free library** ("Background audio library" 3.4.6; "Built-in background audio tracks library" 3.4.9) — *"can be used for any purpose without concerns about copyright issues"*.
- **`Add background audio`** to upload your own — **MP3 and MP4** accepted.
- Audio **preview** in the picker (3.4.11). Background audio is **synchronised to the timeline** (3.4.10).
- **No documented ducking, looping or fade controls.** Only track choice and (implicitly) volume.

### 11.4 Silence removal
**Not a feature.** There is no "remove silence" / silence trimming in Screen Studio. The nearest equivalent is **Speed Up Typing Segments** (§13.4). "Audio Improvements Requests" is an open thread on the feedback board.

### 11.5 Beta
**AI voice cleanup** — "On-device voice enhancement and AI noise removal" [BETA]. **Voice audio enhancement** ("studio-like sound") and **AI Voiceover** are Planned/In Progress. [https://screen.studio/roadmap]

---

## 12. Captions / transcription [P] (`/guide/captions`)

### 12.1 Engines — two, both on-device
1. **Whisper** — runs locally. Model size is user-selectable:
   - **`Base`** — "prioritizes speed"
   - **`Small`** — "balances accuracy and speed"
   - **`Medium`** — "provides the highest accuracy" at the cost of processing time
2. **Apple Speech Recognition** (added 3.5.0) — requires **macOS 26.0+**.

Privacy claim [P, homepage + privacy policy]: transcripts are generated **entirely on device**, "no data uploaded to external servers". The privacy policy states *"All screen recordings are processed locally on your device. The recordings are never uploaded to our servers unless you explicitly choose to create a shareable link."*

### 12.2 Generation parameters
- **AI Model** — Base / Small / Medium (Whisper only)
- **Language** — **auto-detected, manually overridable** (manual selection added 2.10.2). Multilingual.
- **Prompt** — a free-text field to "help generate an accurate transcript", for product names and jargon. (This is Whisper's `initial_prompt`.)

### 12.3 Styling and editing
- **Caption size** — adjustable directly in the video preview.
- **Show/hide** the caption overlay.
- **Transcript editor** to fix typos; the editor UI was substantially reworked in 2.7.2.
- **Export the transcript as a separate file.** The format isn't named in the docs — do not assume SRT.
- Captions work even with the built-in microphone (2.22.0).
- Transcript segments that fall inside cuts are **skipped** (2.25.10), and 3.5.0 fixed "transcript processing avoiding lost or extra words when project has cuts" — so the transcript is time-mapped through the edit.
- **No documented font, colour, background-box, position or word-level-highlight controls.** Size and visibility are the only styling knobs in the shipping version. **Improved caption style and animation is on the beta.** [BETA]

---

## 13. Timeline editing [P]

### 13.1 Structure
- Tracks: **video slices** (the yellow clip bar), **zooms**, **camera layouts**, **masks/highlights**, **keyboard shortcuts**, plus the **audio scrubber** strip and waveforms.
- Tracks can be hidden; "always keep at least one track active"; the zoom track stays visible when empty (2.25.18).
- **Timeline zoom**: `⌘ + scroll`, **pinch on the trackpad**, `+`/`-`, animated, staying centred on the playhead or the visible centre (2.22.0, 2.25.10, 2.25.30, 2.26.0). Max timeline zoom was raised (2.25.18).
- Scroll the timeline **during playback** (2.25.18).
- **Preview size** is adjustable (2.25.18); sidebar and timeline can be hidden (2.11.1).

### 13.2 Cutting
| Action | Shortcut / gesture |
|---|---|
| **Split tool (razor)** | **Hold `⌥`** (changed from a toggled `S` in 2.25.18). Scissors icon in the UI |
| **Cut at playhead** | **`C`** (2.25.18 repurposed `C` for this) |
| **Ripple delete** | **`X`** — "deletes clip before the playhead till previous cut" (2.25.18) |
| **Remove a section** | Cut on both sides, right-click the middle → **`Remove`** |
| **Trim** | Drag a clip's left/right edge. Trims render as **yellow bubbles with a scissors icon**; click a bubble to undo that specific trim |
| **Reset all** | "Reset all trims and cuts on timeline" (3.4.11) |
| **Minimum clip length** | **100 ms** (2.25.10) |

Behavioural details worth cloning: while the split tool is active, clicking the timeline does **not** move the playhead; dragging/resizing an item does not drag the playhead; undo/redo of a slice removal **restores the playhead to the same moment of the source video**; split makes items "wiggle independently to show a wave-like effect".

### 13.3 Speed [P] (`/guide/speeding-up-the-video`)
- **Right-click a part → `Set speed` → pick a value from a list** (discrete list, not a free slider, in the main menu; the typing-segment UI uses a slider).
- Slow-down is supported as well as speed-up (2.10.6).
- **`Apply to all`** option for slice speed changes (3.6.0).
- Stored as **`timeScale = 1 / speed`** [R].
- Export of slices above 2x had a bug (fixed 3.2.2); audio quality with speed adjustments fixed in the same release.
- **No speed ramps.** Speed is per-slice and constant within a slice. There is no acceleration curve.

### 13.4 Speed Up Typing Segments — the "magic auto-edit" [P] (`/guide/speed-up-typing-segments`) — shipped 3.0.0
- The app **detects typing from the captured keystroke stream** and **suggests** speeding those fragments up.
- Select a suggested segment → adjust pace with a **speed slider** → choose **"Apply to all typing parts"** or apply only to the selected segment. There is an **"Apply all suggestions"** action for consistency across the recording.
- Default multiplier is not documented.

### 13.5 Other editing
- **Copy/paste** of zoom ranges and slice settings (2.25.18/2.26.0); **⌘-click multi-select** and batch actions.
- **Copy current frame as an image** — right-click the preview → copy, or **`⌘C`**; paste anywhere (`/guide/copy-current-frame-as-an-image`; added 2.25.18, context-menu route 3.5.0). Includes the composited frame (background, effects).
- **Loop playback** mode.
- Arrow keys move by **0.5 s**, or **1 s with `Shift`** (2.25.2).
- **JKL playback controls** and playback-speed settings (announced June 2024 on @screenstudio).
- **Undo/redo** via `project.history` snapshots.
- **Command Menu — `⌘K`** (`/guide/command-menu`, shipped 3.0.0): "quick keyboard access to all Screen Studio features" — switch tools, access editing features, change settings, execute actions. Enabled outside the main editor as of 3.4.10. The command list isn't published.
- **`⌘/`** opens a window listing **all** keyboard shortcuts (`/guide/screen-studio-shortcuts`). **Every action's shortcut is rebindable** in Settings → Shortcuts. The full default map is not published anywhere — it must be read from the in-app `⌘/` sheet.

Known shortcut inventory (assembled from the docs + changelog; not exhaustive):

| Shortcut | Action |
|---|---|
| `⌥⌘↩` | Open the New Recording modal |
| `⌃⌥⌘F` | Drop a recording flag (default, rebindable) |
| `⌘⌥.` | Start/stop the speaker-notes prompter |
| `⌘K` | Command menu |
| `⌘/` | Show all shortcuts |
| `⌘S` / `⌘⇧S` | Save / Save As |
| `⌘C` / `⌘V` | Copy current frame / paste |
| `⌘⇧E` | Export dialog [R] |
| `⌘⌥C` | Quick export to clipboard [R] |
| `⌥` (hold) | Split/razor tool |
| `C` | Cut at playhead |
| `X` | Ripple delete to previous cut |
| `0`–`9` | Set zoom level of the hovered zoom |
| `1` / `2` / `3` | Track/layout selection (inferred from a fixed conflict) |
| `4` | Mask timeline |
| `←` / `→` | ±0.5 s (`⇧` → ±1 s) |
| `Esc` | Close sidebar panel; again → back to background settings |
| `⌘`+scroll / pinch | Zoom the timeline |
| `⌘`+click | Multi-select timeline items |
| Global start/stop | Set during onboarding, rebindable |
| Pause recording | Added 3.2.0, rebindable |

---

## 14. Masks and highlights [P] (`/guide/adding-a-mask-and-highlight`) — shipped 3.1.0

- Press **`4`** to open the mask timeline, then click at the position in the video to place one.
- **Mask** — `type: "sensitive-data"` — **blurs** a rectangle to hide passwords, API keys, PII. `blur` is a **numeric amount** (CLI default **20**). `bounds` is an **array of `{x, y, width, height}`** in *recording coordinate space*, so **one mask can cover multiple rectangles**.
- **Highlight** — dims/de-emphasises everything outside a region to draw the eye. **Opacity is adjustable.**
- Both are **time-ranged** on their own timeline track (`startTime`/`endTime` in source ms).
- **Masks do not track content** — *"masks remain stationary and won't follow screen movement during scrolling."* No object tracking.
- **A mask and a highlight cannot both be applied to the same frame.**
- 3.2.0 improved "handling of content under masks" (i.e. the blur samples correctly under zoom/pan).

---

## 15. Keystroke / shortcut display [P] (`/guide/shortcuts`) — shipped 2.7.0 / 2.22.0

- Screen Studio detects keys pressed **during recording** (from `keystrokes-0.json`) and can render them as an on-screen overlay.
- **`Show shortcuts`** toggle in the Keyboard Shortcuts menu. Disabled if no keys were pressed.
- **Shortcut labels size** — a slider. That is the only styling control. (**Real keycap overlays** are a beta feature. [BETA])
- **`Show single key shortcuts`** — include lone keypresses, not just combos. The app **filters out rapid adjacent presses** so ordinary typing doesn't clutter the video.
- **A dedicated shortcuts timeline track** (2.22.0) with per-instance control: **click a shortcut to disable/remove it**, or **right-click → `disable all "x" shortcuts`** to suppress every instance of that combination.
- **"Hide all shortcuts from timeline"** option (3.4.5).
- Rendering details: `Space` is spelled out as the word "Space"; the Ctrl key is ordered correctly; **F1–F12 and arrow combos are displayed without the `FN` key** (2.22.14). Non-Latin keyboards' unknown keys are ignored (2.16.6).

---

## 16. Annotations, text, shapes

**None.** Screen Studio has **no text tool, no shape tool, no arrows, no freehand drawing, no callouts.** "Annotations" is explicitly listed as **Paused** on the roadmap: *"Enable users to incorporate visual or textual descriptions of clicks within recordings."* "Full text slides" and "Enter/Exit animations" are **Planned**, not shipped. [https://screen.studio/roadmap]

The only overlay primitives are: cursor + click effects, keystroke labels, masks/highlights, captions, camera, device mockups.

---

## 17. Presets, settings, export

### 17.1 Presets [P] (`/guide/creating-preset`, `/applying-preset`, `/sharing-preset`)
- A preset captures the **look-and-feel settings** — background, aspect ratio, camera positioning, and by extension the rest of the 68 config keys.
- Create: finish styling a project → **`Presets`** button → name it → **`Create new preset`**.
- Apply: `Presets` button → click a preset.
- **Share**: `Presets` → preset settings → **`Open in finder`** → send the file. Format is **`.screenstudiopreset`** (introduced 2.12.0), which **bundles images** so custom backgrounds travel with it.
- **Preset storage location is configurable** (3.2.0). A **default preset** is applied to new recordings (2.20.0), with special handling for external-device recordings (3.0.0-3301).
- Separately: **Settings → Editing → "Use last project settings as default for new recordings"** (`/guide/managing-project-settings-for-new-recordings`) — a toggle that makes each new recording inherit the previous project's settings (default ON since 2.25.10).

### 17.2 App settings tabs [P]
Confirmed tabs: **General** (Hide Dock Icon, window position reset), **Recording** ("Create zooms automatically", accessibility/focus options, quick-export-widget toggle, dim toggle), **Editing** ("Use last project settings…", "Create initial zooms automatically"), **Shortcuts** (rebind everything), **Advanced** (proxy/VPN network toggle for licence activation, "Share diagnostics info", reduce export memory usage, cursor-type optimisation toggle), plus performance/preview options.

**Diagnostics** (`/guide/diagnostic-info`): Settings → Advanced → **"Share diagnostics info"** returns Screen Studio version, macOS version, Mac specs, connected camera and microphone — *"This only includes device names and models - no content or personal data is accessed."*

### 17.3 Export [P] (`/guide/exporting-the-video`, `/guide/explanation-of-export-settings`)

**Formats: MP4 and GIF. That is the complete list.**
- **No HEVC, no ProRes, no WebM, no MOV export, no transparent/alpha export.** (MOV and MP4 are *import* formats only.) Searched specifically; nothing in any primary source. Codec is not named but is H.264-class in an MP4 container.
- **GIF**: dedicated pipeline (2.5.10) producing smaller files; a **high-quality colour-palette GIF mode** (2.11.0); **GIF loop count setting** (3.4.0). Guide advises *"We do not recommend creating GIFs that are longer than 1 minute."* MP4 and GIF settings are remembered **separately** (2.16.6).

**Settings exposed:**
| Setting | Options / notes |
|---|---|
| **Format** | MP4 / GIF |
| **Output size (resolution)** | Up to **4K**; HD offered as the lighter option. *"a 4K resolution export will take four times longer than exporting the same project in HD"* |
| **Frame rate** | **60 fps** (smoother, slower export) or **24–30 fps** (standard, faster, smaller) |
| **Quality** | A **compression level**. Explicitly: *"The compression level in Screen Studio does not affect the time it takes to export your content."* — i.e. quality and speed are decoupled; only resolution and fps drive export time |
| **Export presets** | "for web, social media, video editing" (homepage) |

**Destinations:**
- **Export to file** (a save dialog; the file-save modal is docked to the export window since 3.5.2)
- **Copy to clipboard** (2.6.0)
- **Shareable link** (§18)
- **Quick export** — reuses the last-used settings (2.26.0); a toggle list of export settings sits under the record button so a recording can be exported instantly (2.26.0)
- **Export multiple projects at once** (3.0.0) — the save location is requested up front

**Export UX:** a progress window; clicking the info symbol reveals the full output path (3.4.7 "export file details in export window"). Export can run while you keep editing another project (2.25.2). Playback stops automatically when export starts (3.0.0-3301). The project can be deleted right after export (2.10.6).

**Export engine claims:** "new exporting engine and significantly faster export speeds" (2.26.0); "fundamental changes to the exporting engine" (2.25.2); "+~25% export speed" (2.25.18); "faster export for projects with multiple cuts" (3.4.4); an **experimental multi-threaded export mode** that "might increase export speed by 20-40%, but might result in broken video file in some rare cases and hardware setups" (2.22.14); an advanced **"reduce export memory usage"** option (2.25.30). **Up to 3× faster exports** via a reworked render engine is on the beta. [BETA]

**Performance settings** [P] (`/guide/performance-settings`) — three preview modes:
- **Quality** — preview matches the export exactly, motion blur on
- **Performance** — disables motion blur and similar in the preview for a higher preview frame rate
- **Power Saving Mode** — lowers compute and preview frame rate
Plus "options to reduce preview quality" (2.16.1) and playback entering idle mode after 30 s of inactivity (2.25.18).

### 17.4 Extract raw recording files [P] (`/guide/extracting-raw-recording-files`) — since 2.18.1
**Export → "Extract raw recording files…"** → choose a destination folder. Extracts the individual source assets for use in an external NLE. Caveats stated verbatim in the 2.18.1 changelog:
> "you can extract raw webcam file as a separate file. Notes: webcam file does not include audio from the microphone - you'll need to extract microphone audio file as well. Another note - raw screen recording file will not include your mouse cursor as it is not directly recorded by Screen Studio - it is re-added later basing on your mouse position data."

So the extractable components are at least: **raw screen video (cursor-free)**, **raw webcam video (audio-free)**, **microphone audio**, and by extension **system audio**.

---

## 18. Shareable links / cloud [P] (`/guide/shareable-links`, `/guide/shareable-links-comments`) — shipped 3.0.0

- One click produces a hosted link. Managed via **Screen Studio menu → "Manage Shareable Links"** → the web **dashboard**.
- **Hard limit: 30 minutes per shared recording.** *"Please note that currently shareable recordings have a 30 min limit. For longer projects, you'll need to export them as a file."* (Raised from a lower limit to 30 min in 3.3.1; made consistent in 3.4.5.)
- **Private shareable links** (3.4.4) with an improved private link page and **invitation emails** (3.4.5).
- **View counter** (3.5.1); the owner's own views don't increment it (3.7.1).
- **Custom title** — editable from the quick-export widget at share time (3.5.1); a customised title becomes the main overlay text (3.3.0).
- **Comments** (3.4.10): open the link → **"Show Comments"** → **"Write a comment"**; set a display name via a pencil icon; **`⌘↩`** submits and **binds the comment to the current video timestamp**.
- Ultra-wide monitor recordings had a share-creation bug (fixed 3.0.0-3301).
- **Requires an active licence** — access control for existing links when a licence expires was explicitly fixed (3.0.0-3301), and the homepage lists "Shareable links" as a plan feature.
- **Storage**: uploaded to the vendor's cloud, served via **Cloudflare** ("Shared recordings (only when you create shareable links), shareable links thumbnails"). Retention is not stated. [P, privacy policy]

**Quick share widget** [P] (`/guide/quick-share-widget-`) — shipped 3.0.0: appears after a recording with **Share** (link), **Save** (file), **Copy** (clipboard) and **Edit** (double-click opens the editor). Auto-saves the project (3.0.0-3337). Export settings for it are configured via the **"Edit quick export settings"** icon in the recording modal, and the whole widget can be turned off with **"Show quick export widget after recording"** — reached from the **settings gear at the far right of the recording picker**, which may or may not be the same surface as the Settings window's Recording tab.

---

## 19. Integrations, automation, AI

- **Raycast extension** — official, at https://www.raycast.com/screen-studio/screen-studio, ~4,776 installs. Backed by a **custom URL scheme exposed in 2.5.10** "that allows controlling main features of Screen Studio from the outside of it".
- **No AppleScript, no official CLI, no public API.** The screenstudio-agent author states plainly: *"Screen Studio has no automation surface of its own — no AppleScript, no URL scheme, no CLI"* (i.e. the 2.5.10 URL scheme is undocumented/limited), which is why third-party automation goes through the Electron debug port.
- **No Notion, Slack, YouTube or Loom integrations.** Sharing is: file, clipboard, or a Screen Studio-hosted link (which can be pasted anywhere).
- **Drag & drop** project files onto the editor or the menu-bar icon to open (2.26.0).
- **AI features shipping today**: Whisper/Apple on-device transcription; click-driven auto-zoom; typing-segment detection; audio normalisation + noise reduction. **AI Voiceover** and **AI noise removal / voice cleanup** are In Progress / Beta. [BETA]
- **Telemetry** [P, privacy policy]: **PostHog** receives "Feature usage events, recording metadata, device information, IP address" and specifically "Usage analytics (feature usage patterns for blur, highlight, export formats - when permitted)". **Sentry** receives "Device specifications, crash logs, error reports, IP addresses, user email (if user is logged in)".

---

## 20. Version history highlights (for feature-dating a clone roadmap)

| Version | Date | Landmark |
|---|---|---|
| 2.5.10 | May 2023 | Raycast URL scheme; new GIF pipeline |
| 2.7.0 | May 2023 | Show pressed shortcuts in the video |
| 2.8.0 | Jun 2023 | Inset around the recorded screen |
| 2.10.6 | Jun 2023 | Waveform, auto mic normalisation + noise reduction, slow-down, Chrome/Safari crop suggestions |
| 2.12.0 | Jun 2023 | `.screenstudiopreset` format |
| 2.14.0 | Jun 2023 | Hide idle cursor; loop cursor position |
| 2.15.1 / 2.15.3 | Jul 2023 | System audio recording; iPhone & iPad recording |
| 2.17.0 | Aug 2023 | 100+ wallpapers, categories, favourites |
| 2.18.1 | Nov 2023 | Speaker Notes; precise crop; **extract raw recording files** (the cursor-not-baked-in disclosure) |
| 2.22.0 | Mar 2024 | Dedicated keyboard-shortcut timeline; single-key display; project location setting |
| 2.25.2 | Aug 2024 | Ripple click effect; rewritten animations engine; **new motion blur engine**; device rotation |
| 2.25.18 | Sep 2024 | Timeline overhaul: `⌥` razor, `C` cut, `X` ripple delete, multi-select, copy/paste zooms, project-from-mp4, copy frame |
| 2.26.0 | Dec 2024 | Click ripple + shockwave; new export engine; drag & drop; pinch-zoom timeline |
| **3.0.0** | **17 Dec 2024** | **Shareable links, dynamic camera layouts, quick share widget, custom cursors, speed-up-typing, `⌘K` command menu, multi-project export** |
| 3.0.0-3301 | Feb 2025 | 4:5 aspect ratio |
| **3.1.0** | Mar 2025 | **Masks + highlights**; per-slice cursor hiding |
| **3.2.0** | Apr 2025 | **Pause/resume recording**; iPhone device audio; .MOV import; preset storage location |
| 3.3.0 | Jun 2025 | **Mouse click sound effects** |
| 3.4.0–3.4.11 | Jun–Oct 2025 | Background audio + library; Tahoe wallpapers & cursors; private shareable links; 720p/1080p/4K camera; link comments; glassmorphism wallpapers |
| 3.5.0 | Oct 2025 | **Apple Speech Recognition transcripts**; **iPhone Mirroring support**; Halloween cursors; magnetic multifunction button |
| 3.6.0 | Feb 2026 | "Apply to all" for slice speed |
| 3.7.x | May–Aug 2026 | Audio fixes, billing/account polish, reliability |

---

## 21. Pricing and gating [P]

**Authoritative (screen.studio homepage `#pricing`, Sept 2026):**
| Plan | Price | Includes |
|---|---|---|
| **Monthly** | **$20 / month** | "All Screen Studio features included" + "Shareable links" |
| **Yearly** | **$9 / month, billed yearly** (= $108/yr) | Same |

- Billing/subscription management runs through **Lemon Squeezy** ("Manage subscription").
- **Education discount available** — via a "request-educational-discount" link on the site.
- **Legacy one-time licences exist but are no longer sold.** The homepage FAQ has a standing entry *"What happens if I purchased a one-time license in the past?"*, and `/guide/activating-screen-studio` says the licence-key field is *"only applicable for legacy one-time purchase licenses."* Changelog references "expired lifetime license validation" (3.4.2). **Do not quote a one-time price** — every third-party figure ($89 / $149 / $189 / $229) is stale or fabricated and they mutually contradict.
- **Teams**: **not shipped.** "Teams subscriptions architecture" is *In Progress* on the roadmap — *"Owner can invite team members who will need to sign in and will automatically be able to activate their Studio installs."*

**What the free/unactivated app does** — this is the single most important gating fact, and it comes from `/download` [P]:
> Users without an active paid plan can access **all features except video export**.

So: **recording and full editing are free; export is the paywall.** There is **no watermark tier** — third-party claims that "the free version adds a watermark to all videos" and "free users only get MP4 and MOV" (saastreats.net) are **wrong**; MOV isn't even an export format. datastudios.org corroborates the primary source: *"No free trial: Recording works, but exports require payment."*

**Activation** [P] (`/guide/activating-screen-studio`, `/guide/managing-license`):
- Two paths: **email address + emailed activation code** (current subscriptions), or **licence key** (legacy one-time).
- **Per-device activation with a deactivation limit.** Manage at **screen.studio/dashboard** → Device tab → **"Disconnect device"** to free a seat. *"You do not need access to your old device to reset your license key; you can perform this action from any device with internet access."* (A "device deactivation limit" bug was fixed in 3.4.0; "visibility of active devices in dashboard" in 3.0.0-3301.) The exact device count is not published.
- On expiry: a licence-expiration screen with status and expiration time; app-update logic is restricted for expired licences; existing shareable links lose access. Refunded subscriptions are deactivated (3.4.2).

---

## 22. Beta / roadmap — NOT in 3.7.5 [P, https://screen.studio/roadmap]

**On Beta** (this is effectively "Screen Studio 4"):
1. **Up to 3× faster exports** — "Reworked Screen Studio's render engine. Exports are faster and editing is snappier."
2. **New camera features** — "Background removal, smooth face tracking, cropping, LUTs, and a new split-screen layout with smooth transitions."
3. **New zoom effects** — "Glass Loupe effect, sharper zoomed-in text, and lots of tiny improvements."
4. **Better captions & shortcuts** — "Improved style and animation. Real keycap overlays for shortcuts."
5. **AI voice cleanup** — "On-device voice enhancement and AI noise removal."
6. **Unsplash backgrounds** — "Search for background images on Unsplash within Screen Studio."
7. **Improved click effects** — "Reworked the Ripple click effect."

**In Progress**: Teams subscriptions architecture; AI Voiceover.

**Planned**: Voice audio enhancement (studio-like sound); Multi-clip recordings (merge multiple recordings into one project); Full text slides; Enter/Exit animations; Create videos from screenshots.

**Paused**: Annotations.

**Completed**: 26 items listed.

---

## 23. Explicit absences — things a clone spec should NOT assume exist

| Assumed feature | Reality |
|---|---|
| Transparent / alpha export | **No** |
| HEVC / ProRes / WebM / MOV export | **No** — MP4 and GIF only |
| HDR capture or export | **No** |
| >60 fps / ProMotion capture | **No** |
| Text, shapes, arrows, freehand annotation | **No** — Paused on roadmap |
| Silence removal / auto-trim of dead air | **No** — only typing-segment speed-up |
| Audio ducking, looping, fades for background music | **Not documented** |
| Caption font / colour / position / word-level highlight | **No** — size and visibility only |
| SRT export specifically | Unconfirmed — "export the transcript as a separate file", format unnamed |
| Cursor spotlight / follow-me vignette | **No** — only static Highlight masks |
| Camera background removal, face tracking, LUTs, split-screen | **Beta only** |
| Object/scroll tracking for masks | **No** — masks are stationary |
| Multi-clip / multi-take projects | **No** — one recording per project; Planned |
| Speed ramps / acceleration curves | **No** — constant speed per slice |
| Teams / shared workspaces | **Not shipped** — In Progress |
| Notion / Slack / YouTube integrations | **No** |
| Custom (free-form) project aspect ratio | **No** — six presets + 4:5; custom exists only for the webcam |
| 3:2 aspect ratio | **Not listed** |
| Windows / Linux | **No** |
| Zoom-drop shortcut during recording | **No** — open feature request |
| Auto-zoom on non-click events (typing, hover, app switch) | **No** — clicks only |
| Background blur (canvas) | **No** — only macOS Portrait mode on the camera |
| "Auto-balance" | **Not a Screen Studio feature** |
| Camera shape picker (circle/square) | **No** — shape emerges from size + custom aspect ratio + roundness |
| Project library / browser UI | **No** — bundles in a folder; Open Recent, tray menu, drag & drop, Finder |
| Localized app UI | **No** — English only; "multi-language" means caption languages |
| Watermark on a free tier | **No such tier** — export is simply blocked |

---

## 24. Minimum viable clone — the five load-bearing mechanisms

1. **Capture video without the cursor**, and capture, as separate timestamped streams: mouse positions, mouse clicks (`{processTimeMs, button, x, y}`), keystrokes (`{processTimeMs, character, type}`), and the cursor bitmaps themselves. Everything distinctive downstream is a function of this metadata.
2. **Composite at render time, not at capture time** — cursor, click effects, keystroke labels, zoom crop, background, camera, masks and captions are all applied to a raw, unmodified screen video during preview and export. This is why every one of them stays editable afterwards.
3. **Spring-simulated zoom/pan** driven by click positions, with `glideSpeed`, `snapToEdgesRatio` and cursor-following, plus motion blur on three independent channels (cursor / zooming / panning).
4. **A segmented, crash-resilient recorder** — fragmented `.m4s` + `.m3u8` written live, enabling pause/resume, low-disk warnings and project recovery.
5. **A slice model with `timeScale = 1/speed`, dual source/playback time axes, and per-slice `volume` / `systemAudioVolume` / `hideCursor`,** so cuts and speed changes re-map the cursor, zoom, caption and keystroke streams coherently.
