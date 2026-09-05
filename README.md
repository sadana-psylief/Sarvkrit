# Sarvkrit

The things macOS does differently than you'd expect — fixed. A menu bar app.

Nineteen features, each an independent toggle you can turn on or off at any time. Nothing runs
unless you switch it on, and turning something off stops it immediately.

```
Keyboard  ·  Clipboard  ·  Windows  ·  Capture  ·  Files  ·  Sound  ·  System
```

Click the menu bar icon and you get a panel per thing worth looking at — what the machine is doing,
the network, the disks, where the power is going, the volume of each app, the brightness of each
screen — rather than a list of switches. The switches are all still there, on their own tab.

---

## Install

1. Download the DMG and drag **Sarvkrit** to your Applications folder.
2. **First launch:** double-click Sarvkrit, click **Done** on the warning, then open **System
   Settings → Privacy & Security**, scroll down to **Security**, and click **Open Anyway** next to
   Sarvkrit. Authenticate, open Sarvkrit again and choose **Open**.

That second step is needed because Sarvkrit isn't notarized yet — notarization requires a paid Apple
Developer account. macOS will otherwise refuse to open it. You only have to do this once.

<!-- TODO(notarize): the whole of step 2 goes away once `make notarize` has run for real. -->

Not *right-click → Open*: macOS 15 Sequoia removed that override, so on 15 and later it shows the
same refusal with no Open button. Open Anyway works on 14 too, so it is the only route given here.

Or skip the whole detour with one command:

```sh
curl -fsSL https://sarvkrit.com/install | sh
```

That works because macOS quarantines what a *browser* downloaded and curl sets no such attribute,
so Gatekeeper's first-launch check never runs. Which is why the script does the equivalent check
itself — signature intact, signed by this team — and installs nothing if either fails. Read it
before you run it: <https://sarvkrit.com/install> is the script, served as plain text. If you
already have the DMG, `xattr -dr com.apple.quarantine /Applications/Sarvkrit.app` is the same idea
by hand.

Sarvkrit lives in the menu bar and has no Dock icon until you open its window.

---

## Features

### ⌨️ Keyboard

#### Finder Cut & Paste

Press **⌘X** on files in Finder to mark them, then **⌘V** in the destination to move them there.

Finder can already do this — it's just hidden behind ⌘C followed by ⌘⌥V — so Sarvkrit translates the
shortcut you expect into the one Finder listens for. Because Finder does the actual work, you keep
undo, progress bars and conflict prompts.

Only Finder is affected. ⌘X while editing text, including renaming a file inline, still cuts text as
usual, and ⌘C followed by ⌘V still copies rather than moves.

A brief confirmation appears at the top of the screen: **"Cut — press ⌘V where you want it"**, then
**"Moved"**. The first only appears once Finder has actually put something on the clipboard, so ⌘X
with nothing selected stays silent.

### 📋 Clipboard

#### Clipboard History

Keeps what you copy so you can paste it again later. Press **⌘⇧C** to open the list at your cursor,
type to search, and press Return to paste.

- **Text, images and files** — each can be turned off independently.
- **Files are stored by path, not copied**, so a 4 GB video costs the same as a note. If you move or
  delete the original, that entry is shown struck through rather than pasting nothing.
- **Pin** entries you use often so they never age out.
- **Paste as plain text** with ⌥Return, to strip formatting from a web page.
- **Search** in exact or fuzzy mode — fuzzy finds `invoice-2026.pdf` when you type `invpdf`. Matching
  letters are shown in bold.
- **Sort** by time of last copy, time of first copy, or number of copies.
- **Size limit** — skip anything over a size you choose. With no limit set, copying a *folder* is
  skipped and only individual files are kept.

**Your passwords are not recorded.** See [Privacy](#privacy) below — this is the most important
thing about this feature.

### 🪟 Windows

#### Window Management

Move and resize windows from the keyboard, or by dragging them to a screen edge.

**⌃⌥←** and **⌃⌥→** snap the focused window to half the screen, **⌃⌥↩** maximizes it, and
**⌃⌥⌫** puts it back where it was. Forty-one actions in all — halves, corners, thirds, fourths,
sixths, nudges and moving between displays — and every one of them is rebindable. Click a shortcut
in the settings pane to change it; **⌫** clears one and **⎋** cancels.

The recorder refuses shortcuts that would do you harm. A bare letter is rejected, because Sarvkrit
swallows what it matches and the letter would never reach the app you were typing in; so are ⌘Q,
⌘W, ⌘Tab, ⌘Space and Escape. Anything that clashes with Sarvkrit's own shortcuts is allowed but
tells you what it will cost first.

**Ultrawide mode** retunes the layouts for very wide displays, where a half is wider than anyone
wants a window. With it on, the arrow keys give thirds instead — press the same one again to cycle
through a third, a half and two-thirds — and Maximize stops short of filling the screen, at a width
you choose.

It applies **per display**. A laptop alongside an ultrawide keeps its halves, so the setting is
safe to leave on with either one plugged in. Sarvkrit will point out that an ultrawide is connected,
but never switches the mode on by itself: a shortcut that quietly means something different
depending on which monitor a window is on would be worse than one that is occasionally suboptimal.

**Snap areas** are off until you ask for them, since they change what an ordinary window drag does.
Turn them on and dragging a window to an edge or corner shows a preview of where it will land.
Only the edges and corners react — dragging across the middle of the screen does nothing. Each of
the nine zones can be reassigned, and a window dragged away from its edge can be given back the
size it had before.

#### Quit on Close

Closing an app's last window with the red ✕ quits the app, instead of leaving it running with
nothing on screen.

Sarvkrit asks the app to quit the same way ⌘Q does, so unsaved work still prompts you to save. Apps
that keep other windows open are left alone, and **Finder is always excluded** — quitting it would
take the desktop with it.

### 📁 Files

#### File Rules

Watches folders you choose and applies rules to files as they arrive. Rules are checked in order and
**only the first one that matches a file runs**, so the order of your rules decides what happens.

**Match on:** name, extension, full name, kind, size, date added, date modified, source URL, tags —
with `all` or `any` of your conditions.

**Then:** move, copy, rename, sort into a subfolder, add a tag, set a colour label, move to Trash, or
notify.

**Rename patterns** support these tokens:

| Token | Meaning |
| --- | --- |
| `{name}` | Filename without extension |
| `{ext}` | File extension |
| `{fullname}` | Filename including extension |
| `{counter}` | Number that increments to avoid collisions |
| `{date:FORMAT}` | File's modification date, e.g. `{date:yyyy-MM-dd}` |
| `{now:FORMAT}` | Today's date, e.g. `{now:yyyy}` |
| `{kind}` | Image, Video, Document, … |
| `{match:N}` | Capture group N from a regex condition |

**Preview before you arm anything.** Every rule has a dry run that lists exactly which files match
and what would happen to each — including for rules you haven't enabled yet.

Nothing is ever deleted permanently: files Sarvkrit removes go to the Trash. A file still being
downloaded is left alone until it stops changing, and a rule that files something into a folder it
also watches runs once rather than looping.

#### Trash Cleanup

Permanently removes items that have been in the Trash longer than you choose, and can keep the Trash
under a size limit by clearing the oldest items first.

This is the one thing Sarvkrit does that can't be undone — items in the Trash have nowhere further to
go. It ships **disabled**, defaults to 30 days with no size limit, runs once an hour, and writes
every removal to the log.

Needs **Full Disk Access**. See [Permissions](#permissions).

#### App Sweep

When you delete an application, Sarvkrit looks for the support files, caches and preferences it
leaves behind, and offers to remove them.

It never sweeps on its own: you always see the list, with sizes, and choose what goes. Everything
selected is moved to the Trash, not deleted.

Two things keep it safe. It matches on **bundle identifier only** — matching on app *name* is how
tools like this delete the wrong thing. And it waits before offering, then checks whether macOS can
still find the app anywhere: app updates are a delete followed by a replace, and sweeping mid-update
would destroy the preferences of an app you still have.

### 📸 Capture

#### Screenshots

Capture an area, a window, or the whole screen. **The screen freezes while you choose**, so an open
menu or a tooltip stays put instead of vanishing the moment you click — and because the selection is
drawn over a picture that has already been taken, the magnifier and the live pixel readout cost
nothing.

A window capture is taken on its own rather than cut out of the screen, so its shadow can be kept or
dropped and its corners can be genuinely transparent instead of showing whatever was behind it.

**Scrolling capture** takes a frame each time you pause while scrolling and stitches them into one
tall image. It watches your scrolling rather than doing the scrolling for you, which is why it needs
no extra permission. Vertical is what it's built and tested for; a full-width sticky header or footer
is written once, but a floating button in the middle of a row will repeat.

**Text recognition** reads the text — or a QR code — out of any part of the screen and puts it on the
clipboard. It runs on your Mac, and a scanned QR payload is copied rather than opened, because
following a link scanned off the screen should be your decision.

After a capture a thumbnail appears in the corner: copy it, annotate it, pin it, or drag it straight
into another app. The editor has arrows, shapes, text, counters, a highlighter that snaps to lines of
text, and backgrounds.

**On blurring things out.** An ordinary blur is reversible — blurred small text is routinely
recovered — and so is pixelation when the alphabet is small, which is exactly the password case. So
Sarvkrit names them for what they are and offers a **secure** mode that keeps nothing but the average
colour of the region, with texture generated from a seed rather than from your pixels. A weak blur
over a password is worse than none, because you'd share it believing it was hidden.

#### Pin to Screen

Floats a screenshot above everything else while you work. Resize it, fade it, and move it wherever
you need it. Lock Mode makes it ignore clicks so you can work through it — and because a locked shot
can't be clicked to unlock, **⌃⇧P** unlocks every pinned shot and one draws a coloured border while
locked. Needs no permissions at all.

**⌃⇧⎋ always clears the screen.** Everything in this category floats above your other windows, and
one thing deliberately ignores clicks, so there is one shortcut that means *get all of it off my
screen* — overlays, pinned shots, the capture bar, whatever state any of it is in. It's registered
with the system rather than by watching the keyboard, so it keeps working even if you revoke
Sarvkrit's other permissions.

### 🔊 Sound

#### Volume Mixer

A separate volume for each app. Slide one down without touching anything else, or **push a quiet one
past 100%** when a video was mastered too low — up to 200%, shown with a ⚡ so it's clear Sarvkrit is
adding gain that wasn't in the original.

Boosting is where a mixer usually starts distorting, because multiplying a signal that already peaks
near full scale produces samples the hardware can't play. Sarvkrit runs the boosted signal through a
soft limiter, which leaves anything below the threshold **bit-for-bit untouched** — a quiet podcast
at 200% never reaches it — and bends the loudest peaks over smoothly instead of flattening them.

There's no audio driver and no installer. It works by tapping the app's audio and playing it back at
the level you chose, which is the only way to do this that doesn't put a plug-in in
`/Library/Audio/Plug-Ins/HAL/`.

**This needs the System Audio Recording permission**, and macOS refuses it *silently* — every call
still reports success, and the audio simply goes quiet. Sarvkrit notices that and says so, rather
than appearing to work.

An app you've never touched plays at exactly the volume it would without this feature.

#### Audio Devices

Pick which device your Mac plays through and listens with, without opening System Settings. **⌃⌥O**
steps to the next output, which beats a list when you're just moving between speakers and headphones.
Name a preferred device and Sarvkrit switches to it whenever it's connected.

#### Mute Microphone

Silences the microphone from the menu bar, whichever app is using it.

#### Privacy Guard

Holds the microphone muted and tells you the moment the camera comes on. The lock puts the mute back
if anything turns it off — an app, System Settings, you by accident — and can mute at login and
whenever the Mac sleeps or locks.

**Sarvkrit can't switch the camera off.** macOS provides no way for any app to do that, and anything
claiming otherwise is either using a private trick or just showing you a warning. This shows you the
warning, the instant the camera starts. Checking is a question *about* the device — Sarvkrit never
opens the camera itself.

#### Music Blocker

Stops the Music app barging in when you connect headphones. You can still open it yourself.

---

### ⚙️ System

#### Keep Awake

Prevents your Mac from going to sleep by itself. Turn it off and normal sleep behaviour returns
immediately.

- **Also keep the display on** — optional.
- **Stay awake for** — until you turn it off, or 30 minutes / 1 / 2 / 4 hours.
- **Keep awake with the lid closed** — for long-running work in Terminal.

The menu bar icon shows what's happening: a **coffee cup** while Keep Awake is on, a **bolt** when
system sleep is disabled entirely, with the remaining time beside it when a timer is running.

**About the lid-closed option.** It changes a system-wide setting rather than something Sarvkrit
holds for itself, which is why macOS asks for your password. Sarvkrit starts a small background task
at the same time that restores normal sleep **the moment Sarvkrit quits — including if it crashes**,
so your Mac can't be left permanently awake in a bag. The one case that can't cover is restarting
your Mac; if that happens, Sarvkrit tells you on next launch and offers to put it back.

#### System Monitor

Shows what your Mac is actually doing — **CPU**, **GPU**, **Power**, **Battery**, **Memory**,
**Disk** and **Network** — in the Sarvkrit menu, with a full pane in the window.

- **Each reading switches on and off on its own.** Nothing is sampled for one you've turned off.
- **Every reading lives under the Sarvkrit icon.** Click it and open **System** to see all seven at
  once. System Monitor adds no menu bar icon of its own.
- **Show live data in the menu bar** — optional, on by default. Chosen readings appear as text
  beside the Sarvkrit icon; switch it off and the icon is left alone while the readings stay in the
  menu. CPU alone to begin with, since that text shares the app's own icon.
- **Refresh every 1, 2 or 5 seconds** — two by default. Changing it clears the graphs, since a
  graph can only show one cadence at a time.
- **Two minutes of history** is kept to draw the graphs. It lives in memory only, is never written
  to disk, and is discarded the moment you switch the monitor off.

It shows a little more than the seven headline numbers:

- **Temperatures** for the CPU, the GPU and the battery.
- **Memory pressure**, not just memory used. A Mac at 90% used with normal pressure is doing exactly
  what it should — macOS fills spare RAM with cache and hands it back on demand — and the percentage
  on its own alarms people about precisely that case.
- **Battery health** and cycle count. This is the number System Settings calls Maximum Capacity, and
  it is worked out the same way, so the two agree.
- **Uptime**, and **how much the network has moved** since you switched the monitor on.
- **Every mounted volume**, with how full it is, its **SMART** status, and an **Eject** button for
  the ones that can be. Machinery volumes — Preboot, VM, the read-only system snapshot, mounted disk
  images — are left out, on the same test Finder uses to decide what goes in its sidebar.

**One reading uses a private API, and it is the temperatures.** macOS publishes no way to read them,
so this goes through the same undocumented sensor interface every Mac temperature tool uses. It is
worth being exact about what that costs: it is *unprivileged* — no root, no password, no permission
prompt, and nothing leaves your Mac — and the symbols are looked up at runtime, so a macOS release
that removes them makes the temperatures read **—** rather than stopping Sarvkrit from launching.
Everything else here is public API. Temperatures are Apple Silicon only; Intel Macs report through
the SMC instead and show **—**.

**Power** still means where your energy is going — battery charge or discharge in watts, and the
adapter's rating when one is plugged in — rather than per-chip wattage. That one genuinely does need
a root process running continuously, which is a different bargain from an unprivileged read.

Readings the Mac genuinely can't give are shown as **—**, never as zero. A desktop has no battery; a
rate needs two samples, so it has nothing to report for the first couple of seconds after you switch
it on or wake the Mac up; and a Mac with no GPU temperature sensor shows a dash for it rather than
borrowing the CPU's.

#### Displays

Sets the brightness of every connected screen from the menu, including externals, which the
brightness keys don't reach.

How far it can go depends on the screen. The built-in panel and some Apple externals have a backlight
macOS can set directly, and the slider moves the real thing. Everything else falls back to **dimming
the picture** Sarvkrit sends, which works on any display but can only make it darker than the setting
on the monitor's own controls — the panel says so, on the displays where that's what's happening,
rather than offering a slider whose top half does nothing.

Dimming that way changes a setting that outlives the app, so it is undone when you switch the feature
off, when Sarvkrit quits, **and at the next launch if Sarvkrit was killed while a screen was dim**.
A screen left dark with nothing on it to explain why is the one failure worth engineering against.

Setting brightness needs no permission of any kind. Reading and setting the backlight uses a private
but unprivileged framework, resolved at runtime, for the same reasons as the temperatures above; the
dimming fallback is public API.

---

## Keyboard shortcuts

| Shortcut | Where | What it does |
| --- | --- | --- |
| **⌃⌥←** / **⌃⌥→** | Anywhere | Snap the window to half the screen (a third on an ultrawide) |
| **⌃⌥↑** / **⌃⌥↓** | Anywhere | Snap to the top or bottom half |
| **⌃⌥U** / **⌃⌥I** / **⌃⌥J** / **⌃⌥K** | Anywhere | Snap to a corner |
| **⌃⌥D** / **⌃⌥F** / **⌃⌥G** | Anywhere | First, centre or last third |
| **⌃⌥↩** | Anywhere | Maximize |
| **⌃⌥C** | Anywhere | Centre without resizing |
| **⌃⌥⌫** | Anywhere | Restore to where the window was before |
| **⌃⌥−** / **⌃⌥=** | Anywhere | Make smaller or larger |
| **⌃⌥⌘←** / **⌃⌥⌘→** | Anywhere | Move to the previous or next display |
| **⌘X** then **⌘V** | Finder | Move files |
| **⌘⇧C** | Anywhere | Open clipboard history at the cursor |
| **⌃⌥1**–**⌃⌥5** | Anywhere | Paste one of the first five entries directly |
| **⌘1**–**⌘5** | Clipboard picker | Paste that entry |
| **↑ / ↓** | Clipboard picker | Move the selection |
| **Return** | Clipboard picker | Paste the selected entry |
| **⌥Return** | Clipboard picker | Paste without formatting |
| **⌥P** | Clipboard picker | Pin or unpin |
| **⌥⌫** | Clipboard picker | Delete that entry |
| **Esc** | Clipboard picker | Close |
| **⌃⇧A** | Anywhere | Capture an area |
| **⌃⇧W** | Anywhere | Capture a window |
| **⌃⇧F** | Anywhere | Capture the screen |
| **⌃⇧5** | Anywhere | All-In-One: pick a mode, a size and a timer |
| **⌃⇧S** | Anywhere | Scrolling capture |
| **⌃⇧T** | Anywhere | Copy text from the screen |
| **⌃⇧Z** | Anywhere | Bring back the last capture overlay you dismissed |
| **⌃⇧H** | Anywhere | Hide the capture overlays until the next shot |
| **⌃⇧P** | Anywhere | Pin the clipboard image, or unlock every pinned shot |
| **⌃⇧Y** | Anywhere | Browse everything you've captured |
| **⌃⇧⎋** | Anywhere | Clear everything Sarvkrit has put on screen |
| **Esc** | Capture overlay | Cancel |
| **⇧** drag | Capture overlay | Keep the shape you're already drawing |
| **⌥** drag | Capture overlay | Grow from the centre |
| **Arrows** | Capture overlay | Nudge the selection (⇧ for ten pixels) |
| **A L R E T H D N B P C S ;** | Editor | Pick a tool |
| **1**–**6** | Editor | Pick a colour |
| **⌘Z** / **⇧⌘Z** | Editor | Undo and redo |
| **⌘S** / **⇧⌘S** | Editor | Save, or save so it stays editable |

**Why not ⌘⇧3, ⌘⇧4 and ⌘⇧5.** Those belong to macOS's own screenshot service, which claims them
below the level Sarvkrit can register at — bind one and it either fails outright or silently never
fires. You can still record one if you want it, and Sarvkrit will mark it as unregistered rather
than pretend; free it in System Settings › Keyboard › Keyboard Shortcuts › Screenshots first.

Window shortcuts fire only while Window Management is switched on, and the keys go back to the app
you're using the moment you turn it off. They are all rebindable — the table above is just what
ships, chosen to match Rectangle so that switching over keeps your muscle memory.

**Why ⌘1–⌘5 only works inside the picker.** ⌘1–⌘9 switches tabs in Safari, Chrome, Slack and
essentially every tabbed app. Claiming it system-wide would take it away everywhere, so the short
shortcut works where nothing else is listening — inside the picker — and **⌃⌥1–5** covers pasting
without opening anything. ⌃1–4 is macOS Spaces and ⌥1–5 types `¡™£¢∞`, which is why the global one
needs three modifiers.

---

## Permissions

Sarvkrit asks for as little as it can, and each feature says what it needs.

**Accessibility** — needed by Finder Cut & Paste, Quit on Close, and the clipboard's global
shortcuts. macOS calls it this because it's the same permission apps use to control the interface on
your behalf. Sarvkrit watches only the specific keys and clicks belonging to features you've switched
on, doesn't record what you type, and sends nothing off your Mac.

**Screen Recording** — Screenshots only. macOS classes reading what's on your display as recording
the screen, so taking a screenshot needs it. **Unlike Accessibility, macOS does not hand this grant
to an app that's already running**: after you allow it, Sarvkrit has to be restarted before it can
capture anything, and it offers to do that rather than leaving you with black rectangles. Pin to
Screen needs nothing at all — floating an image you already have asks nothing of the system.

**System Audio Recording** — Volume Mixer only. Setting one app's volume means taking its audio and
playing it back, and macOS classes taking it as recording. Nothing is written anywhere: the audio
goes straight back out at the level you chose. **macOS refuses this one silently** — every call still
reports success and the app simply falls quiet — so Sarvkrit watches for that and tells you, rather
than looking like it works.

**Folder access** — File Rules asks the first time it reads a folder you've pointed a rule at. macOS
prompts for this normally.

**Full Disk Access** — Trash Cleanup only. **macOS never prompts for this one**: you have to add
Sarvkrit by hand in System Settings → Privacy & Security → Full Disk Access. Sarvkrit tells you when
it's missing and links you there, rather than silently doing nothing.

**Nothing at all** — Keep Awake, Displays, System Monitor and the audio device switcher ask for no
permission of any kind. Two of them read through private but *unprivileged* interfaces, which is
described where each one is: see [System Monitor](#system-monitor) for temperatures and
[Displays](#displays) for brightness.

Permissions are keyed to the app's location, so a copy in `/Applications` and a copy elsewhere are
two separate grants.

---

## Privacy

Clipboard history is kept on your Mac, in `~/Library/Application Support/Sarvkrit/`. It is never
uploaded anywhere — **the app contains no network code at all.**

**One thing does reach the internet, and it is deliberately not part of the app.** Sarvkrit ships
a launchd job that asks GitHub, roughly once a day, what the newest release is, and writes the
answer to a file the app then reads. That is the whole of it: an unauthenticated `GET` with no
token, no query string and no identifier of any kind. Nothing about you or your Mac is sent, and
nothing is sent back.

It is a separate job rather than code inside the app for a reason you can act on: you can read it
(`Sarvkrit.app/Contents/Resources/check-for-update.sh` — eighty lines of shell), you can see
it listed under **System Settings → General → Login Items → Allow in the Background**, and you can
switch it off there or in **Settings → General** without giving up anything else the app does.
With it off, Sarvkrit makes no network requests whatsoever.

Sarvkrit never installs an update itself. When a newer version exists it says so and shows you the
command to run.

**Copies marked confidential are never recorded.** macOS has an established convention
([nspasteboard.org](https://nspasteboard.org/)) for marking a copy as "don't keep this", and password
managers use it every time you copy a password. Sarvkrit checks for it *before reading the content*,
so a refused copy never enters the app at all:

- `org.nspasteboard.ConcealedType` — confidential
- `org.nspasteboard.TransientType` — momentary
- `org.nspasteboard.AutoGeneratedType` — not a deliberate copy
- plus the legacy markers used by 1Password, TextExpander, TypeIt4Me and Typinator

**The convention has a real gap.** Passwords copied from password-manager *browser extensions* are
frequently not marked at all, and an app like Notes has no way to mark anything. For those, add the
app to **Never record from** in the Clipboard settings. **Clear History** removes everything already
stored, pinned items included.

---

## Building

```bash
brew install xcodegen create-dmg   # one time

make build     # release build into build/
make test      # unit tests
make install   # copy to /Applications
make dmg       # dist/Sarvkrit.dmg
make notarize  # needs a paid Apple Developer account — see below
make release VERSION=1.0.1   # bump, build, notarize, then tag and publish to GitHub
```

`make release` treats notarization as a gate: it bumps `MARKETING_VERSION`, builds, runs
`make notarize`, and only if that verifies its own work does it commit, tag and create the GitHub
release. There is no path through it that publishes a DMG users would be blocked by. Because
`sarvkrit.com/download` and GitHub's own "latest" link both resolve through
`releases/latest/download/Sarvkrit.dmg`, a new release is picked up with no change on the site.

`Sarvkrit.xcodeproj` is generated from `project.yml` by XcodeGen and is **not** checked in. Run
`make generate` (or any build target) before opening the project in Xcode.

### Adding a feature

One file under `Sources/Sarvkrit/Features/`, conforming to `Feature`, plus one line in
`FeatureRegistry.makeAll()`. The tray tab, the sidebar, the detail pane, persistence and permission
gating all pick it up with no further edits.

Put the decision logic in a pure `enum` or `struct` with no `CGEvent`, pasteboard or filesystem
dependency — `CutPasteRewriter`, `RuleMatcher`, `ClipboardPrivacyFilter` and `KeepAwakeState` are the
pattern — so it can be tested exhaustively without a live event tap or a real folder.

### Notarizing, once there is a paid account

`scripts/notarize.sh` is written and waiting; it exits with instructions until a **Developer ID
Application** certificate is in the keychain, which only a paid Apple Developer Program membership
can produce. Today's DMG is signed with the *Apple Development* cert and is not notarized, which is
why the install section above has a step 2 at all.

0. **Decide Individual vs Organization before enrolling.** The licence holder is Psylief
   Technologies Pvt. Ltd., so Organization is the tidier fit — but it needs a D-U-N-S number and
   legal-entity verification, which runs to weeks rather than days, and it is the company name that
   then appears on the certificate and in every Gatekeeper dialog. Individual is approved in a day
   or two and shows the personal name. This choice is not easy to change later.
1. Enrol in the Apple Developer Program ($99/yr) as `tusharsadana@icloud.com`.
2. Xcode → Settings → Accounts → Manage Certificates → **+ Developer ID Application**.
3. Read the **new Team ID** off that certificate (Keychain Access shows it in the Organizational
   Unit field) and put it in `project.yml`'s `DEVELOPMENT_TEAM` **and** in `EXPECTED_TEAM` in the
   site repo's `public/install.sh`, which pins it. It is not `77A36893HP` — see below. A build
   signed against the old ID will not notarize, and the installer will reject it.
4. Create an app-specific password at appleid.apple.com, and store it for `notarytool`, once:

   ```bash
   xcrun notarytool store-credentials SarvkritNotary \
     --apple-id tusharsadana@icloud.com --team-id <new team ID> --password <app-specific-password>
   ```
5. `make release VERSION=1.0.1`. It will not tag or publish anything unless notarization has
   verified itself — `spctl` reporting `source=Notarized Developer ID` and `stapler validate`
   passing on both the app and the DMG. Cut a new version rather than replacing the v1.0 asset:
   the v1.0 notes publish that DMG's sha256 under *Verifying the download*, so clobbering the
   asset in place would make the published hash a lie.
6. Grep both repos for the marker `TODO` + `(notarize)` and delete what it finds: the install
   step 2 above, step 2 of `INSTALL_STEPS`, the `OpenAnywayMock` illustration and its `.ctx-*`
   rules in `index.css`. This runbook is a hit too and stays — it is the instruction, not the
   thing being removed. Then fix step 2 of the v1.0 release notes, which still describes the
   Gatekeeper detour.

**The Team ID will almost certainly change.** `77A36893HP` is a *free personal team* — Xcode's own
record says `isFreeProvisioningTeam = true`, `teamType = Personal Team`, named "Tushar Sadana
(Personal Team)". A paid membership is a different team with its own ID; the personal team does not
become it. So after enrolling, read the new Team ID off the certificate and update
`DEVELOPMENT_TEAM` in `project.yml` and the `--team-id` in `scripts/notarize.sh`'s message. A build
signed against the old ID will not notarize.

**Expect one Accessibility re-prompt.** Re-signing from *Apple Development* to *Developer ID*
changes the code signature, and macOS keys the Accessibility grant to bundle ID *and* signature — so
the first notarized build asks every existing user, and this machine, to grant it once more. That is
a one-time cost at the switch, not something that recurs.

### Two things to know before changing the build

**Sign with a real certificate, never ad-hoc.** macOS keys the Accessibility grant to bundle ID *and*
code signature. An unstable signature means the permission prompt returns on every rebuild and the
grant silently drops mid-session.

**The App Sandbox must stay off.** Event taps and controlling other apps through the Accessibility
API are incompatible with it, which also means Sarvkrit can't ship on the Mac App Store. "Off" is
expressed by the *absence* of `com.apple.security.app-sandbox` from `Sarvkrit.entitlements` — there
is no build setting to flip.

---

## Contributing

Issues and pull requests are welcome. **[CONTRIBUTING.md](CONTRIBUTING.md)** has the full process.

- `main` takes no direct pushes. Every change goes through a pull request, which the owner merges.
- `make test` must pass. There are 846 tests; new behaviour should come with some.
- Prefer pure, testable logic over code that can only be checked by running the app.
- Contributions are accepted under the same licence as the project.

---

## Licence

**[PolyForm Shield 1.0.0](LICENSE.md)** — Copyright © Psylief Technologies Pvt. Ltd.

Sarvkrit is **free to use**, for anything, including at work. The source is public, and you're
welcome to read it, change it, and contribute back.

**What you may not do is use this code to build a competing product.** That includes something free,
something written in another language, and something for another platform — the licence is explicit
that marketing a product as a practical substitute definitely competes.

This is a **source-available** licence, not an open-source one. That distinction is deliberate: the
OSI definition requires permitting competing derivative works, which is the one thing this licence
withholds. Practically, that means GitHub won't show an open-source licence badge, Sarvkrit can't go
into Homebrew core, and some people won't contribute to non-OSI projects. That's the cost of the
term, not an oversight.

### The name

**"Sarvkrit" is not licensed.** The licence covers the code — it grants no rights to the name, the
icon, or the branding, and explicitly implies no licences beyond the ones it states. If you publish
something built on this code, give it your own name.
