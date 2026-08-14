# Ventus

A native macOS menu-bar fan controller and thermal monitor for Apple Silicon.

Ventus reads your Mac's real die sensors, shows them as a live heat map of your
actual chip, and — on Macs that have fans — drives those fans from temperature
curves you can edit directly. Fanless Macs (MacBook Air) run in monitor-only
mode: Ventus will never attempt hardware control there.

- **Menu bar** — CPU and GPU temperature at a glance, in two compact lines.
- **Authorize once** — enable fan control a single time, then switch profiles
  and edit curves freely. No confirmation dialog on every action.
- **Real die map** — the schematic is built from *your* chip: core counts and
  GPU size come from the hardware, and every tile is a real sensor reading.
- **Curve editor** — drag points, click to add, double-click to remove.
  Quiet / Balanced / Performance are all editable.
- **Safety first** — see below. It writes to your fans, so this is the part
  worth reading.

Requires **macOS 14+** on **Apple Silicon**.

---

## Why it needs root, and why you can trust it

Fan control means writing to the System Management Controller. That requires a
privileged helper, so Ventus ships a small root daemon (`ventusd`) and a
menu-bar app that talks to it over XPC. Nothing is sent anywhere — Ventus has
**no network code at all**; it never phones home, and there is no telemetry.

Because you are being asked to let something run as root and drive your
cooling, the source is public so you can read exactly what it does. The safety
architecture is deliberate:

- **Observe by default.** The daemon starts in observe mode. It reads sensors
  and computes targets but writes nothing until you explicitly arm it.
- **Thermal override.** Any sensor at 95 °C or a critical thermal state forces
  fans to maximum, overriding your curves.
- **Control-loop watchdog.** If the control loop stops running while fans are
  forced, the daemon hands the fans back to Apple's automatic control, and on a
  sustained stall it restores and exits so launchd can restart it cleanly.
  Staleness is measured on a clock that excludes sleep, so a sleeping Mac is
  never mistaken for a hung one.
- **Verified restore.** Returning to Apple auto is read back and verified, not
  assumed.
- **Sleep and exit are safe.** Fans are released to Apple's control when the
  machine sleeps and when the daemon exits or crashes.
- **Never blind.** If the critical sensors disappear, the daemon restores auto
  and drops to observe rather than driving fans on missing data.
- **Clamped writes.** Every target is clamped to the fan's own hardware
  min/max envelope, read from the hardware.

The armed control path has been through an adversarial safety audit, and
changes to it are reviewed by a second model before release. That is not a
guarantee — see the disclaimer in [LICENSE.md](LICENSE.md) — but the reasoning
is in the commit history if you want to check it.

---

## Install

### Signed build (recommended)

A notarized, signed build with automatic updates and one-click installation is
available at **[ventus.app](https://ventus.app)** *(coming soon)*. Buying it
funds continued development, and it is the easiest path — no Xcode, no
Gatekeeper warnings, no terminal.

### Build it yourself

Everything you need is in this repository.

```bash
git clone https://github.com/pablogcloud/ventus.git
cd ventus
swift build -c release            # build
bash scripts/make-app.sh          # assemble Ventus.app into ./build
cp -R build/Ventus.app ~/Applications/
sudo bash scripts/install.sh      # install + start the root daemon
open ~/Applications/Ventus.app
```

To remove it completely:

```bash
sudo bash scripts/uninstall.sh
```

The self-built app is ad-hoc signed, so macOS will not auto-update it and you
may need to allow it on first launch.

### Command line

`ventusctl` is built alongside the app and is useful for scripting or checking
state:

```bash
.build/release/ventusctl status              # sensors, fans, mode
.build/release/ventusctl profile performance
.build/release/ventusctl arm                 # enable hardware control
.build/release/ventusctl disarm              # back to Apple auto
```

---

## Support development

Ventus is built and maintained by one person. If it is useful to you and you
built it from source rather than buying a licence, a contribution genuinely
helps — and is never required.

- **[Ko-fi](https://ko-fi.com/pablogv)** — one-off or monthly, no account
  needed to donate.
- **GitHub Sponsors** — use the ❤️ Sponsor button at the top of this page.

Reporting a good bug is worth just as much. Sensor layouts differ across chips,
and reports from Macs other than an M2 Max are especially valuable.

---

## Licence

Ventus is **source-available** under the
[Functional Source License 1.1 with an Apache 2.0 future licence](LICENSE.md).

In short: read it, build it, run it, modify it, use it at work — but do not
sell it or ship something that competes with it. Two years after each release,
that version becomes plain Apache 2.0. The name and logo are not licensed;
forks must use a different name.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Bug reports from unusual hardware are
the most useful thing you can send.
