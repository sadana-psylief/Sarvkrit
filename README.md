# Sarvkrit

A macOS menu bar app for the small things macOS does differently than you'd expect.

Sixteen features, each an independent toggle you can turn on or off at any time. Nothing runs unless
you switch it on, and turning something off stops it immediately.

```
Keyboard  ·  Clipboard  ·  Windows  ·  Files  ·  Sound  ·  System
```

---

## Install

1. Download the DMG and drag **Sarvkrit** to your Applications folder.
2. **First launch:** right-click the app and choose **Open**, then confirm.

That second step is needed because Sarvkrit isn't notarized yet — notarization requires a paid Apple
Developer account. macOS will otherwise refuse to open it. You only have to do this once.

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

Everything comes from public system APIs, so nothing here asks for a password or a permission.
That is also why **Power** means where your energy is going — battery charge or discharge in watts,
and the adapter's rating when one is plugged in — rather than per-chip wattage, which needs either
undocumented SMC keys or a root process running continuously.

Readings the Mac genuinely can't give are shown as **—**, never as zero. A desktop has no battery;
a rate needs two samples, so it has nothing to report for the first couple of seconds after you
switch it on or wake the Mac up.

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

**Folder access** — File Rules asks the first time it reads a folder you've pointed a rule at. macOS
prompts for this normally.

**Full Disk Access** — Trash Cleanup only. **macOS never prompts for this one**: you have to add
Sarvkrit by hand in System Settings → Privacy & Security → Full Disk Access. Sarvkrit tells you when
it's missing and links you there, rather than silently doing nothing.

Permissions are keyed to the app's location, so a copy in `/Applications` and a copy elsewhere are
two separate grants.

---

## Privacy

Clipboard history is kept on your Mac, in `~/Library/Application Support/Sarvkrit/`. It is never
uploaded anywhere — Sarvkrit has no network code at all.

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
```

`Sarvkrit.xcodeproj` is generated from `project.yml` by XcodeGen and is **not** checked in. Run
`make generate` (or any build target) before opening the project in Xcode.

### Adding a feature

One file under `Sources/Sarvkrit/Features/`, conforming to `Feature`, plus one line in
`FeatureRegistry.makeAll()`. The tray tab, the sidebar, the detail pane, persistence and permission
gating all pick it up with no further edits.

Put the decision logic in a pure `enum` or `struct` with no `CGEvent`, pasteboard or filesystem
dependency — `CutPasteRewriter`, `RuleMatcher`, `ClipboardPrivacyFilter` and `KeepAwakeState` are the
pattern — so it can be tested exhaustively without a live event tap or a real folder.

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

Issues and pull requests are welcome.

- `make test` must pass. There are 334 tests; new behaviour should come with some.
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
