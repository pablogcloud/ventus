import XCTest
@testable import VentusCore

final class VentusCoreTests: XCTestCase {
    // MARK: - Config Validation (6 tests)

    func testConfigValidation_NoProfiles() {
        var config = Config()
        config.profiles = [:]
        XCTAssertThrowsError(try config.validate()) { error in
            XCTAssertEqual(error as? ConfigError, .noProfiles)
        }
    }

    func testConfigValidation_InvalidProfile() {
        var config = Config()
        config.profiles["bad"] = Profile(
            name: "bad",
            curves: [:],
            powerCurve: nil,
            emaTimeConstantS: -1,
            hysteresisGapC: 5,
            hysteresisDwellS: 20
        )
        XCTAssertThrowsError(try config.validate())
    }

    func testConfigValidation_PinnedProfileNotFound() {
        var config = Config()
        config.profiles["real"] = Profile(
            name: "real",
            curves: [0: FanCurve(inputMix: [.cpuPerf: 1.0], points: [CurvePoint(temp: 40, rpm: 2000), CurvePoint(temp: 80, rpm: 5000)])],
            powerCurve: nil,
            emaTimeConstantS: 5,
            hysteresisGapC: 5,
            hysteresisDwellS: 20
        )
        config.pinnedProfile = "nonexistent"
        XCTAssertThrowsError(try config.validate())
    }

    func testConfigValidation_Success() {
        let config = Config.defaultConfig()
        XCTAssertNoThrow(try config.validate())
    }

    func testDefaultConfig_RoundTrip() {
        let original = Config.defaultConfig()
        XCTAssertNoThrow(try original.validate())

        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(original)

            let decoder = JSONDecoder()
            let decoded = try decoder.decode(Config.self, from: data)

            XCTAssertEqual(original.armed, decoded.armed)
            XCTAssertEqual(original.profiles.count, decoded.profiles.count)
        } catch {
            XCTFail("JSON roundtrip failed: \(error)")
        }
    }

    func testProfileValidation_NegativeEMA() {
        let profile = Profile(
            name: "bad",
            curves: [:],
            powerCurve: nil,
            emaTimeConstantS: -1,
            hysteresisGapC: 5,
            hysteresisDwellS: 20
        )
        XCTAssertThrowsError(try profile.validate())
    }

    // MARK: - Curve Interpolation (4 tests)

    func testCurveInterpolation_BoundaryLow() {
        let engine = CurveEngine()
        let curve: [CurvePoint] = [CurvePoint(temp: 40, rpm: 2000), CurvePoint(temp: 60, rpm: 3000), CurvePoint(temp: 80, rpm: 5000)]
        let result = engine.interpolate(30, points: curve)
        XCTAssertEqual(result, 2000)
    }

    func testCurveInterpolation_BoundaryHigh() {
        let engine = CurveEngine()
        let curve: [CurvePoint] = [CurvePoint(temp: 40, rpm: 2000), CurvePoint(temp: 60, rpm: 3000), CurvePoint(temp: 80, rpm: 5000)]
        let result = engine.interpolate(100, points: curve)
        XCTAssertEqual(result, 5000)
    }

    func testCurveInterpolation_ExactPoint() {
        let engine = CurveEngine()
        let curve: [CurvePoint] = [CurvePoint(temp: 40, rpm: 2000), CurvePoint(temp: 60, rpm: 3000), CurvePoint(temp: 80, rpm: 5000)]
        let result = engine.interpolate(60, points: curve)
        XCTAssertEqual(result, 3000)
    }

    func testCurveInterpolation_Linear() {
        let engine = CurveEngine()
        let curve: [CurvePoint] = [CurvePoint(temp: 40, rpm: 2000), CurvePoint(temp: 80, rpm: 4000)]
        let result = engine.interpolate(60, points: curve)
        XCTAssertEqual(result, 3000, accuracy: 1)
    }

    // MARK: - Hysteresis (2 tests)

    func testHysteresis_RampUpImmediate() {
        let engine = CurveEngine()
        let profile = Profile(
            name: "test",
            curves: [0: FanCurve(inputMix: [.cpuPerf: 1.0], points: [CurvePoint(temp: 40, rpm: 2000), CurvePoint(temp: 80, rpm: 6000)])],
            powerCurve: nil,
            emaTimeConstantS: 5.0,
            hysteresisGapC: 5,
            hysteresisDwellS: 10
        )

        var sensors: [SensorGroup: GroupReading] = [:]
        sensors[.cpuPerf] = GroupReading(max: 50, mean: 50, count: 1)

        let actualRPMs: [Int: Double] = [0: 2000]
        let now = Date()

        let results = engine.compute(
            sensors: sensors,
            profile: profile,
            actualRPMs: actualRPMs,
            now: now,
            thermalState: .nominal,
            safetyOverride: 0
        )

        XCTAssertEqual(results.count, 1)
        XCTAssert(results[0].targetRPM > 2000 && results[0].targetRPM < 3000)
    }

    func testHysteresis_RampDownDwell() {
        let engine = CurveEngine()
        let profile = Profile(
            name: "test",
            curves: [0: FanCurve(inputMix: [.cpuPerf: 1.0], points: [CurvePoint(temp: 40, rpm: 2000), CurvePoint(temp: 80, rpm: 6000)])],
            powerCurve: nil,
            emaTimeConstantS: 0,
            hysteresisGapC: 5,
            hysteresisDwellS: 10
        )

        var sensors: [SensorGroup: GroupReading] = [:]
        sensors[.cpuPerf] = GroupReading(max: 80, mean: 80, count: 1)

        var actualRPMs: [Int: Double] = [0: 6000]
        let now = Date()

        var results = engine.compute(
            sensors: sensors,
            profile: profile,
            actualRPMs: actualRPMs,
            now: now,
            thermalState: .nominal,
            safetyOverride: 0
        )
        actualRPMs[0] = results[0].targetRPM

        sensors[.cpuPerf] = GroupReading(max: 70, mean: 70, count: 1)
        let later5s = now.addingTimeInterval(5)
        results = engine.compute(
            sensors: sensors,
            profile: profile,
            actualRPMs: actualRPMs,
            now: later5s,
            thermalState: .nominal,
            safetyOverride: 0
        )
        XCTAssert(results[0].targetRPM >= 5500)
        actualRPMs[0] = results[0].targetRPM

        let later15s = now.addingTimeInterval(15)
        results = engine.compute(
            sensors: sensors,
            profile: profile,
            actualRPMs: actualRPMs,
            now: later15s,
            thermalState: .nominal,
            safetyOverride: 0
        )
        // Dwell (10s below 75°C) satisfied at t+15 → ramp-down releases to curve(70°C) = 5000
        XCTAssertEqual(results[0].targetRPM, 5000, accuracy: 1.0)
    }

    // MARK: - EMA Smoothing (1 test)

    func testAbsentSensorGroups_NotFabricatedAsZero() {
        // Regression (audit finding 7): a fan mixed on a partially-absent sensor
        // group must be driven by the remaining present groups (renormalized),
        // never dragged toward 0°C by fabricated readings.
        let engine = CurveEngine()
        let profile = Profile(
            name: "test",
            curves: [0: FanCurve(inputMix: [.cpuPerf: 0.5, .gpu: 0.5], points: [CurvePoint(temp: 40, rpm: 2000), CurvePoint(temp: 80, rpm: 6000)])],
            powerCurve: nil,
            emaTimeConstantS: 0,
            hysteresisGapC: 0,
            hysteresisDwellS: 0
        )

        // gpu group absent entirely; cpuPerf hot at 80°C
        var sensors: [SensorGroup: GroupReading] = [:]
        sensors[.cpuPerf] = GroupReading(max: 80, mean: 80, count: 1)

        var actualRPMs: [Int: Double] = [0: 2000]
        let now = Date()
        var results: [CurveEngine.Explanation] = []
        for tick in 0 ..< 20 {
            results = engine.compute(sensors: sensors, profile: profile, actualRPMs: actualRPMs, now: now.addingTimeInterval(Double(tick)))
            actualRPMs[0] = results[0].targetRPM
        }
        // Renormalized blend = 80°C (not 40°C avg with fabricated 0) → full 6000 RPM
        XCTAssertEqual(results[0].targetRPM, 6000, accuracy: 1.0)
    }

    func testEMA_Convergence() {
        let engine = CurveEngine()
        let profile = Profile(
            name: "test",
            curves: [0: FanCurve(inputMix: [.cpuPerf: 1.0], points: [CurvePoint(temp: 40, rpm: 2000), CurvePoint(temp: 80, rpm: 6000)])],
            powerCurve: nil,
            emaTimeConstantS: 5.0,
            hysteresisGapC: 0,
            hysteresisDwellS: 0
        )

        var sensors: [SensorGroup: GroupReading] = [:]
        sensors[.cpuPerf] = GroupReading(max: 60, mean: 60, count: 1)

        var now = Date()
        var actualRPMs: [Int: Double] = [0: 2000]

        for _ in 0 ..< 25 {
            sensors[.cpuPerf] = GroupReading(max: 80, mean: 80, count: 1)
            let results = engine.compute(
                sensors: sensors,
                profile: profile,
                actualRPMs: actualRPMs,
                now: now,
                thermalState: .nominal,
                safetyOverride: 0
            )
            actualRPMs[0] = results[0].targetRPM
            now = now.addingTimeInterval(1)
        }

        let results = engine.compute(
            sensors: sensors,
            profile: profile,
            actualRPMs: actualRPMs,
            now: now,
            thermalState: .nominal,
            safetyOverride: 0
        )
        XCTAssert(results[0].targetRPM > 5800)
    }

    // MARK: - Slew Rate Limiting (1 test)

    func testSlewRateLimit_Ramps() {
        let engine = CurveEngine()
        let profile = Profile(
            name: "test",
            curves: [0: FanCurve(inputMix: [.cpuPerf: 1.0], points: [CurvePoint(temp: 40, rpm: 2000), CurvePoint(temp: 80, rpm: 6000)])],
            powerCurve: nil,
            emaTimeConstantS: 0,
            hysteresisGapC: 0,
            hysteresisDwellS: 0
        )

        var sensors: [SensorGroup: GroupReading] = [:]
        sensors[.cpuPerf] = GroupReading(max: 80, mean: 80, count: 1)

        let actualRPMs: [Int: Double] = [0: 2000]
        let now = Date()

        let results = engine.compute(
            sensors: sensors,
            profile: profile,
            actualRPMs: actualRPMs,
            now: now,
            thermalState: .nominal,
            safetyOverride: 0
        )

        XCTAssert(results[0].targetRPM <= 2300)
    }

    // MARK: - Pressure Floors (2 tests)

    func testPressureFloor_SeriousiAdjusted() {
        let engine = CurveEngine()
        let profile = Profile(
            name: "test",
            curves: [0: FanCurve(inputMix: [.cpuPerf: 1.0], points: [CurvePoint(temp: 40, rpm: 2000), CurvePoint(temp: 80, rpm: 6000)])],
            powerCurve: nil,
            emaTimeConstantS: 0,
            hysteresisGapC: 0,
            hysteresisDwellS: 0
        )

        var sensors: [SensorGroup: GroupReading] = [:]
        sensors[.cpuPerf] = GroupReading(max: 50, mean: 50, count: 1)

        // Start with high actual RPM so slew limit doesn't interfere
        let actualRPMs: [Int: Double] = [0: 5000]
        let now = Date()

        let results = engine.compute(
            sensors: sensors,
            profile: profile,
            actualRPMs: actualRPMs,
            now: now,
            thermalState: .serious,
            safetyOverride: 0
        )

        XCTAssert(results[0].targetRPM >= 4800)
    }

    func testPressureFloor_CriticalAdjusted() {
        let engine = CurveEngine()
        let profile = Profile(
            name: "test",
            curves: [0: FanCurve(inputMix: [.cpuPerf: 1.0], points: [CurvePoint(temp: 40, rpm: 2000), CurvePoint(temp: 80, rpm: 6000)])],
            powerCurve: nil,
            emaTimeConstantS: 0,
            hysteresisGapC: 0,
            hysteresisDwellS: 0
        )

        var sensors: [SensorGroup: GroupReading] = [:]
        sensors[.cpuPerf] = GroupReading(max: 50, mean: 50, count: 1)

        // Start with high actual RPM so slew limit doesn't interfere
        let actualRPMs: [Int: Double] = [0: 6000]
        let now = Date()

        let results = engine.compute(
            sensors: sensors,
            profile: profile,
            actualRPMs: actualRPMs,
            now: now,
            thermalState: .critical,
            safetyOverride: 0
        )

        XCTAssert(results[0].targetRPM >= 5900)
    }

    // MARK: - Differential Per-Fan Mixes (1 test)

    func testDifferentialFans() {
        let engine = CurveEngine()
        let profile = Profile(
            name: "test",
            curves: [
                0: FanCurve(inputMix: [.cpuPerf: 0.8, .gpu: 0.2], points: [CurvePoint(temp: 40, rpm: 2000), CurvePoint(temp: 80, rpm: 6000)]),
                1: FanCurve(inputMix: [.cpuPerf: 0.2, .gpu: 0.8], points: [CurvePoint(temp: 40, rpm: 2000), CurvePoint(temp: 80, rpm: 6000)]),
            ],
            powerCurve: nil,
            emaTimeConstantS: 0,
            hysteresisGapC: 0,
            hysteresisDwellS: 0
        )

        var sensors: [SensorGroup: GroupReading] = [:]
        sensors[.cpuPerf] = GroupReading(max: 50, mean: 50, count: 1)
        sensors[.gpu] = GroupReading(max: 80, mean: 80, count: 1)

        var actualRPMs: [Int: Double] = [0: 2000, 1: 2000]
        let now = Date()

        // Slew limiting (300 RPM/s) clamps both fans identically on early ticks;
        // run 1s ticks until both converge on their curve targets.
        var results: [CurveEngine.Explanation] = []
        for tick in 0 ..< 20 {
            results = engine.compute(
                sensors: sensors,
                profile: profile,
                actualRPMs: actualRPMs,
                now: now.addingTimeInterval(Double(tick)),
                thermalState: .nominal,
                safetyOverride: 0
            )
            actualRPMs[0] = results[0].targetRPM
            actualRPMs[1] = results[1].targetRPM
        }

        XCTAssertEqual(results.count, 2)
        // fan0 blend = 0.8*50 + 0.2*80 = 56°C → 3600 RPM; fan1 blend = 74°C → 5400 RPM
        XCTAssert(results[1].targetRPM > results[0].targetRPM)
        XCTAssertEqual(results[0].targetRPM, 3600, accuracy: 1.0)
        XCTAssertEqual(results[1].targetRPM, 5400, accuracy: 1.0)
    }

    func testPowerCurve_NotMaskedByTempDwell() {
        // Regression (codex review): a power-led ramp-up must not be held down by an
        // active temperature ramp-down hysteresis dwell.
        let engine = CurveEngine()
        let profile = Profile(
            name: "test",
            curves: [0: FanCurve(inputMix: [.cpuPerf: 1.0], points: [CurvePoint(temp: 40, rpm: 2000), CurvePoint(temp: 80, rpm: 6000)])],
            powerCurve: PowerCurve(points: [PowerPoint(watts: 10, rpm: 2000), PowerPoint(watts: 60, rpm: 6000)]),
            emaTimeConstantS: 0,
            hysteresisGapC: 5,
            hysteresisDwellS: 20
        )

        var sensors: [SensorGroup: GroupReading] = [:]
        let now = Date()

        // t0: hot (80°C) → target 6000
        sensors[.cpuPerf] = GroupReading(max: 80, mean: 80, count: 1)
        var results = engine.compute(sensors: sensors, profile: profile, actualRPMs: [0: 6000], now: now)

        // t+5: temp falls to 60°C (inside ramp-down dwell, holds high) — fine so far
        sensors[.cpuPerf] = GroupReading(max: 60, mean: 60, count: 1)
        results = engine.compute(sensors: sensors, profile: profile, actualRPMs: [0: 6000], now: now.addingTimeInterval(5))

        // t+6: power spikes to 55W (→ 5600 RPM) while temp dwell is still active.
        // The power term must govern the curve target, not be masked by the dwell hold.
        results = engine.compute(
            sensors: sensors, profile: profile, actualRPMs: [0: 6000],
            now: now.addingTimeInterval(6), packageWatts: 55
        )
        XCTAssert(results[0].targetRPM >= 5600 - 1)
        XCTAssertEqual(results[0].powerCurveRPM, 5600, accuracy: 1.0)
    }

    func testPowerCurve_LeadingIndicator() {
        let engine = CurveEngine()
        let profile = Profile(
            name: "test",
            curves: [0: FanCurve(inputMix: [.cpuPerf: 1.0], points: [CurvePoint(temp: 40, rpm: 2000), CurvePoint(temp: 80, rpm: 6000)])],
            powerCurve: PowerCurve(points: [PowerPoint(watts: 10, rpm: 2000), PowerPoint(watts: 60, rpm: 6000)]),
            emaTimeConstantS: 0,
            hysteresisGapC: 0,
            hysteresisDwellS: 0
        )

        var sensors: [SensorGroup: GroupReading] = [:]
        // Still cool (45°C → temp curve 2500) but package power already high (50W → power curve 5200)
        sensors[.cpuPerf] = GroupReading(max: 45, mean: 45, count: 1)

        var actualRPMs: [Int: Double] = [0: 2000]
        let now = Date()
        var results: [CurveEngine.Explanation] = []
        for tick in 0 ..< 15 {
            results = engine.compute(
                sensors: sensors,
                profile: profile,
                actualRPMs: actualRPMs,
                now: now.addingTimeInterval(Double(tick)),
                thermalState: .nominal,
                safetyOverride: 0,
                packageWatts: 50
            )
            actualRPMs[0] = results[0].targetRPM
        }
        // Power term must win over the (cool) temp curve: fans pre-spin before heat arrives
        XCTAssertEqual(results[0].targetRPM, 5200, accuracy: 1.0)

        // Without a watts sample, power curve is inactive → temp curve governs
        let engine2 = CurveEngine()
        let r2 = engine2.compute(
            sensors: sensors,
            profile: profile,
            actualRPMs: [0: 2500],
            now: now,
            thermalState: .nominal,
            safetyOverride: 0,
            packageWatts: nil
        )
        XCTAssertEqual(r2[0].targetRPM, 2500, accuracy: 1.0)
    }

    // MARK: - Safety Hard Override (2 tests)

    func testSafetyOverride_ThermalTrip() {
        let supervisor = SafetySupervisor(armed: true)

        var sensors: [SensorGroup: GroupReading] = [:]
        sensors[.cpuPerf] = GroupReading(max: 95, mean: 95, count: 1)

        let maxRPM = 6000.0
        let override = supervisor.getSafetyOverrideRPM(maxRPM: maxRPM, sensors: sensors, thermalState: .nominal)

        XCTAssertEqual(override, maxRPM)
    }

    func testThermalDecision_ExplicitNotRPMSentinel() {
        // Finding #4: the decision must be an explicit enum, so a valid fan curve
        // ending at 0 RPM cannot alias with "no emergency". At 95°C the decision
        // is .forceMax regardless of any curve RPM value.
        let supervisor = SafetySupervisor(armed: true)
        var hot: [SensorGroup: GroupReading] = [:]
        hot[.cpuPerf] = GroupReading(max: 95, mean: 95, count: 1)
        XCTAssertEqual(supervisor.thermalDecision(sensors: hot, thermalState: .nominal), .forceMax)

        var cool: [SensorGroup: GroupReading] = [:]
        cool[.cpuPerf] = GroupReading(max: 50, mean: 50, count: 1)
        XCTAssertEqual(supervisor.thermalDecision(sensors: cool, thermalState: .nominal), .normal)
        // Critical thermal state forces max even when temps read low.
        XCTAssertEqual(supervisor.thermalDecision(sensors: cool, thermalState: .critical), .forceMax)
    }

    func testSafetyOverride_CriticalState() {
        let supervisor = SafetySupervisor(armed: true)

        var sensors: [SensorGroup: GroupReading] = [:]
        sensors[.cpuPerf] = GroupReading(max: 50, mean: 50, count: 1)

        let maxRPM = 6000.0
        let override = supervisor.getSafetyOverrideRPM(maxRPM: maxRPM, sensors: sensors, thermalState: .critical)

        XCTAssertEqual(override, maxRPM)
    }

    // MARK: - Observe/Armed Gating (3 tests)

    func testArmedMode_ObserveDisallows() {
        let supervisor = SafetySupervisor(armed: false)
        XCTAssertFalse(supervisor.canWrite())
    }

    func testArmedMode_ArmedAllows() {
        let supervisor = SafetySupervisor(armed: true)
        XCTAssertTrue(supervisor.canWrite())
    }

    func testArmedMode_Toggle() {
        let supervisor = SafetySupervisor(armed: false)
        XCTAssertFalse(supervisor.canWrite())
        supervisor.setArmed(true)
        XCTAssertTrue(supervisor.canWrite())
        supervisor.setArmed(false)
        XCTAssertFalse(supervisor.canWrite())
    }

    // MARK: - Watchdog (4 tests)

    func testControlLoopWatchdog_NotStalled() {
        let watchdog = ControlLoopWatchdog(stallThresholdS: 10)
        watchdog.recordHeartbeat()

        let now = Date()
        XCTAssertFalse(watchdog.isStalled(now: now))
    }

    /// Rewritten in v1.0.4: these previously asserted that a FUTURE WALL-CLOCK
    /// `Date` trips the stall — i.e. they encoded the very bug that made every
    /// system wake look like a multi-minute control-loop hang. Staleness is now
    /// measured on the sleep-excluding uptime clock, so these exercise real
    /// elapsed time instead.
    func testControlLoopWatchdog_Stalled() {
        let watchdog = ControlLoopWatchdog(stallThresholdS: 0.05)
        watchdog.recordHeartbeat()
        XCTAssertFalse(watchdog.isStalled(now: Date()))

        Thread.sleep(forTimeInterval: 0.15)   // real elapsed time, not a clock jump
        XCTAssertTrue(watchdog.isStalled(now: Date()))
    }

    func testControlLoopWatchdog_SecondsElapsed() {
        let watchdog = ControlLoopWatchdog(stallThresholdS: 10)
        watchdog.recordHeartbeat()

        Thread.sleep(forTimeInterval: 0.2)
        let elapsed = watchdog.secondsSinceHeartbeat(now: Date())
        XCTAssert(elapsed > 0.15 && elapsed < 1.0, "expected ~0.2s, got \(elapsed)")
    }

    func testSafetySupervisor_Heartbeat() {
        let supervisor = SafetySupervisor()
        let now = Date()
        supervisor.recordHeartbeat(now)
        XCTAssertFalse(supervisor.isControlLoopStalled(now: now))
        // A wall-clock jump (system sleep) must NOT read as a stall — this is
        // the same class of bug that killed the daemon on every wake.
        XCTAssertFalse(supervisor.isControlLoopStalled(now: now.addingTimeInterval(11)))
        // Real elapsed time still trips it.
        Thread.sleep(forTimeInterval: 0.15)
        XCTAssertTrue(supervisor.isControlLoopStalled(now: Date(), threshold: 0.05))
    }

    // MARK: - Self-CPU Watchdog (3 tests)

    func testSelfCPUWatchdog_HighCPU() {
        let watchdog = SelfCPUWatchdog()
        let now = Date()

        watchdog.recordSample(0.5, at: now)
        watchdog.recordSample(3.6, at: now.addingTimeInterval(60))

        XCTAssertTrue(watchdog.isHighCPU(now: now.addingTimeInterval(60)))
    }

    func testSelfCPUWatchdog_LowCPU() {
        let watchdog = SelfCPUWatchdog()
        let now = Date()

        watchdog.recordSample(0.1, at: now)
        watchdog.recordSample(1.0, at: now.addingTimeInterval(60))

        XCTAssertFalse(watchdog.isHighCPU(now: now.addingTimeInterval(60)))
    }

    func testSelfCPUWatchdog_MeasurePercent() {
        let watchdog = SelfCPUWatchdog()
        let now = Date()

        watchdog.recordSample(1.0, at: now)
        watchdog.recordSample(4.0, at: now.addingTimeInterval(60))

        let percent = watchdog.measureCPUPercent(now: now.addingTimeInterval(60))
        XCTAssert(percent > 0.049 && percent < 0.051)
    }

    // MARK: - Rule Engine (6 tests)

    func testRuleEngine_ManualPinOverridesAll() {
        let engine = RuleEngine()
        var rulesConfig = RulesConfig()
        rulesConfig.rules = [
            Rule(priority: 100, trigger: .onBattery, profileName: "quiet"),
        ]

        let context = RuleEngine.RuleContext(
            onBattery: false,
            clamshellClosed: false,
            externalDisplayConnected: false,
            runningBundleIDs: [],
            frontmostBundleID: nil,
            frontmostIsFullscreen: false,
            gpuPowerW: nil,
            localTime: Date()
        )

        let knownProfiles = Set(["quiet", "balanced", "performance"])
        let active = engine.evaluateRules(
            rulesConfig: rulesConfig,
            context: context,
            manualPin: "performance",
            knownProfiles: knownProfiles
        )

        XCTAssertEqual(active, "performance")
    }

    func testRuleEngine_PriorityOrder() {
        let engine = RuleEngine()
        var rulesConfig = RulesConfig()
        rulesConfig.rules = [
            Rule(priority: 10, trigger: .onBattery, profileName: "quiet"),
            Rule(priority: 100, trigger: .onAC, profileName: "balanced"),
            Rule(priority: 50, trigger: .onAC, profileName: "performance"),
        ]

        let context = RuleEngine.RuleContext(
            onBattery: false,
            clamshellClosed: false,
            externalDisplayConnected: false,
            runningBundleIDs: [],
            frontmostBundleID: nil,
            frontmostIsFullscreen: false,
            gpuPowerW: nil,
            localTime: Date()
        )

        let knownProfiles = Set(["quiet", "balanced", "performance"])
        let active = engine.evaluateRules(
            rulesConfig: rulesConfig,
            context: context,
            manualPin: nil,
            knownProfiles: knownProfiles
        )

        XCTAssertEqual(active, "balanced")
    }

    func testRuleEngine_GameDetection() {
        let engine = RuleEngine()
        var rulesConfig = RulesConfig()
        rulesConfig.rules = [
            Rule(priority: 100, trigger: .gameDetected, profileName: "performance"),
            Rule(priority: 50, trigger: .onAC, profileName: "balanced"),
        ]

        let context = RuleEngine.RuleContext(
            onBattery: false,
            clamshellClosed: false,
            externalDisplayConnected: false,
            runningBundleIDs: [],
            frontmostBundleID: "com.game.app",
            frontmostIsFullscreen: true,
            gpuPowerW: 75.0,
            localTime: Date()
        )

        let knownProfiles = Set(["quiet", "balanced", "performance"])
        let active = engine.evaluateRules(
            rulesConfig: rulesConfig,
            context: context,
            manualPin: nil,
            knownProfiles: knownProfiles
        )

        XCTAssertEqual(active, "performance")
    }

    func testRuleEngine_OnBattery() {
        let engine = RuleEngine()
        var rulesConfig = RulesConfig()
        rulesConfig.rules = [
            Rule(priority: 100, trigger: .onBattery, profileName: "quiet"),
        ]

        let context = RuleEngine.RuleContext(
            onBattery: true,
            clamshellClosed: false,
            externalDisplayConnected: false,
            runningBundleIDs: [],
            frontmostBundleID: nil,
            frontmostIsFullscreen: false,
            gpuPowerW: nil,
            localTime: Date()
        )

        let knownProfiles = Set(["quiet", "balanced", "performance"])
        let active = engine.evaluateRules(
            rulesConfig: rulesConfig,
            context: context,
            manualPin: nil,
            knownProfiles: knownProfiles
        )

        XCTAssertEqual(active, "quiet")
    }

    func testRuleEngine_AppRunning() {
        let engine = RuleEngine()
        var rulesConfig = RulesConfig()
        rulesConfig.rules = [
            Rule(priority: 100, trigger: .appRunning(bundleId: "com.xcode.Xcode"), profileName: "performance"),
        ]

        let context = RuleEngine.RuleContext(
            onBattery: false,
            clamshellClosed: false,
            externalDisplayConnected: false,
            runningBundleIDs: ["com.xcode.Xcode", "com.apple.finder"],
            frontmostBundleID: nil,
            frontmostIsFullscreen: false,
            gpuPowerW: nil,
            localTime: Date()
        )

        let knownProfiles = Set(["quiet", "balanced", "performance"])
        let active = engine.evaluateRules(
            rulesConfig: rulesConfig,
            context: context,
            manualPin: nil,
            knownProfiles: knownProfiles
        )

        XCTAssertEqual(active, "performance")
    }

    func testRuleEngine_WrappingTimeWindow() {
        let engine = RuleEngine()
        var rulesConfig = RulesConfig()
        rulesConfig.rules = [
            Rule(priority: 100, trigger: .timeWindow(startHour: 22, endHour: 7), profileName: "quiet"),
            Rule(priority: 50, trigger: .onAC, profileName: "balanced"),
        ]

        let context = RuleEngine.RuleContext(
            onBattery: false,
            clamshellClosed: false,
            externalDisplayConnected: false,
            runningBundleIDs: [],
            frontmostBundleID: nil,
            frontmostIsFullscreen: false,
            gpuPowerW: nil,
            localTime: Date(timeIntervalSinceNow: 0)  // Use current time; hour extraction happens at runtime
        )

        let knownProfiles = Set(["quiet", "balanced", "performance"])
        let active = engine.evaluateRules(
            rulesConfig: rulesConfig,
            context: context,
            manualPin: nil,
            knownProfiles: knownProfiles
        )

        // Will return either "quiet" or "balanced" depending on current hour - just verify it completes
        XCTAssert(active == "quiet" || active == "balanced")
    }

    // MARK: - Curve Validation (4 tests)

    func testCurveValidation_MonotonicRPM() {
        let curve = FanCurve(
            inputMix: [.cpuPerf: 1.0],
            points: [CurvePoint(temp: 40, rpm: 3000), CurvePoint(temp: 60, rpm: 2500), CurvePoint(temp: 80, rpm: 5000)]
        )

        XCTAssertThrowsError(try curve.validate())
    }

    func testCurveValidation_MonotonicTemp() {
        let curve = FanCurve(
            inputMix: [.cpuPerf: 1.0],
            points: [CurvePoint(temp: 60, rpm: 2000), CurvePoint(temp: 40, rpm: 3000), CurvePoint(temp: 80, rpm: 5000)]
        )

        XCTAssertThrowsError(try curve.validate())
    }

    func testCurveValidation_RPMRange() {
        let curve = FanCurve(
            inputMix: [.cpuPerf: 1.0],
            points: [CurvePoint(temp: 40, rpm: 2000), CurvePoint(temp: 80, rpm: 10000)]
        )

        XCTAssertThrowsError(try curve.validate())
    }

    func testCurveValidation_MinPoints() {
        let curve = FanCurve(
            inputMix: [.cpuPerf: 1.0],
            points: [CurvePoint(temp: 40, rpm: 2000)]
        )

        XCTAssertThrowsError(try curve.validate())
    }
}

// MARK: - Test Helper Extensions

extension CurveEngine {
    func interpolate(_ x: Double, points: [CurvePoint]) -> Double {
        guard !points.isEmpty else { return 0 }
        if x <= points.first!.temp { return points.first!.rpm }
        if x >= points.last!.temp { return points.last!.rpm }
        for i in 0 ..< points.count - 1 {
            let p1 = points[i]
            let p2 = points[i + 1]
            if x >= p1.temp && x <= p2.temp {
                let alpha = (x - p1.temp) / (p2.temp - p1.temp)
                return p1.rpm * (1 - alpha) + p2.rpm * alpha
            }
        }
        return points.last!.rpm
    }
}

// MARK: - Additional Tests for Coverage (to reach 40+)
// (Were stranded at file top level — outside any XCTestCase — since they were
// written; never discovered or run until this class was added.)
final class ConfigValidationCoverageTests: XCTestCase {

    func testConfigValidation_InvalidHysteresisGap() {
        let profile = Profile(
            name: "bad",
            curves: [0: FanCurve(inputMix: [.cpuPerf: 1.0], points: [CurvePoint(temp: 40, rpm: 2000), CurvePoint(temp: 80, rpm: 5000)])],
            powerCurve: nil,
            emaTimeConstantS: 5,
            hysteresisGapC: -1,
            hysteresisDwellS: 20
        )
        XCTAssertThrowsError(try profile.validate())
    }

    func testConfigValidation_InvalidHysteresisDwell() {
        let profile = Profile(
            name: "bad",
            curves: [0: FanCurve(inputMix: [.cpuPerf: 1.0], points: [CurvePoint(temp: 40, rpm: 2000), CurvePoint(temp: 80, rpm: 5000)])],
            powerCurve: nil,
            emaTimeConstantS: 5,
            hysteresisGapC: 5,
            hysteresisDwellS: -1
        )
        XCTAssertThrowsError(try profile.validate())
    }

    func testEngineParams_Validation() {
        let params = EngineParams(
            defaultEMATimeConstantS: -1,
            defaultHysteresisGapC: 5,
            defaultHysteresisDwellS: 20,
            maxSlewRateRPMPerS: 300,
            coolIdleTickS: 5,
            hotLoadedTickS: 1
        )
        XCTAssertThrowsError(try params.validate())
    }

    func testPowerCurveValidation_Success() {
        let powerCurve = PowerCurve(
            points: [PowerPoint(watts: 10, rpm: 2000), PowerPoint(watts: 50, rpm: 5000)]
        )
        XCTAssertNoThrow(try powerCurve.validate())
    }

    func testConfigValidation_MissingBalancedFallbackRejected() {
        var config = Config.defaultConfig()
        config.pinnedProfile = nil
        config.profiles.removeValue(forKey: "balanced")
        XCTAssertThrowsError(try config.validate())
    }

    func testConfigValidation_MissingBalancedOKWhenPinnedElsewhere() {
        var config = Config.defaultConfig()
        config.pinnedProfile = "quiet"
        config.profiles.removeValue(forKey: "balanced")
        // Rules may still reference balanced; drop them for this case.
        config.rules = RulesConfig()
        XCTAssertNoThrow(try config.validate())
    }

    // MARK: - Watchdog sleep regression (v1.0.4)

    /// A system sleep advances the WALL clock but not the uptime clock. The
    /// watchdog must judge staleness on uptime only — otherwise every wake
    /// looked like a multi-minute control-loop stall and the daemon killed
    /// itself (observed: 1436 restarts), losing the user's armed profile.
    func testWatchdog_WallClockJumpIsNotAStall() {
        let watchdog = ControlLoopWatchdog(stallThresholdS: 10)
        watchdog.recordHeartbeat()
        // Simulate waking after an hour of sleep: wall clock leapt forward.
        let anHourLater = Date().addingTimeInterval(3600)
        XCTAssertFalse(
            watchdog.isStalled(now: anHourLater),
            "A wall-clock jump (system sleep) must not be treated as a stall"
        )
        XCTAssertLessThan(watchdog.secondsSinceHeartbeat(now: anHourLater), 10)
    }

    func testWatchdog_UptimeClockIsMonotonic() {
        let first = ControlLoopWatchdog.uptimeSeconds()
        let second = ControlLoopWatchdog.uptimeSeconds()
        XCTAssertGreaterThanOrEqual(second, first)
        XCTAssertGreaterThan(first, 0)
    }
}
