# Research notes

Notes from testing Henge on an iPhone Duo (A20 Pro, iOS 27.3) with a macOS 27.2 guest in November 2026. Each one says what was measured, how, what it showed, which PRs acted on it, and what's still open, so someone else can pick up where I stopped. Claims are marked as confirmed, inferred or open.

- [performance-iphone-duo.md](performance-iphone-duo.md): where the time goes (profiles, code cache, TLB, thermal, TLBI waits), the knobs used to measure it, and the open questions.
- [pvg-and-gpu-notes.md](pvg-and-gpu-notes.md): ParavirtualizedGraphics display page and events, surfaces and page lists, task and pipeline handling, the #102 AGX crash, the first-boot panic, and Safari's multi-plane tiles.
- [jit-setup-notes.md](jit-setup-notes.md): JIT on iOS 27, covering TXM detection, RemotePairing port choice, LocalDevVPN routing, LiveContainer, and the high address holds that broke installs.
- [input-notes.md](input-notes.md): what an MX Master 4 exposes over HID++ and what that means for the mouse code.
- [fork-scan-2026-11-13.md](fork-scan-2026-11-13.md): changes in other Henge forks that aren't upstream yet, ranked, with [the scan script](scripts/fork-scan-step1.py).
- [../display-corners.md](../display-corners.md): rounded corners on the Duo's inner screen, with the details in [../duo/](../duo/).
