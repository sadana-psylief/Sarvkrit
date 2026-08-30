# Sarvkrit

A macOS menu bar app for small fixes to the things macOS does differently than you'd expect.
Each fix is a toggle you can turn on or off at any time.

## Features

| Feature | What it does |
| --- | --- |
| **Finder Cut & Paste** | `⌘X` marks files in Finder, `⌘V` moves them. Finder can already do this — it's just hidden behind `⌘C` then `⌘⌥V` — so Sarvkrit translates the shortcut you expect into the one Finder listens for. Text editing, including inline rename, is untouched, and `⌘C` + `⌘V` still copies. |
| **Quit on Close** | Clicking a window's red ✕ quits the app once its last window is gone, so `⌘Q` becomes optional. Apps are asked to quit the same way `⌘Q` does, so unsaved work still prompts. Finder is always excluded. |

Both need **Accessibility** access, which Sarvkrit asks for on first launch.

## Building

```bash
brew install xcodegen create-dmg   # one time

make build     # release build into build/
make test      # unit tests
make install   # copy to /Applications
make dmg       # dist/Sarvkrit.dmg
make notarize  # needs a paid Apple Developer account — see below
```

`Sarvkrit.xcodeproj` is generated from `project.yml` by XcodeGen and is not checked in. Run
`make generate` (or any build target) before opening it in Xcode.

## Adding a feature

One file under `Sources/Sarvkrit/Features/`, conforming to `Feature`, plus one line in
`FeatureRegistry.makeAll()`. The dropdown, the sidebar, the detail pane, persistence and
permission gating all pick it up with no further edits.

Put the decision logic in a pure `enum`/`struct` with no `CGEvent`, pasteboard or AX
dependency — `CutPasteRewriter` and `CloseButtonHitTest` are the pattern — so it can be
tested exhaustively without a live event tap.

## Two things to know before changing the build

**Sign with a real certificate, never ad-hoc.** macOS keys the Accessibility grant to bundle
ID *and* code signature. An unstable signature means the permission prompt returns on every
rebuild and the grant silently drops mid-session.

**The App Sandbox must stay off.** Event taps and controlling other apps through the
Accessibility API are incompatible with it, which also means Sarvkrit can't ship on the Mac
App Store. "Off" is expressed by the *absence* of `com.apple.security.app-sandbox` from
`Sarvkrit.entitlements` — there is no build setting to flip.

The grant also follows the app's **location**: a copy in `build/` and a copy in
`/Applications` are two separate grants. Test from `/Applications`.

## Distribution status

The DMG is signed with an Apple Development certificate, which is enough to install and run
locally. It is **not notarized**, so on someone else's Mac Gatekeeper will block it until they
right-click → Open once.

Notarizing needs a paid Apple Developer account and a *Developer ID Application* certificate.
`scripts/notarize.sh` is ready for that day and prints the exact setup steps; it refuses to
sign anything until the certificate exists.
