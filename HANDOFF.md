# Ventus — State after visual/UX session (2026-07-23 evening)

Branch `feat/v1-build`, HEAD `9744a66`. Build green, 59/59 tests green.
Four Codex adversarial rounds ran on this work; all fixable findings landed
(transaction serialization + generation tokens, XPC continuations that always
resolve, honest unverified-state UI, all-fans-first restore writes). The one
deferred finding is the XPC code-sign check below.

## What changed this session (all verified visually via screenshots)

- **Popover → borderless NSPanel.** macOS 26's NSPopover wraps content in an
  untintable Liquid Glass frame (NSGlassView + 13pt margins + arrow) — that was
  the "AI slop" halo. The panel now renders the mockup's clean rounded card,
  right-aligned under the status item (falls back to the screen corner when the
  status item is in menu-bar overflow, which it is on this notch Mac).
- **Authorize-once control UX shipped.** The profile segments are the control
  surface: first Quiet/Balanced/Perf pick shows one "Enable fan control?" card;
  after enabling (persisted in `controlAuthorized`), picks set profile + arm
  directly, Auto disarms. No per-arm confirmation anywhere.
- **Dashboard fixed.** `gridCellColumns` was a silent no-op in LazyVGrid —
  every card collapsed to one column (vertical one-letter fan labels, empty
  power card). Now plain stacks; die schematic fixed 620×258 centered; all
  cards verified rendering.
- **Main window no longer auto-opens at launch**, closing it doesn't quit the
  app, and opening it closes the panel. "Open Ventus…" path verified working.
- **Restore-verification flake root-caused + fixed in code (NOT yet deployed).**
  SMC readback of FxMd lags the write on M-series: the daemon wrote mode 0
  (fans really reverted) but the immediate readback said forced →
  "could not verify fans back to auto". `HardwareOwner.restoreAllVerified` now
  polls up to 6×100ms, re-issuing the auto write between polls.

## Pending for Pablo

1. ~~Deploy the daemon fix~~ **RESOLVED**: daemon reinstalled twice this
   session (restore-verify polling + fail-hot blending); disarm now verifies
   cleanly ("Disarmed; fans verified back to auto" in ventusd.log).
2. **/Applications/Ventus.app is a STALE root-owned copy** (couldn't replace
   without admin). Current app: `~/Applications/Ventus.app`. Either
   `sudo rm -rf /Applications/Ventus.app && cp -R build/Ventus.app /Applications/`
   or keep using ~/Applications.
3. **Click-through test**: I could see and drive the app via a debug hook but
   cannot click (no accessibility). Untested by hand: hover states, the Enable
   card via real click, Curves/Profiles tabs visually (data layer proven).
4. **Codex finding for the security audit**: the root daemon's XPC endpoint
   trusts any admin-UID process (no code-signing check on the connecting
   client), so `controlAuthorized` is app-side cosmetics against a malicious
   local process. Fold client code-sign verification into the armed-path audit.
5. Armed-control safety audit still pending as before (arm path unaudited;
   brief arm/disarm cycles during testing behaved correctly, fans left SAFE —
   mode observe, Apple auto).

## Debug hook (DEBUG builds only since the ship-cleanup commit)

The entire debug harness (token-gated distributed-notification commands,
click/drag/scroll synthesis, frames dump, panel pin, ~/ventus-app-debug.log)
is now compiled out of release builds — `strings` on the shipped binary finds
no trace, verified. To use it in a future session: `swift build --product
VentusApp` (debug config), run the debug binary directly, recreate the token
(`python3 -c "import secrets; print(secrets.token_hex(16))" > ~/.ventus-debug`,
chmod 600), and post `"<token>:<command>"` notifications as before. Window-ID
screenshots (`swift /tmp/winid.swift`-style CGWindowList lookup +
`screencapture -l<id>`) work regardless of build type and across Spaces.

## Still unverified by real clicks

Add-point (click empty plot) and remove-point (drag off / double-click) are
implemented but were not confirmed via synthesized events (instant synthetic
taps may not register as SpatialTapGesture; dragging IS verified). One real
click each confirms them. Menu-bar dual readout `58·59°` unverified visually —
the status item lives in menu-bar overflow on this crowded bar.

Fans are SAFE: mode observe, Apple auto, idle RPMs.

