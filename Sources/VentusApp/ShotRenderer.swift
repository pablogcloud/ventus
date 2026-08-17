import AppKit
import SwiftUI
import VentusCore

/// Renders the documentation images offscreen, from the same SwiftUI views the
/// app ships.
///
/// Deliberately not screen capture. Capturing a real desktop drags whatever is
/// behind the window into the shot — browser tabs, terminals, personal files —
/// and ties the result to one machine's wallpaper, scaling and menu bar. This
/// draws the views into a bitmap against a synthetic backdrop with fixed sample
/// telemetry, so the output is reproducible, contains nothing personal, and is
/// still the real interface rather than a mockup.
///
/// Run: `VentusApp --render-shots <output-dir>`
enum ShotRenderer {
    /// Sample telemetry. Plausible mid-load numbers for an M2 Max — high enough
    /// that the curves and heat map have something to show, not so high that
    /// the screenshots look like a machine in trouble.
    private static func sampleStatus() -> TelemetrySnapshot {
        TelemetrySnapshot(
            mode: "armed",
            activeProfile: "balanced",
            activeRule: "On AC power",
            timestamp: Date(timeIntervalSince1970: 1_770_000_000),
            uptime: 6 * 3600 + 42 * 60,
            sensors: [
                .init(groupName: "cpu_perf", maxTemp: 61.4, meanTemp: 58.9, count: 6),
                .init(groupName: "cpu_eff", maxTemp: 52.1, meanTemp: 50.4, count: 4),
                .init(groupName: "gpu", maxTemp: 57.8, meanTemp: 55.2, count: 6),
                .init(groupName: "soc", maxTemp: 59.6, meanTemp: 56.1, count: 26),
                .init(groupName: "nand", maxTemp: 41.2, meanTemp: 41.2, count: 1),
                .init(groupName: "battery", maxTemp: 31.5, meanTemp: 31.1, count: 6),
            ],
            fans: [
                .init(fanIndex: 0, actualRPM: 2480, targetRPM: 2510),
                .init(fanIndex: 1, actualRPM: 2295, targetRPM: 2320),
            ],
            packageWatts: 38.6,
            explanations: [
                .init(fan: 0, targetRPM: 2510, winner: "gpu-weighted"),
                .init(fan: 1, targetRPM: 2320, winner: "p-core"),
            ],
            version: "1.1.2",
            fanControlAvailable: true,
            sensorTemps: [
                .init(group: "cpu_perf", celsius: 61.4), .init(group: "cpu_perf", celsius: 59.8),
                .init(group: "cpu_perf", celsius: 58.2), .init(group: "cpu_perf", celsius: 57.9),
                .init(group: "cpu_perf", celsius: 58.6), .init(group: "cpu_perf", celsius: 57.5),
                .init(group: "cpu_eff", celsius: 52.1), .init(group: "cpu_eff", celsius: 50.9),
                .init(group: "cpu_eff", celsius: 49.4), .init(group: "cpu_eff", celsius: 49.2),
                .init(group: "gpu", celsius: 57.8), .init(group: "gpu", celsius: 56.4),
                .init(group: "gpu", celsius: 55.1), .init(group: "gpu", celsius: 54.6),
                .init(group: "gpu", celsius: 54.0), .init(group: "gpu", celsius: 53.3),
                .init(group: "soc", celsius: 59.6), .init(group: "soc", celsius: 55.2),
                .init(group: "nand", celsius: 41.2),
                .init(group: "battery", celsius: 31.5),
            ]
        )
    }

    /// Config with a rules set worth photographing — the shipped default is two
    /// power rules, which does not show what the editor can express.
    private static func sampleConfig() -> Config {
        var config = Config.defaultConfig()
        config.pinnedProfile = nil
        config.rules.rules = [
            Rule(priority: 40, trigger: .gameDetected, profileName: "performance"),
            Rule(priority: 30, trigger: .timeWindow(startHour: 23, endHour: 8), profileName: "quiet"),
            Rule(priority: 20, trigger: .onBattery, profileName: "quiet"),
            Rule(priority: 10, trigger: .onAC, profileName: "balanced"),
        ]
        return config
    }

    @MainActor
    private static func makeObserver() -> DaemonClientObserver {
        let observer = DaemonClientObserver(offline: true)
        observer.updateConfig(sampleConfig())
        observer.updateStatus(sampleStatus())
        observer.setConnected(true)
        return observer
    }

    // MARK: - Entry point

    @MainActor
    static func render(into directory: String) {
        let dir = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let observer = makeObserver()

        write(hero(observer: observer), size: CGSize(width: 1280, height: 640),
              to: dir.appendingPathComponent("hero.png"))

        write(
            desktop {
                PopoverView(observer: observer, showMainWindow: .constant(false))
            },
            size: CGSize(width: 700, height: 440),
            to: dir.appendingPathComponent("menu-bar.png")
        )

        write(window { DashboardTabView(observer: observer) },
              size: CGSize(width: 900, height: 1330),
              to: dir.appendingPathComponent("dashboard.png"))

        write(window { ProfilesTabView(observer: observer) },
              size: CGSize(width: 900, height: 900),
              to: dir.appendingPathComponent("rules.png"))

        write(window { CurvesTabView(observer: observer) },
              size: CGSize(width: 900, height: 800),
              to: dir.appendingPathComponent("curves.png"))

        FileHandle.standardOutput.write(
            "Rendered documentation images to \(dir.path)\n".data(using: .utf8)!
        )
    }

    // MARK: - Framing

    /// Stand-in for a desktop, so the menu-bar panel is shown in context without
    /// photographing anyone's actual screen.
    private static func desktop<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(
                colors: [
                    Color(red: 0.09, green: 0.13, blue: 0.20),
                    Color(red: 0.16, green: 0.22, blue: 0.27),
                    Color(red: 0.24, green: 0.29, blue: 0.30),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )

            // A menu bar with only our own item in it.
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Spacer()
                    HStack(spacing: 5) {
                        Image(systemName: "fan")
                            .font(.system(size: 13, weight: .medium))
                        Text("61° / 58°")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.trailing, 78)
                }
                .frame(height: 28)
                .background(.black.opacity(0.28))
                Spacer()
            }

            content()
                .padding(.trailing, 64)
                .padding(.top, 34)
        }
    }

    /// Approximates the main window's chrome so a tab reads as part of an app.
    private static func window<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach([Color(red: 1.0, green: 0.37, blue: 0.34),
                         Color(red: 1.0, green: 0.74, blue: 0.18),
                         Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) { dot in
                    Circle().fill(dot).frame(width: 12, height: 12)
                }
                Spacer()
            }
            .padding(.horizontal, 18)
            .frame(height: 42)
            .background(VentusPalette.surface2)

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(VentusPalette.panel)
    }

    private static func hero(observer: DaemonClientObserver) -> some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.06, green: 0.10, blue: 0.14),
                    Color(red: 0.10, green: 0.18, blue: 0.19),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )

            // A wide, very soft accent wash so the panel has something to sit on.
            RadialGradient(
                colors: [VentusPalette.accent.opacity(0.30), .clear],
                center: .init(x: 0.72, y: 0.35), startRadius: 10, endRadius: 520
            )

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        Image(systemName: "fan")
                            .font(.system(size: 34, weight: .medium))
                            .foregroundStyle(VentusPalette.accent)
                        Text("Ventus")
                            .font(VentusFont.display(52, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    Text("Fan control and thermal monitoring\nfor Apple Silicon Macs.")
                        .font(VentusFont.display(23, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .fixedSize()

                    HStack(spacing: 10) {
                        ForEach(["Real die sensors", "Editable curves", "Automatic rules"], id: \.self) { tag in
                            Text(tag)
                                .font(VentusFont.body(13, weight: .medium))
                                .foregroundStyle(.white.opacity(0.88))
                                .padding(.horizontal, 13)
                                .frame(height: 30)
                                .background {
                                    Capsule().fill(.white.opacity(0.12))
                                }
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(.leading, 72)

                Spacer(minLength: 0)

                PopoverView(observer: observer, showMainWindow: .constant(false))
                    .scaleEffect(0.94)
                    .padding(.trailing, 56)
            }
        }
    }

    // MARK: - Offscreen rasterisation

    /// Draws a view into a 2x bitmap. `cacheDisplay` rather than `ImageRenderer`
    /// because the views use AppKit-backed material effects, which only compose
    /// when rendered through a real layer tree.
    @MainActor
    private static func write<Content: View>(_ view: Content, size: CGSize, to url: URL) {
        let host = NSHostingView(
            rootView: view
                .frame(width: size.width, height: size.height)
                .environment(\.ventusStaticSurfaces, true)
        )
        host.frame = CGRect(origin: .zero, size: size)

        // Give the layer tree a window: without one, backdrop-sampling materials
        // have nothing to composite against and render flat.
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        // Pin the appearance so the images do not depend on whatever mode the
        // machine that rendered them happened to be in.
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.setIsVisible(false)
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        rep.size = size                       // 2x pixels, 1x points
        host.cacheDisplay(in: host.bounds, to: rep)

        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.removeItem(at: url)
        try? png.write(to: url, options: [.withoutOverwriting])
    }
}
