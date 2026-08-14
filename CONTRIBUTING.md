# Contributing to Ventus

Thanks for looking. The most valuable contributions to this project are not
always code — read on.

## The most useful thing you can send

**Sensor reports from hardware that isn't an M2 Max.** Ventus classifies raw
HID sensor names into thermal groups, and those names differ between chips. The
classifier is documented and validated against real hardware in
[`Sources/VentusCore/SensorReader.swift`](Sources/VentusCore/SensorReader.swift),
but it is only empirically verified on the machines people have actually run it
on.

If your temperatures look wrong, or a region of the die map shows no reading,
please run:

```bash
swift build -c release --product sensordump
.build/release/sensordump          # HID sensors + assigned group
.build/release/sensordump --smc    # plus every SMC temperature key
```

and open an issue with the output and your chip (e.g. "M4 Pro, 12P+4E, 20-core
GPU"). That single paste is often enough to fix a whole family of Macs.

## Bug reports

Include:

- Your Mac model and chip, and your macOS version.
- What Ventus showed versus what you expected.
- Whether the daemon was armed or in observe mode.
- Relevant lines from `/Library/Logs/Ventus/ventusd.log`.

For anything involving fan behaviour, the daemon log is essential — it records
every SMC write, every mode change, and every safety action.

## Code contributions

Before opening a pull request, please open an issue describing the problem.
This project has a small, deliberate surface and a strong bias toward *not*
adding options, so it is worth agreeing on the approach first.

### Ground rules

- **Build and test must be green.** `swift build -c release && swift test`.
- **Anything touching the armed control path** — the daemon control loop, the
  watchdogs, `HardwareOwner`, `SMCClient`, `SafetySupervisor` — needs a clear
  argument for why it cannot leave fans in an unsafe state, plus a test where a
  test is possible. Changes there get extra scrutiny; that is not distrust, it
  is the cost of writing to someone else's cooling hardware.
- **No network code.** Ventus does not talk to the internet, and that is a
  feature. Anything that phones home will be declined.
- **Match the surrounding style.** Comments explain *why*, not *what*.

### Sign-off (DCO)

Every commit must carry a `Signed-off-by` line, added automatically with:

```bash
git commit -s -m "your message"
```

This is the [Developer Certificate of Origin](https://developercertificate.org):
you are stating that you wrote the contribution, or have the right to submit it
under this project's licence.

### Licensing of contributions

Ventus is source-available under the
[Functional Source License 1.1 (Apache 2.0 future licence)](LICENSE.md).

By contributing, you agree that your contribution is licensed under those same
terms, and you grant Pablo Garza / FORMM Creative Group the right to relicense
your contribution as part of the project — including under the Apache 2.0
future licence, and under a commercial licence for the signed distribution.
Without this, the project could not be relicensed later or shipped as a paid
signed build, so contributions that do not accept it cannot be merged.

If you are contributing on behalf of an employer, make sure you have their
permission first.

## Building and running

```bash
swift build -c release
bash scripts/make-app.sh          # → build/Ventus.app
sudo bash scripts/install.sh      # install/refresh the root daemon
swift test                        # unit tests
```

The daemon logs to `/Library/Logs/Ventus/ventusd.log`. `ventusctl status` is
the fastest way to see what the daemon actually thinks is happening.

Debug builds include a local automation hook used for UI testing; it is
compiled out of release builds entirely and requires a secret token file to be
present even in debug. See the `#if DEBUG` block in
[`VentusAppMain.swift`](Sources/VentusApp/VentusAppMain.swift).

## Security issues

Please do **not** open a public issue for a security problem, especially
anything involving the root daemon or its XPC interface. Email
`pablogv@formm.mx` instead.
