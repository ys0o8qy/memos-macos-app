# Repository workflow

Native macOS menu-bar client. SwiftUI + AppKit, macOS 14+, Memos v0.30.0. Keep unrelated settings, credentials, and drafts intact.

## Choose the smallest useful validation

- Documentation / shell / workflow edits: `python3 scripts/validate.py quick`.
- Swift changes: `python3 scripts/validate.py test`. This also runs the automation-script tests.
- Local installable delivery: `python3 scripts/validate.py package`. This tests, builds the Universal app once, packages it, and writes stage timings.
- After pushing a PR: `python3 scripts/ci_artifact.py --wait`. It targets origin explicitly, waits for the local HEAD's PR run, downloads once, and verifies the DMG. Do not accept an artifact for a previous commit.
- Do not rebuild a local Universal DMG just to duplicate a successful CI build of unchanged app code; use the verified CI artifact when appropriate. Native debug iteration: `ARCHS="$(uname -m)" CONFIGURATION=debug bash scripts/build-app.sh`.
- Reports and downloaded artifacts belong in ignored `.build/`; deliverable local bundles belong in ignored `dist/`.

## Evidence and boundaries

- Tests that touch AppKit, private pasteboards, Carbon registration or disk images require access to macOS services; sandbox failure is not automatically an app defect.
- Exercise the real editor/responder path for paste/focus fixes. For hotkeys, cover registration, cancellation, conflicts and persistence.
- Unit tests and offscreen renders do not prove visible caret blinking, cross-app shortcuts, IME behavior or real clipboard interaction. If desktop tools are unavailable, record the limitation.
- Use synthetic accounts and isolated pasteboards for tests. Never put API tokens, signing credentials, or actual user drafts in source or logs.
- Keep global Git and macOS settings unchanged. Do not merge a PR unless requested. Read current remote state before choosing a branch.

See `docs/DEVELOPMENT.md` for commands, timing evidence, and manual checks.
