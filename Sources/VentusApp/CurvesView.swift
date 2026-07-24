import SwiftUI
import VentusCore

struct CurvesTabView: View {
    @ObservedObject var observer: DaemonClientObserver
    @State private var draft: EditableConfig?
    @State private var baseline: EditableConfig?
    @State private var profileName = ""
    @State private var selectedFan = 0
    @State private var isApplying = false
    @State private var feedback: EditorFeedback?

    var body: some View {
        ScrollView {
            Group {
                if let draft, let profile = draft.profiles[profileName] {
                    editor(draft: draft, profile: profile)
                } else if observer.config == nil {
                    loadingState
                } else {
                    VentusUnavailableState(
                        title: "No Editable Curves",
                        message: "The active profile delegates fan control to Apple."
                    )
                    .frame(maxWidth: .infinity, minHeight: 430)
                }
            }
            .padding(20)
        }
        .background(Color.clear)
        .onAppear(perform: loadConfig)
        .onChange(of: observer.config) { _, _ in
            if draft == nil || draft == baseline {
                loadConfig()
            }
        }
    }

    private func editor(draft: EditableConfig, profile: EditableProfile) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Temperature → RPM curves")
                        .font(VentusFont.display(20, weight: .bold))
                        .foregroundStyle(VentusPalette.ink)
                    Text("Editing the \(ventusProfileTitle(profileName)) profile")
                        .font(VentusFont.body(12))
                        .foregroundStyle(VentusPalette.ink2)
                }
                Spacer()
                livePill(profile)
            }

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    fanSelector(profile)
                    Spacer()
                    Text("Drag points · click the plot to add · drag off or double-click to remove")
                        .font(VentusFont.body(11))
                        .foregroundStyle(VentusPalette.ink3)
                }

                if let curve = profile.curves[selectedFan] {
                    CurvePlot(
                        points: Binding(
                            get: { currentCurve?.points ?? curve.points },
                            set: { setPoints($0) }
                        ),
                        currentTemperature: weightedTemperature(curve),
                        currentRPM: observer.status?.fans.first {
                            $0.fanIndex == selectedFan
                        }?.actualRPM,
                        hysteresisGap: profile.hysteresisGapC
                    )
                    .frame(height: 300)

                    Text(
                        "Shaded band = ramp-down hysteresis window · marker follows the live workload"
                    )
                    .font(VentusFont.body(11))
                    .foregroundStyle(VentusPalette.ink3)

                    inputMix(curve)

                    HStack(spacing: 9) {
                        Button {
                            applyDraft()
                        } label: {
                            HStack(spacing: 7) {
                                if isApplying {
                                    ProgressView()
                                        .controlSize(.small)
                                        .tint(VentusPalette.onAccent)
                                }
                                Text(isApplying ? "Applying" : "Apply")
                            }
                        }
                        .buttonStyle(VentusButtonStyle(kind: .primary))
                        .disabled(!hasChanges || isApplying)
                        .opacity(hasChanges && !isApplying ? 1 : 0.5)

                        Button("Revert") {
                            revertDraft()
                        }
                        .buttonStyle(VentusButtonStyle(kind: .ghost))
                        .disabled(!hasChanges || isApplying)
                        .opacity(hasChanges && !isApplying ? 1 : 0.5)

                        if let feedback {
                            Text(feedback.message)
                                .font(VentusFont.body(11, weight: .medium))
                                .foregroundStyle(feedback.isSuccess ? VentusPalette.good : VentusPalette.hot)
                                .transition(.opacity)
                        }
                        Spacer()
                    }
                }
            }
            .ventusCard()
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
                .tint(VentusPalette.accent)
            Text("Loading curves")
                .font(VentusFont.display(15, weight: .semibold))
                .foregroundStyle(VentusPalette.ink)
            Text("Waiting for the daemon configuration.")
                .font(VentusFont.body(12))
                .foregroundStyle(VentusPalette.ink2)
        }
        .frame(maxWidth: .infinity, minHeight: 430)
    }

    private func fanSelector(_ profile: EditableProfile) -> some View {
        HStack(spacing: 4) {
            ForEach(profile.curves.keys.sorted(), id: \.self) { fanIndex in
                VentusSegmentButton(
                    title: ventusFanLabel(index: fanIndex),
                    isSelected: selectedFan == fanIndex,
                    action: {
                        selectedFan = fanIndex
                        feedback = nil
                    }
                )
            }
        }
        .padding(3)
        .frame(width: max(360, CGFloat(profile.curves.count) * 180))
        // Inside the glass card — inner elements stay subtle materials, never
        // nested glassEffect shapes.
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.black.opacity(0.14))
        }
    }

    private func livePill(_ profile: EditableProfile) -> some View {
        Group {
            if
                let curve = profile.curves[selectedFan],
                let temperature = weightedTemperature(curve)
            {
                let rpm = interpolate(points: curve.points, temperature: temperature)
                let maximum = max(curve.points.last?.rpm ?? 1, 1)
                Text(
                    String(
                        format: "%.0f°C → %.0f%% fan",
                        temperature,
                        min(max(rpm / maximum * 100, 0), 100)
                    )
                )
            } else {
                Text("Waiting for live workload")
            }
        }
        .font(VentusFont.number(11, weight: .semibold))
        .foregroundStyle(VentusPalette.accentDeep)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background {
            Capsule()
                .fill(VentusPalette.accentTint)
        }
    }

    private func inputMix(_ curve: EditableFanCurve) -> some View {
        VStack(spacing: 10) {
            VentusSectionHeader(
                title: "Input mix",
                detail: ventusFanLabel(index: selectedFan)
            )
            ForEach(sensorGroups(for: curve), id: \.self) { group in
                HStack(spacing: 12) {
                    Text(ventusSensorLabel(group))
                        .font(VentusFont.body(12))
                        .foregroundStyle(VentusPalette.ink2)
                        .frame(width: 74, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { currentCurve?.inputMix[group] ?? 0 },
                            set: { setMix(group: group, value: $0) }
                        ),
                        in: 0...1
                    )
                    .tint(VentusPalette.accent)
                    Text(String(format: "%.2f", currentCurve?.inputMix[group] ?? 0))
                        .font(VentusFont.number(11, weight: .medium))
                        .foregroundStyle(VentusPalette.ink)
                        .frame(width: 38, alignment: .trailing)
                }
            }
        }
    }

    private var currentCurve: EditableFanCurve? {
        draft?.profiles[profileName]?.curves[selectedFan]
    }

    private var hasChanges: Bool {
        draft != nil && draft != baseline
    }

    private func loadConfig() {
        guard let config = observer.config else { return }
        do {
            let encoded = try JSONEncoder().encode(config)
            let editable = try JSONDecoder().decode(EditableConfig.self, from: encoded)
            let preferred = preferredProfile(in: editable)
            draft = editable
            baseline = editable
            profileName = preferred
            selectedFan = editable.profiles[preferred]?.curves.keys.sorted().first ?? 0
            feedback = nil
        } catch {
            feedback = EditorFeedback(message: "Could not stage this configuration.", isSuccess: false)
        }
    }

    private func preferredProfile(in config: EditableConfig) -> String {
        let candidates: [String?] = [
            observer.status?.activeProfile,
            config.pinnedProfile,
            Optional("balanced"),
            config.profiles.keys.sorted().first,
        ]
        for candidate in candidates.compactMap({ $0 }) {
            if let profile = config.profiles[candidate], !profile.curves.isEmpty {
                return candidate
            }
        }
        return ""
    }

    private func setPoints(_ points: [EditableCurvePoint]) {
        guard var config = draft, var profile = config.profiles[profileName],
              var curve = profile.curves[selectedFan]
        else { return }
        curve.points = points
        profile.curves[selectedFan] = curve
        config.profiles[profileName] = profile
        draft = config
        feedback = nil
    }

    private func setMix(group: String, value: Double) {
        guard var config = draft, var profile = config.profiles[profileName],
              var curve = profile.curves[selectedFan]
        else { return }

        let clamped = min(max(value, 0), 1)
        var groups = Set(curve.inputMix.keys)
        groups.insert(group)
        let others = groups.filter { $0 != group }
        let otherTotal = others.reduce(0) { $0 + (curve.inputMix[$1] ?? 0) }
        curve.inputMix[group] = clamped

        if others.isEmpty {
            curve.inputMix[group] = 1
        } else if otherTotal > 0 {
            let scale = (1 - clamped) / otherTotal
            for other in others {
                curve.inputMix[other] = (curve.inputMix[other] ?? 0) * scale
            }
        } else {
            let share = (1 - clamped) / Double(others.count)
            for other in others {
                curve.inputMix[other] = share
            }
        }

        profile.curves[selectedFan] = curve
        config.profiles[profileName] = profile
        draft = config
        feedback = nil
    }

    private func revertDraft() {
        draft = baseline
        feedback = nil
    }

    private func applyDraft() {
        guard let draft else { return }
        isApplying = true
        feedback = nil

        do {
            let encoded = try JSONEncoder().encode(draft)
            let config = try JSONDecoder().decode(Config.self, from: encoded)
            try config.validate()

            Task {
                let success = await observer.setConfig(config)
                if success {
                    observer.updateConfig(config)
                    baseline = draft
                    feedback = EditorFeedback(message: "Curve applied.", isSuccess: true)
                } else {
                    feedback = EditorFeedback(
                        message: "The daemon rejected the staged curve.",
                        isSuccess: false
                    )
                }
                isApplying = false
            }
        } catch {
            feedback = EditorFeedback(message: "Curve validation failed.", isSuccess: false)
            isApplying = false
        }
    }

    private func sensorGroups(for curve: EditableFanCurve) -> [String] {
        // Only offer sensor groups that exist on this Mac (plus any group the
        // stored mix already weights) — a slider for a never-present group
        // (e.g. cpu_eff on machines without a separate E-core sensor) silently
        // contributes nothing.
        let preferredOrder = ["cpu_perf", "cpu_eff", "gpu", "soc"]
        let present = Set(observer.status?.sensors.map(\.groupName) ?? [])
        func visible(_ group: String) -> Bool {
            present.contains(group) || (curve.inputMix[group] ?? 0) > 0
        }
        let preferred = preferredOrder.filter(visible)
        let extras = curve.inputMix.keys
            .filter { !preferredOrder.contains($0) && visible($0) }
            .sorted()
        return preferred + extras
    }

    private func weightedTemperature(_ curve: EditableFanCurve) -> Double? {
        guard let status = observer.status else { return nil }
        var weighted = 0.0
        var weightTotal = 0.0
        for (group, weight) in curve.inputMix {
            if let temperature = status.temperature(for: group) {
                weighted += temperature * weight
                weightTotal += weight
            }
        }
        return weightTotal > 0 ? weighted / weightTotal : nil
    }

    private func interpolate(points: [EditableCurvePoint], temperature: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if temperature <= first.temp { return first.rpm }
        if temperature >= last.temp { return last.rpm }
        for index in 0..<(points.count - 1) {
            let left = points[index]
            let right = points[index + 1]
            if temperature <= right.temp {
                let fraction = (temperature - left.temp) / (right.temp - left.temp)
                return left.rpm + (right.rpm - left.rpm) * fraction
            }
        }
        return last.rpm
    }
}

private struct CurvePlot: View {
    @Binding var points: [EditableCurvePoint]
    let currentTemperature: Double?
    let currentRPM: Double?
    let hysteresisGap: Double
    @State private var hoveredPoint: Int?
    /// Index of a point currently dragged outside the plot (armed for removal
    /// on release, Photoshop-style).
    @State private var pointPendingRemoval: Int?

    private static let maxPoints = 8
    /// Distance beyond the plot edge that arms removal.
    private static let removalMargin: CGFloat = 30

    private let insets = EdgeInsets(top: 20, leading: 48, bottom: 34, trailing: 18)

    private var minTemp: Double {
        min(30, floor((points.first?.temp ?? 30) / 10) * 10)
    }

    private var maxTemp: Double {
        max(100, ceil((points.last?.temp ?? 100) / 10) * 10)
    }

    private var maxRPM: Double {
        let configuredMaximum = points.map(\.rpm).max() ?? 7000
        return min(8000, max(7000, ceil(configuredMaximum / 1000) * 1000))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Canvas { context, size in
                    let rect = plotRect(size)
                    drawGrid(context: &context, rect: rect)
                    drawHysteresis(context: &context, rect: rect)
                    drawCurve(context: &context, rect: rect)
                }
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture(coordinateSpace: .named("plot"))
                        .onEnded { addPoint(at: $0.location, size: proxy.size) }
                )

                axisLabels(size: proxy.size)

                // Hit-testing order is load-bearing: contentShape and gestures
                // must be applied to the SMALL dot view BEFORE .position — after
                // .position they bind to the full-plot wrapper and the grab
                // targets land in the wrong place entirely.
                ForEach(points.indices, id: \.self) { index in
                    Circle()
                        .fill(
                            pointPendingRemoval == index
                                ? VentusPalette.hot.opacity(0.25)
                                : hoveredPoint == index
                                    ? VentusPalette.accentTint
                                    : VentusPalette.surface
                        )
                        .overlay {
                            Circle()
                                .stroke(
                                    pointPendingRemoval == index
                                        ? VentusPalette.hot
                                        : VentusPalette.accent,
                                    lineWidth: 2.5
                                )
                        }
                        .frame(
                            width: hoveredPoint == index ? 16 : 13,
                            height: hoveredPoint == index ? 16 : 13
                        )
                        .shadow(color: VentusPalette.shadow, radius: 3, y: 1)
                        .contentShape(Circle().inset(by: -10))
                        .onHover { isHovering in
                            if isHovering {
                                hoveredPoint = index
                            } else if hoveredPoint == index {
                                hoveredPoint = nil
                            }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named("plot"))
                                .onChanged { value in
                                    let outside = distanceOutsidePlot(
                                        value.location, size: proxy.size
                                    ) > Self.removalMargin
                                    if outside, points.count > 2 {
                                        pointPendingRemoval = index
                                    } else {
                                        pointPendingRemoval = nil
                                        updatePoint(
                                            at: index,
                                            location: value.location,
                                            size: proxy.size
                                        )
                                    }
                                }
                                .onEnded { _ in
                                    // indices.contains guards a stale captured
                                    // index after another removal shifted the
                                    // array (out-of-bounds trap otherwise).
                                    if pointPendingRemoval == index,
                                       points.indices.contains(index),
                                       points.count > 2 {
                                        points.remove(at: index)
                                    }
                                    pointPendingRemoval = nil
                                }
                        )
                        .simultaneousGesture(
                            TapGesture(count: 2).onEnded {
                                if points.indices.contains(index), points.count > 2 {
                                    points.remove(at: index)
                                }
                            }
                        )
                        .help(
                            String(
                                format: "%.0f°C, %.0f RPM — double-click to remove",
                                points[index].temp,
                                points[index].rpm
                            )
                        )
                        .animation(.easeOut(duration: 0.12), value: hoveredPoint)
                        .position(position(for: points[index], size: proxy.size))
                }

                if let marker = livePosition(size: proxy.size) {
                    Path { path in
                        path.move(to: CGPoint(x: marker.x, y: plotRect(proxy.size).maxY))
                        path.addLine(to: marker)
                    }
                    .stroke(
                        VentusPalette.accent.opacity(0.58),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                    )
                    Circle()
                        .fill(VentusPalette.accent.opacity(0.20))
                        .frame(width: 22, height: 22)
                        .position(marker)
                    Circle()
                        .fill(VentusPalette.accent)
                        .overlay {
                            Circle()
                                .stroke(VentusPalette.surface, lineWidth: 2)
                        }
                        .frame(width: 11, height: 11)
                        .position(marker)
                    // Below the marker, along the dashed drop line — above it
                    // the label collides with the curve. Chip background keeps
                    // it legible over the hysteresis band.
                    Text("you are here")
                        .font(VentusFont.body(10, weight: .bold))
                        .foregroundStyle(VentusPalette.accentDeep)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background {
                            Capsule().fill(VentusPalette.surface.opacity(0.92))
                        }
                        .position(
                            x: min(
                                max(marker.x, plotRect(proxy.size).minX + 40),
                                plotRect(proxy.size).maxX - 40
                            ),
                            y: min(marker.y + 24, plotRect(proxy.size).maxY - 10)
                        )
                }
            }
            .coordinateSpace(name: "plot")
        }
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(VentusPalette.surface2.opacity(0.62))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(VentusPalette.border, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Temperature to RPM curve editor")
    }

    private func drawGrid(context: inout GraphicsContext, rect: CGRect) {
        for fraction in [0.0, 0.5, 1.0] {
            let y = rect.maxY - rect.height * fraction
            var line = Path()
            line.move(to: CGPoint(x: rect.minX, y: y))
            line.addLine(to: CGPoint(x: rect.maxX, y: y))
            context.stroke(
                line,
                with: .color(VentusPalette.border),
                style: StrokeStyle(
                    lineWidth: 1,
                    dash: fraction == 0 ? [] : [4, 5]
                )
            )
        }

        var vertical = Path()
        vertical.move(to: CGPoint(x: rect.minX, y: rect.minY))
        vertical.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        context.stroke(vertical, with: .color(VentusPalette.border), lineWidth: 1)
    }

    private func drawHysteresis(context: inout GraphicsContext, rect: CGRect) {
        guard points.count >= 2, hysteresisGap > 0 else { return }
        let sampleCount = 48
        let temperatures = (0...sampleCount).map {
            minTemp + (maxTemp - minTemp) * Double($0) / Double(sampleCount)
        }

        var band = Path()
        for (index, temperature) in temperatures.enumerated() {
            let rpm = interpolate(temperature)
            let point = plotPoint(temperature: temperature, rpm: rpm, rect: rect)
            index == 0 ? band.move(to: point) : band.addLine(to: point)
        }
        for temperature in temperatures.reversed() {
            let heldRPM = interpolate(min(temperature + hysteresisGap, maxTemp))
            band.addLine(
                to: plotPoint(temperature: temperature, rpm: heldRPM, rect: rect)
            )
        }
        band.closeSubpath()
        context.fill(band, with: .color(VentusPalette.accent.opacity(0.11)))
    }

    private func drawCurve(context: inout GraphicsContext, rect: CGRect) {
        guard let first = points.first, let last = points.last else { return }
        let plotPoints = points.map { plotPoint($0, rect: rect) }
        let line = smoothPath(through: plotPoints)

        var area = line
        area.addLine(to: CGPoint(x: plotPoint(last, rect: rect).x, y: rect.maxY))
        area.addLine(to: CGPoint(x: plotPoint(first, rect: rect).x, y: rect.maxY))
        area.closeSubpath()
        context.fill(area, with: .color(VentusPalette.accent.opacity(0.06)))
        context.stroke(
            line,
            with: .color(VentusPalette.accent),
            style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
        )
    }

    private func axisLabels(size: CGSize) -> some View {
        let rect = plotRect(size)
        return ZStack {
            Text("100%")
                .position(x: rect.minX - 24, y: rect.minY + 2)
            Text("50%")
                .position(x: rect.minX - 22, y: rect.midY)
            Text("0%")
                .position(x: rect.minX - 18, y: rect.maxY)
            Text(String(format: "%.0f°C", minTemp))
                .position(x: rect.minX + 15, y: rect.maxY + 20)
            Text(String(format: "%.0f°C", (minTemp + maxTemp) / 2))
                .position(x: rect.midX, y: rect.maxY + 20)
            Text(String(format: "%.0f°C", maxTemp))
                .position(x: rect.maxX - 18, y: rect.maxY + 20)
        }
        .font(VentusFont.number(10, weight: .medium))
        .foregroundStyle(VentusPalette.ink3)
        .allowsHitTesting(false)
    }

    /// How far a location sits outside the plot rect (0 when inside).
    private func distanceOutsidePlot(_ location: CGPoint, size: CGSize) -> CGFloat {
        let rect = plotRect(size)
        let dx = max(rect.minX - location.x, location.x - rect.maxX, 0)
        let dy = max(rect.minY - location.y, location.y - rect.maxY, 0)
        return max(dx, dy)
    }

    /// Photoshop-style: click on empty plot area inserts a point at the click,
    /// clamped into the monotonic envelope of its neighbors.
    private func addPoint(at location: CGPoint, size: CGSize) {
        guard points.count < Self.maxPoints else { return }
        let rect = plotRect(size)
        guard rect.insetBy(dx: -4, dy: -4).contains(location) else { return }

        let temp = minTemp
            + Double(location.x - rect.minX) / Double(rect.width) * (maxTemp - minTemp)
        let rpm = Double(rect.maxY - location.y) / Double(rect.height) * maxRPM

        let insertion = points.firstIndex(where: { $0.temp > temp }) ?? points.count
        let lowerTemp = insertion > 0 ? points[insertion - 1].temp + 1 : minTemp
        let upperTemp = insertion < points.count ? points[insertion].temp - 1 : maxTemp
        guard lowerTemp <= upperTemp else { return }   // no room between neighbors
        let lowerRPM = insertion > 0 ? points[insertion - 1].rpm : 0
        let upperRPM = insertion < points.count ? points[insertion].rpm : maxRPM

        points.insert(
            EditableCurvePoint(
                temp: min(max(temp, lowerTemp), upperTemp),
                rpm: min(max(rpm, lowerRPM), upperRPM)
            ),
            at: insertion
        )
    }

    private func updatePoint(at index: Int, location: CGPoint, size: CGSize) {
        guard points.indices.contains(index) else { return }
        let rect = plotRect(size)
        let rawTemp = minTemp
            + Double(min(max(location.x, rect.minX), rect.maxX) - rect.minX)
            / Double(rect.width) * (maxTemp - minTemp)
        let rawRPM = Double(rect.maxY - min(max(location.y, rect.minY), rect.maxY))
            / Double(rect.height) * maxRPM

        let minimumTemp = index > 0 ? points[index - 1].temp + 1 : minTemp
        let maximumTemp = index < points.count - 1 ? points[index + 1].temp - 1 : maxTemp
        let minimumRPM = index > 0 ? points[index - 1].rpm : 0
        let maximumRPM = index < points.count - 1 ? points[index + 1].rpm : maxRPM

        points[index] = EditableCurvePoint(
            temp: min(max(rawTemp, minimumTemp), maximumTemp),
            rpm: min(max(rawRPM, minimumRPM), maximumRPM)
        )
    }

    private func livePosition(size: CGSize) -> CGPoint? {
        guard let currentTemperature else { return nil }
        let rpm = currentRPM ?? interpolate(currentTemperature)
        return plotPoint(
            temperature: min(max(currentTemperature, minTemp), maxTemp),
            rpm: min(max(rpm, 0), maxRPM),
            rect: plotRect(size)
        )
    }

    private func smoothPath(through plotPoints: [CGPoint]) -> Path {
        var path = Path()
        guard let first = plotPoints.first else { return path }
        path.move(to: first)
        guard plotPoints.count > 1 else { return path }

        for index in 0..<(plotPoints.count - 1) {
            let previous = plotPoints[max(index - 1, 0)]
            let current = plotPoints[index]
            let next = plotPoints[index + 1]
            let following = plotPoints[min(index + 2, plotPoints.count - 1)]
            let control1 = CGPoint(
                x: clamp(
                    current.x + (next.x - previous.x) / 6,
                    between: current.x,
                    and: next.x
                ),
                y: clamp(
                    current.y + (next.y - previous.y) / 6,
                    between: current.y,
                    and: next.y
                )
            )
            let control2 = CGPoint(
                x: clamp(
                    next.x - (following.x - current.x) / 6,
                    between: current.x,
                    and: next.x
                ),
                y: clamp(
                    next.y - (following.y - current.y) / 6,
                    between: current.y,
                    and: next.y
                )
            )
            path.addCurve(to: next, control1: control1, control2: control2)
        }
        return path
    }

    private func clamp(_ value: CGFloat, between first: CGFloat, and second: CGFloat) -> CGFloat {
        min(max(value, min(first, second)), max(first, second))
    }

    private func position(for point: EditableCurvePoint, size: CGSize) -> CGPoint {
        plotPoint(point, rect: plotRect(size))
    }

    private func plotRect(_ size: CGSize) -> CGRect {
        CGRect(
            x: insets.leading,
            y: insets.top,
            width: max(1, size.width - insets.leading - insets.trailing),
            height: max(1, size.height - insets.top - insets.bottom)
        )
    }

    private func plotPoint(_ point: EditableCurvePoint, rect: CGRect) -> CGPoint {
        plotPoint(temperature: point.temp, rpm: point.rpm, rect: rect)
    }

    private func plotPoint(temperature: Double, rpm: Double, rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + CGFloat((temperature - minTemp) / (maxTemp - minTemp)) * rect.width,
            y: rect.maxY - CGFloat(rpm / maxRPM) * rect.height
        )
    }

    private func interpolate(_ temperature: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if temperature <= first.temp { return first.rpm }
        if temperature >= last.temp { return last.rpm }
        for index in 0..<(points.count - 1) {
            let left = points[index]
            let right = points[index + 1]
            if temperature <= right.temp {
                let fraction = (temperature - left.temp) / (right.temp - left.temp)
                return left.rpm + (right.rpm - left.rpm) * fraction
            }
        }
        return last.rpm
    }
}

private struct EditorFeedback {
    let message: String
    let isSuccess: Bool
}

private struct EditableConfig: Codable, Equatable {
    var schemaVersion: Int
    var armed: Bool
    var profiles: [String: EditableProfile]
    var rules: RulesConfig
    var engine: EngineParams
    var pinnedProfile: String?
}

private struct EditableProfile: Codable, Equatable {
    var name: String
    var curves: [Int: EditableFanCurve]
    var powerCurve: PowerCurve?
    var emaTimeConstantS: Double
    var hysteresisGapC: Double
    var hysteresisDwellS: Double
}

private struct EditableFanCurve: Codable, Equatable {
    var inputMix: [String: Double]
    var points: [EditableCurvePoint]

    private enum CodingKeys: String, CodingKey {
        case inputMix
        case points
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        points = try container.decode([EditableCurvePoint].self, forKey: .points)

        if let keyedMix = try? container.decode([String: Double].self, forKey: .inputMix) {
            inputMix = keyedMix
            return
        }

        var unkeyedMix = try container.nestedUnkeyedContainer(forKey: .inputMix)
        var decodedMix: [String: Double] = [:]
        while !unkeyedMix.isAtEnd {
            let groupName = try unkeyedMix.decode(String.self)
            decodedMix[groupName] = try unkeyedMix.decode(Double.self)
        }
        inputMix = decodedMix
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(points, forKey: .points)
        var unkeyedMix = container.nestedUnkeyedContainer(forKey: .inputMix)
        for groupName in inputMix.keys.sorted() {
            try unkeyedMix.encode(groupName)
            try unkeyedMix.encode(inputMix[groupName])
        }
    }
}

private struct EditableCurvePoint: Codable, Equatable {
    var temp: Double
    var rpm: Double
}
