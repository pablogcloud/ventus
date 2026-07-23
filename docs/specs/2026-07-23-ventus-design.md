# Ventus — design spec (v1, 2026-07-23)

Personal-now/product-later fan control app for Apple Silicon MacBook Pro (M2 Max, Mac14,6),
replacing FanControl.app after its control loop pegged a core at 99% CPU for days.
Architecture: daemon-centric — the UI can crash, quit, or never launch and fan control keeps working.

## Components

1. **`ventusd`** — root launchd daemon (plist install script for v1; SMAppService deferred to
   productization). The ONLY process touching hardware. Contains sensor service, curve engine,
   safety supervisor, XPC server (mach service `com.formm.ventus.daemon`).
2. **`Ventus.app`** — SwiftUI menu bar extra + settings window. Thin XPC client, zero control logic.
3. **`ventusctl`** — CLI over the same XPC surface (`status`, `profile <name>`, `arm`, `disarm`,
   `set-auto`, `config get|set`, `watch`).

Build system: Swift Package Manager workspace (`VentusCore` library + three executables).
The .app bundle is assembled by `scripts/make-app.sh` (Info.plist with `LSUIElement=true`,
ad-hoc codesign — fine for personal use). No Xcode project files.

## Hardware access (Apple Silicon)

- **Fans (SMC via AppleSMC IOKit user client):** keys `F0Ac`/`F1Ac` (actual RPM, flt), `F0Tg`/`F1Tg`
  (target), `F0Mn`/`F0Mx` (min/max), `F0Md`/`F1Md` (mode: 0=auto, 1=forced). Write path: set `FxMd=1`
  then `FxTg=<rpm>`; restore auto = `FxMd=0`. Implement an `SMCClient` modeled on the open-source
  Stats / smcFanControl approach (IOServiceOpen on `AppleSMC`, selector 2 kernel calls,
  `SMCParamStruct`). All writes go through one audited choke point.
- **Temperatures:** AppleSMC on AS exposes limited temp keys; primary path is
  `IOHIDEventSystemClient` (`kIOHIDEventTypeTemperature`, matching PrimaryUsagePage 0xff00/0xff05)
  as used by Stats/macmon. Sensor names matched by pattern into groups: `cpuPerf`, `cpuEff`, `gpu`,
  `soc`, `battery`, `nand`. Aggregation per group: max and mean.
- **Package power:** IOReport energy-model channels (CPU/GPU/ANE watts) with SMC `PSTR`/`PPBR`
  fallback; if neither works, power terms in curves are simply inactive (degrade gracefully).
- **Thermal pressure:** `ProcessInfo.thermalState` + `NSProcessInfoThermalStateDidChange` notifications.

Known risk (accepted): these are private-but-stable interfaces; failure mode must always be
"fans revert to Apple auto," never "fans stuck."

## Curve engine (pure logic, unit-tested, no IOKit imports)

- Profile = per-fan piecewise-linear curves mapping a **sensor-group aggregate** → RPM, plus
  optional watts→RPM curve. Final target per fan = max(temp curve, power curve, pressure floor,
  safety override). **Differential fans:** each fan configures its own input mix (weighted blend of
  group aggregates), e.g. fan0 GPU-weighted, fan1 P-core-weighted.
- **Smoothing:** EMA on each aggregate, time-constant per profile (default 5 s).
- **Hysteresis:** ramp-up uses live smoothed value; ramp-down requires value < (threshold − gap,
  default 5 °C) sustained for a dwell time (default 20 s). No RPM oscillation around thresholds.
- **Power prediction:** watts curve acts as a leading indicator (sustained high package power spins
  fans up before temps peak).
- **Thermal-pressure floors:** `.serious` → ≥80 % of fan max; `.critical` → 100 %.
- **Rate limiting:** target RPM changes slew-limited (default ≤300 RPM/s) so audible changes are gradual.
- Engine tick is adaptive: 1 s when hot/loaded, 5 s when cool-idle. Event-driven where possible;
  NEVER a busy loop (the FanControl failure).

## Profiles & auto-switch rules

Profiles: `quiet`, `balanced`, `performance`, `auto-apple` (no override) + user-defined.
Rule engine (evaluated in daemon, priority-ordered): on-battery / on-AC, clamshell/external-display,
named apps running (bundle IDs, e.g. LM Studio, Xcode builds), **game detection** (frontmost app is
fullscreen + sustained GPU power/residency above threshold), time windows. First matching rule wins;
manual selection from UI/CLI pins a profile until released.

## Safety supervisor (sits ABOVE the engine; nothing can bypass it)

1. **Hard thermal override:** any sensor ≥95 °C or thermalState == .critical → both fans 100 %.
2. **Restore-to-auto guarantees:** on SIGTERM/SIGINT/uncaught-exit → `FxMd=0`. launchd `KeepAlive`
   restarts the daemon; on start it re-asserts a known state.
3. **Control-loop watchdog:** heartbeat timestamp; independent watchdog thread — if the loop stalls
   >10 s → restore auto, `exit(1)`.
4. **Self-CPU watchdog:** daemon monitors its own CPU (getrusage delta); sustained >5 % over 60 s →
   log, restore auto, `exit(1)`. The FanControl bug becomes structurally self-limiting.
5. **Observe/armed modes:** daemon starts in `observe` (reads sensors, computes targets, writes
   NOTHING). SMC writes only after explicit `ventusctl arm` / UI toggle; armed state persists in config.
6. **Config validation:** schema-versioned JSON; invalid config → keep last-good, else observe mode.

## XPC

Mach service `com.formm.ventus.daemon`. Protocol (NSXPCConnection, Codable payloads as JSON Data):
`getStatus()` (telemetry snapshot: sensors, fan RPM/targets, mode, active profile/rule, engine state),
`streamTelemetry(interval)` via client-supplied endpoint/callback, `getConfig()`, `setConfig(Data)`
(validated, atomic write, single-writer = daemon), `setProfile(String)`, `arm()`, `disarm()`,
`setAppleAuto()`. Connection acceptance v1: peer must be root or member of admin group (audit token);
codesign requirement check is a product-phase hardening item.

## Config

`/Library/Application Support/Ventus/config.json`, versioned (`schemaVersion`), owned root:wheel 0644.
Daemon is the single writer. Contains profiles, curves, rules, engine params, armed flag.

## UI (Ventus.app)

- **Menu bar:** hottest-sensor temp + fan RPM glyph; popover: live per-group temps, both fans,
  power W, active profile + why (which rule), quick profile switch, arm/disarm.
- **Window:** Dashboard (live gauges + 10-min sparkline history, client-side ring buffer);
  Curve editor (per-fan graph, draggable points, hysteresis band visualization, live "where we are
  now" marker); Profiles & rules editor; Settings (login item, tick rates, safety readout).
- If daemon unreachable: clear degraded state + "install/start daemon" call to action.

## Install / uninstall

`scripts/install.sh` (sudo): binary → `/usr/local/libexec/ventusd`, plist →
`/Library/LaunchDaemons/com.formm.ventus.daemon.plist` (KeepAlive), bootstrap. `uninstall.sh`
reverses everything and restores fan auto mode. `make-app.sh` assembles + ad-hoc signs Ventus.app.

## Acceptance gates

- `swift build -c release` green; `swift test` green (curve engine, hysteresis, safety state
  machine, config validation, rule engine — all pure-logic tested).
- `ventusd --dry-run` (foreground, observe) prints real sensor groups + computed targets on this M2 Max.
- `ventusctl status` returns live telemetry via XPC.
- Ventus.app launches, menu bar shows live data, curve edits round-trip through the daemon.
- Armed smoke test (manual, with Pablo): fans follow a test curve; SIGKILL of daemon → fans return
  to Apple auto after launchd restart; uninstall restores auto.

## Work units

- **U1** `VentusCore`: SMC client, HID sensor reader, IOReport power, config schema, curve engine,
  safety state machine, rule engine + full unit tests. (Codex, xhigh)
- **U2** `ventusd`: control loop, XPC server, watchdogs, signal handling, install scripts. (Codex, high)
- **U3** `ventusctl`. (Codex, medium) — after U2's protocol exists.
- **U4** `Ventus.app` SwiftUI. (Codex, high) — after U2's protocol exists; parallel with U3.
- **U5** Integration pass, docs, hardware smoke test. (Orchestrator + Pablo)
- Grok honesty gate over the whole delivery before "done."
