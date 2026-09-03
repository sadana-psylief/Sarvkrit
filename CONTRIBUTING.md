# Contributing to Sarvkrit

Issues and pull requests are welcome. This page covers the process; the
[Building](README.md#building) section of the README covers getting the project to compile.

---

## How a change lands

**`main` is a landing zone, not a working branch.** Nobody pushes to it directly — not outside
contributors, and not the owner either. Every change arrives as a pull request, and the repository
owner merges it. Those two rules are enforced by GitHub rather than by convention, so a direct push
to `main` is rejected by the server no matter who makes it.

1. **Fork the repository**, or branch it if you have write access. Either works.
2. **Branch from `main`.** Name it for what it does: `feature/…`, `fix/…`, `chore/…`.
3. **Open a pull request** against `main`. The template asks what changed, why, and how you checked
   it — filling it in honestly is the fastest route to a merge.
4. **CI runs on every pull request.** The `build` job must pass before the PR can be merged. A second
   `test (advisory)` job also runs; see below for why it doesn't gate anything.
5. **The owner reviews and merges.** You'll be able to see an approved PR but not merge it yourself
   — that's expected, not a permissions bug.

You do not need an approval from anyone else, and you cannot approve your own pull request. Required
approvals are deliberately set to zero: with merges limited to the owner, requiring one would only
have deadlocked the owner's own PRs.

---

## Before you open a pull request

- **`make test` must pass.** There are 846 tests; new behaviour should come with some. Quit any
  running copy of Sarvkrit first — the `test` target does this for you, and the comment above it in
  the `Makefile` explains why it has to.
- **Prefer pure, testable logic** over code that can only be checked by running the app.
  `CutPasteRewriter`, `RuleMatcher`, `ClipboardPrivacyFilter` and `KeepAwakeState` are the pattern:
  decision logic in an `enum` or `struct` with no `CGEvent`, pasteboard or filesystem dependency, so
  it can be tested exhaustively without a live event tap or a real folder.
- **Don't commit `Sarvkrit.xcodeproj`.** It's generated from `project.yml` by XcodeGen. Run
  `make generate` before opening the project in Xcode.
- **Don't change the signing settings or the sandbox setting** in `project.yml` to make something
  build. Both are load-bearing, and the README's
  [Two things to know before changing the build](README.md#two-things-to-know-before-changing-the-build)
  explains what breaks.

## About the advisory `test` job

CI runs the whole suite on pull requests and gets 845 of 846 — including the parts that reach real
hardware, which was the surprise. The one test that cannot pass on a runner is
`CameraMonitorSmokeTests.testTheMachineReportsAtLeastOneCamera`: it asserts that the machine has a
camera, a runner has none, and the test cannot tell that apart from the enumeration being broken —
which is the bug it exists to catch. It is only meaningful on real hardware.

So the `test` job reports but gates nothing, and it is expected to be red. Read it for *which*
tests failed rather than for its overall colour. `make test` passing on your own Mac is still on
you, and that run is the one that counts.

## Licence

Sarvkrit is under **[PolyForm Shield 1.0.0](LICENSE.md)** — source-available, not open-source. It's
free to use for anything, including at work, but it cannot be used to build a competing product.
Contributions are accepted under that same licence. The name and branding aren't covered by it: if
you publish something built on this code, give it your own name.
