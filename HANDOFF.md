# Ventus — Handoff

## Goal
Replace the deleted **FanControl.app** with **Ventus**: a native macOS menu-bar fan controller **+ monitor** that runs on **all Apple Silicon Macs** (fan-equipped Macs get control; fanless Macs like the MacBook Air are monitor-only). It must carry the **green / Sora identity** of the marketing site, and the control UX should be **authorize-once, then switch profiles / edit curves live** (no per-action confirmation friction). Repo: `/Users/pablo/Projects/ventus`, branch `feat/v1-build`.

**Why the user wants to move surfaces:** the app is a menu-bar (`LSUIElement`) app, and Claude Code's computer-use tools **cannot see or click it** (every `request_access` returned `not_installed`, even from `/Applications`). All app-UI debugging this session was done **blind** (from logs + code), which is why visual glitches ("looks like AI slop") and interaction bugs never fully converged. **Resume in a surface with working computer use (the Claude app) so the app can actually be seen and driven.**

## Current State
All work is **committed** — `git status` is clean. HEAD = `2859338` on branch `feat/v1-build`. Last commits (newest first): `2859338` buttons-not-toggle arm control, `d81eb99` AppKit NSPopover host, `b076a24` profile refresh + app file logging, `e6b3825` polling fix, `827bb99` inline arm confirm, `e128403` SwiftUI restyle, `9754746` fan-capability detection.

**Daemon `ventusd` — WORKS, verified via CLI:** arm/disarm/profile-switch/fan-driving all function. Installed as root LaunchDaemon at `/usr/local/libexec/ventusd`, plist `/Library/LaunchDaemons/com.formm.ventus.daemon.plist`, log `/Library/Logs/Ventus/ventusd.log`. `~/Projects/ventus/.build/release/ventusctl status|arm|disarm|profile <name>|set-auto` all work. 55 unit tests green (`swift test`). The **monitor-first / fanless split PASSED an independent Grok audit** (`Sources/VentusCore/HardwareOwner.swift` refuses control on 0-fan Macs).
**Fans are currently SAFE:** `ventusctl disarm` succeeded — mode = **observe**, fans back to Apple auto (actuals ~1340/1530 RPM).

**App `Ventus.app` — builds & runs, but UI unverified visually.** One SwiftUI file per view under `/Users/pablo/Projects/ventus/Sources/VentusApp/`: `VentusAppMain.swift` (AppKit `NSStatusItem`+`NSPopover` host — replaced the broken `MenuBarExtra(.window)`), `PopoverView.swift`, `DashboardView.swift` (die heat map `Canvas`), `CurvesView.swift`, `ProfilesView.swift`, `VentusComponents.swift`, `VentusTheme.swift` (green palette `#00884B`/`#43C07A`, Sora + Instrument Sans registered from `Resources/Fonts/*.ttf`), `DaemonClient.swift` (XPC + 2s async poll).
**Proven via `~/ventus-app-debug.log`:** the poll delivers live status every 2s, user clicks reach `setProfile`/`arm`, and the daemon honors them. So the **data/action layer works** — the remaining problems are **visual rendering + UX**, which the user reports as "not working at all" + "visual glitches / AI slop." These were **never seen by the assistant** (computer-use blocked).

**Design references:** approved mockup at `/Users/pablo/Projects/ventus/docs/design/ventus-ui-mockup.html` (green/Sora, popover, die heat map, curve editor, both themes). User's marketing-site design (their `Ventus.dc.html`) defines the identity: accent `oklch(0.55 0.14 155)`, Sora (display) + Instrument Sans (body), faint-green neutrals, soft rounded cards. Also published mockup artifact: https://claude.ai/code/artifact/fc46b141-1264-4058-9047-3de5b8356a86

## Next Step
**In the Claude app (working computer use): screenshot the open popover and the open main window, then do a proper visual + UX pass.** Concretely:
1. Launch `/Applications/Ventus.app`, open the popover (click the fan menu-bar icon), open the main window — screenshot both. Cross-reference `~/ventus-app-debug.log` for what clicks actually do.
2. **Implement the authorize-once UX** the user asked for: a single "Enable fan control" authorization, after which **profiles switch live and curves are editable with NO repeated confirmation**. Remove the per-arm confirmation friction (the toggle/confirm churn in `PopoverView.swift` `armControls`).
3. **Fix the visual glitches** ("AI slop") against `docs/design/ventus-ui-mockup.html` — this needs eyes on the real app, hence the surface move.
4. Rebuild loop: `swift build -c release --product VentusApp && bash scripts/make-app.sh && cp -R build/Ventus.app /Applications/Ventus.app && open /Applications/Ventus.app`.

## Open Risks
- **Armed-control safety path is NOT audit-passed** — keep it gated. It has a real, reproduced restore-verification flake: `ventusctl set-auto` (setAppleAuto) returned "could not verify fans back to auto" **while mode stayed armed**, yet `ventusctl disarm` worked cleanly moments later. Bug lives in the `setAppleAutoXPC` / `restoreAllVerified` path (`Sources/ventusd/main.swift`, `Sources/VentusCore/HardwareOwner.swift`). Don't trust armed mode for daily use until fixed + re-audited.
- The button-based arm control (`2859338`) was **never visually verified** — user said "not working at all" but that may predate/postdate the build; confirm with a screenshot.
- App `~/ventus-app-debug.log` + `os.Logger` were added for debugging — consider removing `DebugFile` before shipping.
- `openWindow(id:"mainWindow")` from the AppKit-hosted popover ("Open Ventus…") is unverified — may not work outside the SwiftUI scene environment.
- Disk hit 100% twice this session (builds refill it); ~74 GB free after cleanup. Big consumers are the user's call: Steam ~99 GB, Parallels ~148 GB.

## Destructive-Step Warnings
- **Fan hardware control (root SMC writes):** armed the fans several times during testing; **left SAFE** — `ventusctl disarm` succeeded, mode observe, Apple auto. Re-arming drives fans via the still-unaudited path; watchdog + 95°C override are active but don't leave it armed unattended.
- **Daemon install (root):** `scripts/install.sh` run via admin — wrote `/usr/local/libexec/ventusd` + `/Library/LaunchDaemons/com.formm.ventus.daemon.plist` and bootstrapped it. Re-running is safe (idempotent reinstall).
- **App copied to `/Applications/Ventus.app`** via `osascript ... with administrator privileges` (and `~/Applications/Ventus.app`). Overwriting is safe.
- **Disk cleanup:** deleted `~/.npm`, `~/Library/Caches/*`, `~/Projects/ventus/.build`, `~/Projects/ventus/build`, `~/Library/Developer/Xcode/DerivedData/*` to free space. All regenerable — safe.
- **The original FanControl.app was uninstalled at the very start** (app deleted, login item removed, root helpers `com.crystalidea.macsfancontrol.smcwrite` + `FanControlHelper` removed via admin). Do not attempt to "restore" it.
- No git force-pushes, no branch deletions, no DB migrations. `.gitignore` added (`7ac41f6`) to untrack `.build/` + `build/`.
