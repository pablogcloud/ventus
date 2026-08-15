import SwiftUI
import VentusCore

struct DashboardTabView: View {
    @ObservedObject var observer: DaemonClientObserver
    @State private var histories: [String: [Double]] = [:]


    var body: some View {
        ScrollView {
            Group {
                if let status = observer.status {
                    dashboard(status)
                } else {
                    VentusUnavailableState(
                        title: "Unable to Load Dashboard",
                        message: observer.errorMessage ?? "The daemon is not responding."
                    )
                    .frame(maxWidth: .infinity, minHeight: 430)
                }
            }
            .padding(20)
        }
        .background(Color.clear)
        .onAppear {
            if let status = observer.status {
                appendHistory(status)
            }
        }
        .onChange(of: observer.status?.timestamp) { _, _ in
            if let status = observer.status {
                appendHistory(status)
            }
        }
    }

    private func dashboard(_ status: TelemetrySnapshot) -> some View {
        // Plain stacks, not Grid/LazyVGrid: spanning cells resolve column
        // widths unpredictably; equal thirds via maxWidth on each card.
        VStack(spacing: 14) {
            DieHeatMap(status: status)
                .frame(maxWidth: .infinity)
                .ventusCard()

            HStack(alignment: .top, spacing: 14) {
                ThermalGaugeCard(
                    title: "CPU package",
                    temperature: status.temperature(for: "cpu_perf") ?? status.hottestTemperature,
                    peak: status.peakTemperature(for: "cpu_perf")
                )
                .frame(maxWidth: .infinity)
                .ventusCard()

                ThermalGaugeCard(
                    title: "GPU",
                    temperature: status.temperature(for: "gpu"),
                    peak: status.peakTemperature(for: "gpu")
                )
                .frame(maxWidth: .infinity)
                .ventusCard()

                PackagePowerCard(watts: status.packageWatts)
                    .frame(maxWidth: .infinity)
                    .ventusCard()
            }
            .fixedSize(horizontal: false, vertical: true)

            ThermalHistoryCard(status: status, histories: histories)
                .frame(maxWidth: .infinity)
                .ventusCard()

            if status.isFanControlAvailable {
                FanStatusCard(status: status)
                    .frame(maxWidth: .infinity)
                    .ventusCard()
            }
        }
    }

    private func appendHistory(_ status: TelemetrySnapshot) {
        for sensor in status.sensors {
            var values = histories[sensor.groupName, default: []]
            if values.last != sensor.maxTemp || values.isEmpty {
                values.append(sensor.maxTemp)
            }
            histories[sensor.groupName] = Array(values.suffix(300))
        }
    }
}

private struct DieHeatMap: View {
    let status: TelemetrySnapshot
    private let chip = ChipInfo.current

    private func grid(for cores: Int, maxColumns: Int) -> (columns: Int, rows: Int) {
        let columns = min(max(cores, 1), maxColumns)
        let rows = max(1, Int((Double(cores) / Double(columns)).rounded(.up)))
        return (columns, rows)
    }

    /// Adaptive color range across the die sensors: narrow live span so the
    /// hottest region visibly stands out. Widened to ≥6°C around its midpoint
    /// so a thermally uniform idle die doesn't amplify noise into fake
    /// hotspots.
    private var dieRange: ClosedRange<Double> {
        let dieTemps = ["cpu_perf", "cpu_eff", "gpu", "soc"].flatMap { status.temps(for: $0) }
        guard let low = dieTemps.min(), let high = dieTemps.max() else {
            return 40 ... 85
        }
        let mid = (low + high) / 2
        let halfSpan = max((high - low) / 2, 3)
        return (mid - halfSpan) ... (mid + halfSpan)
    }

    private var legendText: String {
        let dieTemps = ["cpu_perf", "cpu_eff", "gpu", "soc"].flatMap { status.temps(for: $0) }
        guard let low = dieTemps.min(), let high = dieTemps.max() else {
            return "40°→85°"
        }
        return String(format: "%.0f°→%.0f°", low, high)
    }

    var body: some View {
        VStack(spacing: 12) {
            VentusSectionHeader(
                title: "Die heat map",
                detail: hottestDetail
            )

            GeometryReader { proxy in
                let width = proxy.size.width
                let height = proxy.size.height
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(VentusPalette.well)
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(VentusPalette.border, lineWidth: 1)
                        }

                    // Align with the region grid's left edge (P-CORES box
                    // starts at 6.5% width), not the container edge.
                    Text("\(chip.name.uppercased()) · \(chip.pCores)P+\(chip.eCores)E · \(chip.gpuCores)-CORE GPU")
                        .font(VentusFont.number(9, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(VentusPalette.ink3)
                        .lineLimit(1)
                        .frame(width: width * 0.87, alignment: .leading)
                        .position(x: width / 2, y: height * 0.05)

                    // Sensor reality on this die (validated via sensordump):
                    // one shared CPU-cluster sensor set (E-cores have no
                    // separate sensor), 3 GPU cluster sensors, an 11-sensor
                    // SoC die grid, board (tdev) sensors, and nothing for the
                    // Neural Engine.
                    let pGrid = grid(for: chip.pCores, maxColumns: 4)
                    let eGrid = grid(for: chip.eCores, maxColumns: 4)
                    let gpuGrid = grid(for: chip.gpuCores, maxColumns: 8)

                    DieRegion(
                        name: "P-CORES",
                        temperature: status.temperature(for: "cpu_perf"),
                        temps: status.temps(for: "cpu_perf"),
                        range: dieRange,
                        tileColumns: pGrid.columns,
                        tileRows: pGrid.rows
                    )
                    .frame(width: width * 0.25, height: height * 0.40)
                    .position(x: width * 0.19, y: height * 0.305)

                    DieRegion(
                        name: "E-CORES",
                        temperature: status.temperature(for: "cpu_perf"),
                        temps: status.temps(for: "cpu_perf"),
                        range: dieRange,
                        tileColumns: eGrid.columns,
                        tileRows: eGrid.rows,
                        annotation: "shared"
                    )
                    .frame(width: width * 0.25, height: height * 0.315)
                    .position(x: width * 0.19, y: height * 0.7)

                    DieRegion(
                        name: "GPU",
                        temperature: status.temperature(for: "gpu"),
                        temps: status.temps(for: "gpu"),
                        range: dieRange,
                        tileColumns: gpuGrid.columns,
                        tileRows: gpuGrid.rows,
                        tileCount: chip.gpuCores
                    )
                    .frame(width: width * 0.357, height: height * 0.77)
                    .position(x: width * 0.521, y: height * 0.5)

                    DieRegion(
                        name: "NEURAL",
                        temperature: nil,
                        temps: [],
                        range: dieRange,
                        tileColumns: 3,
                        tileRows: 1,
                        annotation: "no sensor"
                    )
                    .frame(width: width * 0.207, height: height * 0.36)
                    .position(x: width * 0.823, y: height * 0.285)

                    DieRegion(
                        name: "SOC · MEDIA",
                        temperature: status.temperature(for: "soc"),
                        temps: status.temps(for: "soc"),
                        range: dieRange,
                        tileColumns: 3,
                        tileRows: 1
                    )
                    .frame(width: width * 0.207, height: height * 0.36)
                    .position(x: width * 0.823, y: height * 0.7)
                }
            }
            .frame(width: 620, height: 258)     // fixed: the schematic reads wrong blown up
            .frame(maxWidth: .infinity)         // …and centered in the card

            HStack(spacing: 10) {
                Text("Cooler")
                    .font(VentusFont.body(11))
                    .foregroundStyle(VentusPalette.ink3)
                LinearGradient(
                    colors: VentusPalette.thermalStops.map(\.color),
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 8)
                .clipShape(Capsule())
                Text("Hotter")
                    .font(VentusFont.body(11))
                    .foregroundStyle(VentusPalette.ink3)
                Text(legendText)
                    .font(VentusFont.number(11, weight: .medium))
                    .foregroundStyle(VentusPalette.ink3)
            }
            .frame(maxWidth: 620)
        }
    }

    private var hottestDetail: String {
        guard let hottest = status.hottestTemperature else {
            return "Waiting for sensors"
        }
        return String(format: "Live snapshot · %.0f°C peak", hottest)
    }
}

private struct DieRegion: View {
    let name: String
    let temperature: Double?
    /// Individual sensor readings for this region; tiles tint per sensor.
    let temps: [Double]
    /// Adaptive color range shared across the whole die.
    let range: ClosedRange<Double>
    let tileColumns: Int
    let tileRows: Int
    var annotation: String?
    /// Exact number of real units (cores); grid cells beyond this render
    /// empty so a 38-core GPU shows 38 tiles in an 8×5 grid, not 40.
    var tileCount: Int?
    @State private var hoveredTile: Int?

    /// One value per tile: bucket-averaged when there are more sensors than
    /// tiles (SoC's 11-sensor grid), cycled when there are fewer, nil when
    /// the region has no per-sensor data (falls back to the region color).
    private func tileTemps(count: Int) -> [Double?] {
        guard !temps.isEmpty else {
            return Array(repeating: temperature, count: count)
        }
        if temps.count >= count {
            let bucketSize = Double(temps.count) / Double(count)
            return (0 ..< count).map { i in
                let start = Int(Double(i) * bucketSize)
                let end = max(start + 1, Int(Double(i + 1) * bucketSize))
                let bucket = temps[start ..< min(end, temps.count)]
                return bucket.reduce(0, +) / Double(bucket.count)
            }
        }
        return (0 ..< count).map { temps[$0 % temps.count] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(name)
                    .font(VentusFont.number(9, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(VentusPalette.ink2)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(temperature.map { String(format: "%.0f°", $0) } ?? "—")
                    .font(VentusFont.number(12, weight: .bold))
                    .foregroundStyle(
                        temperature.map(VentusPalette.thermal) ?? VentusPalette.ink3
                    )
            }

            GeometryReader { proxy in
                let spacing: CGFloat = 4
                let tileWidth = (proxy.size.width - CGFloat(tileColumns - 1) * spacing)
                    / CGFloat(tileColumns)
                let tileHeight = (proxy.size.height - CGFloat(tileRows - 1) * spacing)
                    / CGFloat(tileRows)
                let values = tileTemps(count: tileRows * tileColumns)
                ZStack(alignment: .topLeading) {
                    VStack(spacing: spacing) {
                        ForEach(0..<tileRows, id: \.self) { row in
                            HStack(spacing: spacing) {
                                ForEach(0..<tileColumns, id: \.self) { column in
                                    let index = row * tileColumns + column
                                    if let tileCount, index >= tileCount {
                                        Color.clear
                                            .frame(width: max(tileWidth, 4), height: max(tileHeight, 4))
                                    } else {
                                        let fill = values[index].map {
                                            VentusPalette.adaptiveThermal($0, range: range)
                                        }
                                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                                            .fill(fill?.opacity(0.72) ?? VentusPalette.surface3.opacity(0.5))
                                            .overlay {
                                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                                    .stroke(
                                                        hoveredTile == index
                                                            ? VentusPalette.ink.opacity(0.8)
                                                            : fill?.opacity(0.9) ?? VentusPalette.borderStrong.opacity(0.6),
                                                        lineWidth: hoveredTile == index ? 1.5 : 1
                                                    )
                                            }
                                            .frame(width: max(tileWidth, 4), height: max(tileHeight, 4))
                                            .onHover { hovering in
                                                if hovering {
                                                    hoveredTile = index
                                                } else if hoveredTile == index {
                                                    hoveredTile = nil
                                                }
                                            }
                                    }
                                }
                            }
                        }
                    }

                    // Hover readout: the exact sensor value for the tile under
                    // the pointer, floated above it.
                    if let hovered = hoveredTile,
                       hovered < values.count,
                       let value = values[hovered] {
                        let row = hovered / tileColumns
                        let column = hovered % tileColumns
                        let tileCenterX = CGFloat(column) * (tileWidth + spacing) + tileWidth / 2
                        let chipX = min(max(tileCenterX, 24), proxy.size.width - 24)
                        let chipY = CGFloat(row) * (tileHeight + spacing) - 8
                        Text(String(format: "%.1f°", value))
                            .font(VentusFont.number(10, weight: .bold))
                            .foregroundStyle(VentusPalette.ink)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background {
                                Capsule()
                                    .fill(VentusPalette.surface)
                                    .shadow(color: VentusPalette.shadow, radius: 4, y: 2)
                            }
                            .overlay {
                                Capsule().stroke(VentusPalette.borderStrong, lineWidth: 1)
                            }
                            .position(x: chipX, y: max(chipY, -4))
                            .allowsHitTesting(false)
                            .zIndex(1)
                    }
                }
            }
        }
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(VentusPalette.lift)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(
                    VentusPalette.borderStrong.opacity(temperature == nil ? 0.7 : 1),
                    style: temperature == nil
                        ? StrokeStyle(lineWidth: 1, dash: [4, 4])
                        : StrokeStyle(lineWidth: 1)
                )
        }
        // Sensor caveats live in the tooltip, not on the finished UI.
        .help(annotation.map { "\(name) — \($0)" } ?? name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(name), \(temperature.map { String(format: "%.0f degrees Celsius", $0) } ?? "no reading")"
        )
    }
}

private struct ThermalGaugeCard: View {
    let title: String
    /// Group MEAN — the number the curve engine drives fans with, and what the
    /// menu bar shows. Displayed as the headline value.
    let temperature: Double?
    /// Hottest INDIVIDUAL sensor in the group. Status (Normal/Elevated/Hot)
    /// derives from THIS, because the daemon's 95C override also triggers on the
    /// hottest sensor — a cool mean must never show "Normal" while a single
    /// sensor is hot enough to force max fans.
    var peak: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VentusSectionHeader(title: title)
            HStack(spacing: 14) {
                ThermalGauge(temperature: temperature)
                    .frame(width: 84, height: 84)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 7, height: 7)
                        Text(statusLabel)
                            .font(VentusFont.body(11))
                            .foregroundStyle(VentusPalette.ink2)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
    }

    private var statusColor: Color {
        guard let temperature = peak ?? temperature else { return VentusPalette.ink3 }
        if temperature >= 85 { return VentusPalette.hot }
        if temperature >= 72 { return VentusPalette.warn }
        return VentusPalette.good
    }

    private var statusLabel: String {
        guard let temperature = peak ?? temperature else { return "No reading" }
        if temperature >= 85 { return "Hot" }
        if temperature >= 72 { return "Elevated" }
        return "Normal"
    }
}

private struct ThermalGauge: View {
    let temperature: Double?

    var body: some View {
        ZStack {
            Circle()
                .fill(VentusPalette.gaugeCore)
                .padding(8)

            Circle()
                .trim(from: 0.12, to: 0.88)
                .stroke(
                    VentusPalette.surface3,
                    style: StrokeStyle(lineWidth: 9, lineCap: .round)
                )
                .rotationEffect(.degrees(90))

            Circle()
                .trim(from: 0.12, to: 0.12 + progress * 0.76)
                .stroke(
                    VentusPalette.accent,
                    style: StrokeStyle(lineWidth: 9, lineCap: .round)
                )
                .rotationEffect(.degrees(90))

            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(temperature.map { String(format: "%.0f", $0) } ?? "--")
                    .font(VentusFont.number(19, weight: .bold))
                Text("°")
                    .font(VentusFont.body(11, weight: .semibold))
            }
            .foregroundStyle(VentusPalette.thermalInk)
        }
        .animation(.easeOut(duration: 0.4), value: progress)
    }

    private var progress: Double {
        guard let temperature else { return 0 }
        return min(max((temperature - 30) / 70, 0), 1)
    }
}

private struct PackagePowerCard: View {
    let watts: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VentusSectionHeader(title: "Package power")
            Spacer(minLength: 4)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(watts.map { String(format: "%.1f", $0) } ?? "--")
                    .font(VentusFont.number(30, weight: .bold))
                Text("W")
                    .font(VentusFont.body(14, weight: .medium))
                    .foregroundStyle(VentusPalette.ink3)
            }
            Text(watts == nil ? "No power sample" : "Live package draw")
                .font(VentusFont.body(11))
                .foregroundStyle(VentusPalette.ink2)
        }
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
    }
}

private struct ThermalHistoryCard: View {
    let status: TelemetrySnapshot
    let histories: [String: [Double]]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VentusSectionHeader(title: "Thermal history", detail: "Peak · up to 10 min")
            ForEach(status.sensors.sorted { $0.groupName < $1.groupName }, id: \.groupName) { sensor in
                VStack(spacing: 5) {
                    HStack {
                        Text(ventusSensorLabel(sensor.groupName))
                            .font(VentusFont.body(12))
                            .foregroundStyle(VentusPalette.ink2)
                        Spacer()
                        Text(String(format: "%.0f°C", sensor.maxTemp))
                            .font(VentusFont.number(13, weight: .semibold))
                            .foregroundStyle(VentusPalette.ink)
                    }
                    Sparkline(values: histories[sensor.groupName] ?? [sensor.maxTemp])
                        .frame(height: 34)
                }
            }
        }
    }
}

private struct Sparkline: View {
    let values: [Double]

    var body: some View {
        Canvas { context, size in
            let normalizedValues = values.count == 1 ? [values[0], values[0]] : values
            let points = normalizedValues.enumerated().map { index, value in
                CGPoint(
                    x: CGFloat(index) / CGFloat(max(normalizedValues.count - 1, 1)) * size.width,
                    y: size.height - CGFloat(min(max((value - 35) / 60, 0), 1)) * size.height
                )
            }

            guard let first = points.first, let last = points.last else { return }
            var line = Path()
            line.move(to: first)
            for point in points.dropFirst() {
                line.addLine(to: point)
            }

            var area = line
            area.addLine(to: CGPoint(x: last.x, y: size.height))
            area.addLine(to: CGPoint(x: first.x, y: size.height))
            area.closeSubpath()

            context.fill(
                area,
                with: .linearGradient(
                    Gradient(colors: [
                        VentusPalette.accent.opacity(0.26),
                        VentusPalette.accent.opacity(0),
                    ]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )
            context.stroke(
                line,
                with: .color(VentusPalette.accent),
                style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)
            )
            context.fill(
                Circle().path(in: CGRect(x: last.x - 3, y: last.y - 3, width: 6, height: 6)),
                with: .color(VentusPalette.accent)
            )
        }
        .accessibilityHidden(true)
    }
}

private struct FanStatusCard: View {
    let status: TelemetrySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VentusSectionHeader(title: "Fans")
            if status.fans.isEmpty {
                Text(
                    status.isFanControlAvailable
                        ? "Fan telemetry is not available yet."
                        : "Monitor-only · no fans on this Mac"
                )
                .font(VentusFont.body(12))
                .foregroundStyle(VentusPalette.ink3)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 14) {
                    ForEach(status.fans.prefix(2), id: \.fanIndex) { fan in
                        HStack(spacing: 13) {
                            Image(systemName: "fanblades.fill")
                                .font(.system(size: 24, weight: .medium))
                                .foregroundStyle(VentusPalette.accent)
                                .frame(width: 42, height: 42)
                                .background {
                                    Circle()
                                        .fill(VentusPalette.accentTint)
                                }
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    Text(String(format: "%.0f", fan.actualRPM))
                                        .font(VentusFont.number(22, weight: .bold))
                                    Text("rpm")
                                        .font(VentusFont.body(11, weight: .medium))
                                        .foregroundStyle(VentusPalette.ink3)
                                }
                                Text(ventusFanLabel(index: fan.fanIndex))
                                    .font(VentusFont.body(11, weight: .semibold))
                                    .foregroundStyle(VentusPalette.accentDeep)
                            }
                            Spacer()
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity)
                        .background {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(VentusPalette.lift)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(VentusPalette.border, lineWidth: 1)
                        }
                    }
                }
            }
        }
    }
}
