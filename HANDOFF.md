# Ventus — State after visual/UX session (2026-07-23 evening)

Branch `feat/v1-build`, HEAD `8f3dbff`. Build green, 55/55 tests green.

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

1. **Deploy the daemon fix**: the installed root ventusd predates the
   HardwareOwner fix. Run `bash scripts/install.sh` (needs admin). Until then
   disarm may still report the spurious verify error (fans DO revert — verified
   in ventusd.log: F0Md/F1Md=0 written, RPMs back to idle).
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

## Debug hook (for future sessions without accessibility)

`touch ~/.ventus-debug`, then distributed notification
`com.formm.ventus.debug.command` with object `showPopover` / `hidePopover` /
`openMain` (openMain requires the panel to have been shown once — the handler
lives in PopoverView). Post via:
`osascript -l JavaScript -e 'ObjC.import("Foundation"); $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately("com.formm.ventus.debug.command", "showPopover", $(), true);'`
Screenshots work via the Control-your-Mac MCP (`do shell script "screencapture …"`).
Delete `~/.ventus-debug` to disable the hook for daily use.

Fans are SAFE: mode observe, Apple auto, idle RPMs.
