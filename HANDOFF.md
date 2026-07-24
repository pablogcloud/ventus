# Ventus — State after visual/UX + safety-audit session (2026-07-24)

Branch `feat/v1-build`, HEAD `b73b3bb`. Build green, 61/61 tests green.

## Armed-path safety audit (2026-07-24)

Codex adversarial audit + self-review + live SIGKILL fault injection. Live
test PASSED: `kill -9` on the armed root daemon → launchd restarted it in
~0.5s → startup restore wrote fans to Apple auto → mode observe (verified in
ventusd.log: "Performing startup restoreAuto", F0Md/F1Md=0). Findings fixed in
b73b3bb (C1 startup-restore gating, C4 resolved-profile validation, C5/C8
consecutive-command-failure → exit, latched→disarm, H3 frozen-sensor
detection, missing-profile mid-run restore, C8b getConfig race).

**REMAINING KNOWN GAPS:**
- **H7 sleep/wake: IMPLEMENTED + LIVE-VERIFIED (2026-07-24).** Deployed and
  tested: armed on Performance, slept the Mac, woke it. ventusd.log confirmed
  "[Power] System will sleep — restoring fans to Apple auto" → F0Md/F1Md=0,
  then per-tick re-force while armed, then "[Power] System woke — control loop
  resumes"; post-wake fans tracked targets (3312/3126 RPM). Restore-on-sleep
  and clean resume both work. CLOSED.
- **H2** owner-queue wedge: `HardwareOwner.submit` timeout doesn't cancel
  queued work, so an emergency latch might not engage — but the new C5/C8
  consecutive-failure `exit(1)` makes launchd-restart the reliable backstop
  regardless, so this is mitigated in outcome if not in mechanism.
- **H9** no thermal floor in curve validation (an all-min-RPM curve is
  "valid") — the 95°C force-max override is the backstop, so defense-in-depth
  only; low priority.
- **XPC code-sign check** (from the earlier UI audit): the root daemon still
  trusts any admin-UID client. Fold into the same hardening pass.

**The hardened daemon IS DEPLOYED (2026-07-24)** — `install.sh` ran, log shows
"[Power] Registered for sleep/wake notifications". Left in Mode: observe
(Apple auto) after the sleep test. Re-run `sudo bash scripts/install.sh` after
any further daemon code change.

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

