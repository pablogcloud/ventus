import Foundation

/// Complete Ventus configuration schema, versioned and Codable.
public struct Config: Codable, Equatable {
    /// Schema version for forward compatibility.
    public let schemaVersion: Int = 1

    /// True if daemon should write to hardware; false = observe mode only.
    public var armed: Bool = false

    /// Named profiles (e.g., "quiet", "balanced", "performance", "auto-apple").
    public var profiles: [String: Profile] = [:]

    /// Rule engine configuration.
    public var rules: RulesConfig = RulesConfig()

    /// Curve engine parameters.
    public var engine: EngineParams = EngineParams()

    /// Manually pinned profile (if set, overrides rule-based selection).
    public var pinnedProfile: String?

    /// Validates the entire config. Throws on error.
    public func validate() throws {
        // At least one profile
        guard !profiles.isEmpty else {
            throw ConfigError.noProfiles
        }

        // All profiles must be valid
        for (name, profile) in profiles {
            do {
                try profile.validate()
            } catch {
                throw ConfigError.invalidProfile(name: name, reason: "\(error)")
            }
        }

        // The profile the control loop will resolve must exist: the pinned one
        // when set, otherwise the "balanced" fallback (audit C4 — a valid
        // config without it would starve the loop before the thermal override
        // is ever evaluated).
        let resolved = pinnedProfile ?? "balanced"
        guard profiles[resolved] != nil else {
            throw ConfigError.pinnedProfileNotFound(name: resolved)
        }

        // Rules must reference existing profiles
        try rules.validate(knownProfiles: Set(profiles.keys))

        // Engine parameters must be sane
        try engine.validate()
    }

    /// Returns a sensible default configuration for M2 Max MacBook Pro.
    public static func defaultConfig() -> Config {
        var config = Config()

        // Quiet profile: lower fan speeds for silent operation
        config.profiles["quiet"] = Profile(
            name: "quiet",
            curves: [
                0: FanCurve(
                    inputMix: [.cpuPerf: 0.4, .gpu: 0.3, .soc: 0.3],
                    points: [
                        CurvePoint(temp: 40, rpm: 1600),
                        CurvePoint(temp: 60, rpm: 2200),
                        CurvePoint(temp: 75, rpm: 3500),
                        CurvePoint(temp: 85, rpm: 4500),
                        CurvePoint(temp: 95, rpm: 6000),
                    ]
                ),
                1: FanCurve(
                    inputMix: [.cpuPerf: 0.4, .cpuEff: 0.3, .gpu: 0.3],
                    points: [
                        CurvePoint(temp: 40, rpm: 1600),
                        CurvePoint(temp: 60, rpm: 2000),
                        CurvePoint(temp: 75, rpm: 3200),
                        CurvePoint(temp: 85, rpm: 4300),
                        CurvePoint(temp: 95, rpm: 5800),
                    ]
                ),
            ],
            powerCurve: nil,
            emaTimeConstantS: 8.0,
            hysteresisGapC: 5.0,
            hysteresisDwellS: 25.0
        )

        // Balanced profile: middle ground
        config.profiles["balanced"] = Profile(
            name: "balanced",
            curves: [
                0: FanCurve(
                    inputMix: [.cpuPerf: 0.5, .gpu: 0.3, .soc: 0.2],
                    points: [
                        CurvePoint(temp: 35, rpm: 1600),
                        CurvePoint(temp: 50, rpm: 2000),
                        CurvePoint(temp: 65, rpm: 3000),
                        CurvePoint(temp: 80, rpm: 4500),
                        CurvePoint(temp: 95, rpm: 6500),
                    ]
                ),
                1: FanCurve(
                    inputMix: [.cpuPerf: 0.4, .cpuEff: 0.3, .gpu: 0.3],
                    points: [
                        CurvePoint(temp: 35, rpm: 1600),
                        CurvePoint(temp: 50, rpm: 1900),
                        CurvePoint(temp: 65, rpm: 2800),
                        CurvePoint(temp: 80, rpm: 4200),
                        CurvePoint(temp: 95, rpm: 6300),
                    ]
                ),
            ],
            powerCurve: nil,
            emaTimeConstantS: 5.0,
            hysteresisGapC: 4.0,
            hysteresisDwellS: 15.0
        )

        // Performance profile: aggressive cooling
        config.profiles["performance"] = Profile(
            name: "performance",
            curves: [
                // "Earlier, stronger cooling" has to be felt: at a typical
                // working ~50°C this curve already holds ~3700 RPM, where
                // Balanced sits near 2000 — the audible gap is the product.
                0: FanCurve(
                    inputMix: [.cpuPerf: 0.6, .gpu: 0.3, .soc: 0.1],
                    points: [
                        CurvePoint(temp: 30, rpm: 2400),
                        CurvePoint(temp: 45, rpm: 3400),
                        CurvePoint(temp: 55, rpm: 4400),
                        CurvePoint(temp: 65, rpm: 5500),
                        CurvePoint(temp: 80, rpm: 6800),
                    ]
                ),
                1: FanCurve(
                    inputMix: [.cpuPerf: 0.5, .cpuEff: 0.35, .gpu: 0.15],
                    points: [
                        CurvePoint(temp: 30, rpm: 2200),
                        CurvePoint(temp: 45, rpm: 3200),
                        CurvePoint(temp: 55, rpm: 4200),
                        CurvePoint(temp: 65, rpm: 5200),
                        CurvePoint(temp: 80, rpm: 6500),
                    ]
                ),
            ],
            powerCurve: nil,
            emaTimeConstantS: 2.0,
            hysteresisGapC: 2.0,
            hysteresisDwellS: 5.0
        )

        // Auto-Apple: no override (fans run at Apple's default)
        config.profiles["auto-apple"] = Profile(
            name: "auto-apple",
            curves: [:],
            powerCurve: nil,
            emaTimeConstantS: 5.0,
            hysteresisGapC: 0,
            hysteresisDwellS: 0
        )

        // Default rules: use balanced on AC, quiet on battery
        config.rules.rules = [
            Rule(priority: 100, trigger: .onBattery, profileName: "quiet"),
            Rule(priority: 50, trigger: .onAC, profileName: "balanced"),
        ]

        config.armed = false
        return config
    }
}

/// Error type for config validation.
public enum ConfigError: Error, Equatable {
    case noProfiles
    case invalidProfile(name: String, reason: String)
    case pinnedProfileNotFound(name: String)
    case invalidTempCurve(reason: String)
    case invalidRPMRange
    case noRules
}

/// A single curve point (temp -> RPM mapping).
public struct CurvePoint: Codable, Equatable, Hashable {
    public let temp: Double
    public let rpm: Double
}

/// A single fan control profile.
public struct Profile: Codable, Equatable {
    public let name: String

    /// Per-fan curves: fan index -> curve
    public let curves: [Int: FanCurve]

    /// Optional watts-based curve (limits max RPM based on package power).
    public let powerCurve: PowerCurve?

    /// EMA time constant (seconds) for sensor smoothing.
    public let emaTimeConstantS: Double

    /// Hysteresis gap (°C) for ramp-down threshold.
    public let hysteresisGapC: Double

    /// Hysteresis dwell (seconds) to sustain below threshold before ramping down.
    public let hysteresisDwellS: Double

    /// Highest RPM any fan is asked for at `tempC`. Lets two profiles be
    /// compared for aggressiveness, so a change that increases cooling can be
    /// applied at once while one that reduces it is rate-limited.
    public func peakRPM(atTemp tempC: Double) -> Double {
        curves.values.map { $0.rpm(atTemp: tempC) }.max() ?? 0
    }

    /// Validates this profile.
    public func validate() throws {
        // Validate profile's own EMA and hysteresis parameters
        guard emaTimeConstantS > 0 else {
            throw ConfigError.invalidProfile(name: name, reason: "EMA tau must be > 0")
        }
        guard hysteresisGapC >= 0 else {
            throw ConfigError.invalidProfile(name: name, reason: "Hysteresis gap must be ≥ 0")
        }
        guard hysteresisDwellS >= 0 else {
            throw ConfigError.invalidProfile(name: name, reason: "Hysteresis dwell must be ≥ 0")
        }

        // Curves must have monotonically increasing temps
        for (_, curve) in curves {
            try curve.validate()
        }
        if let pc = powerCurve {
            try pc.validate()
        }
    }
}

/// A single piecewise-linear temperature → RPM curve for one fan.
public struct FanCurve: Codable, Equatable {
    /// Weighted input mix over sensor groups (must sum to ~1.0).
    public let inputMix: [SensorGroup: Double]

    /// Piecewise linear points: (temperature in °C, target RPM).
    /// Must be sorted by temperature and have monotonically increasing RPM.
    public let points: [CurvePoint]

    /// Piecewise-linear value of this curve at `tempC`, clamped to the end
    /// points.
    public func rpm(atTemp tempC: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if tempC <= first.temp { return first.rpm }
        if tempC >= last.temp { return last.rpm }
        for i in 1 ..< points.count where tempC <= points[i].temp {
            let a = points[i - 1], b = points[i]
            let span = b.temp - a.temp
            guard span > 0 else { return b.rpm }
            return a.rpm + (b.rpm - a.rpm) * ((tempC - a.temp) / span)
        }
        return last.rpm
    }

    /// Validates this curve.
    public func validate() throws {
        // Must have at least 2 points
        guard points.count >= 2 else {
            throw ConfigError.invalidTempCurve(reason: "Curve must have ≥2 points")
        }

        // Temps and RPMs must be sorted and increasing
        var lastTemp = -Double.infinity
        var lastRPM = -Double.infinity
        for point in points {
            guard point.temp > lastTemp else {
                throw ConfigError.invalidTempCurve(reason: "Temps must be strictly increasing")
            }
            guard point.rpm >= lastRPM else {
                throw ConfigError.invalidTempCurve(reason: "RPMs must be monotonically increasing")
            }
            // RPM must be in plausible range [0, 8000]
            guard point.rpm >= 0 && point.rpm <= 8000 else {
                throw ConfigError.invalidRPMRange
            }
            lastTemp = point.temp
            lastRPM = point.rpm
        }

        // Input mix should sum to ~1.0 (allow ±10% tolerance)
        let sum = inputMix.values.reduce(0, +)
        if sum <= 0.9 || sum >= 1.1 {
            // Warn but don't fail; single group is ok
        }
    }
}

/// Optional power-based curve: watts → RPM limit.
public struct PowerCurve: Codable, Equatable {
    /// Points: (package watts, max RPM at that power level).
    public let points: [PowerPoint]

    /// Validates this curve.
    public func validate() throws {
        guard points.count >= 1 else {
            throw ConfigError.invalidTempCurve(reason: "Power curve must have ≥1 point")
        }
        var lastW = -Double.infinity
        var lastRPM = -Double.infinity
        for point in points {
            guard point.watts >= lastW else {
                throw ConfigError.invalidTempCurve(reason: "Power curve watts must be increasing")
            }
            guard point.rpm >= lastRPM else {
                throw ConfigError.invalidTempCurve(reason: "Power curve RPM must be increasing")
            }
            guard point.rpm >= 0 && point.rpm <= 8000 else {
                throw ConfigError.invalidRPMRange
            }
            lastW = point.watts
            lastRPM = point.rpm
        }
    }
}

/// A single power curve point.
public struct PowerPoint: Codable, Equatable, Hashable {
    public let watts: Double
    public let rpm: Double
}

/// Rules configuration.
public struct RulesConfig: Codable, Equatable {
    public var rules: [Rule] = []

    /// GPU watts above which `.gameDetected` considers the machine to be
    /// gaming. Nil means derive it from the detected chip
    /// (`ChipInfo.defaultGameGPUWatts`), which is the right default because the
    /// figure is meaningless without knowing the GPU's size. Optional with a
    /// default so existing config.json files still decode unchanged.
    public var gameGPUWattsThreshold: Double? = nil

    /// Validates all rules.
    public func validate(knownProfiles: Set<String>) throws {
        for rule in rules {
            try rule.validate(knownProfiles: knownProfiles)
        }
    }
}

/// A single rule that triggers profile selection.
public struct Rule: Codable, Equatable {
    /// Priority order (higher = checked first).
    public let priority: Int

    /// Trigger condition.
    public let trigger: RuleTrigger

    /// Profile to activate if this rule matches.
    public let profileName: String

    public init(priority: Int, trigger: RuleTrigger, profileName: String) {
        self.priority = priority
        self.trigger = trigger
        self.profileName = profileName
    }

    /// Validates this rule.
    public func validate(knownProfiles: Set<String>) throws {
        guard knownProfiles.contains(profileName) else {
            throw ConfigError.invalidProfile(name: profileName, reason: "Profile not found")
        }
    }
}

/// Conditions that can trigger a rule.
public enum RuleTrigger: Codable, Equatable {
    case onBattery
    case onAC
    case clamshellClosed
    case externalDisplayConnected
    case appRunning(bundleId: String)
    case gameDetected
    case timeWindow(startHour: Int, endHour: Int) // 0-23

    /// True when this trigger depends on facts only the GUI session can supply.
    /// The daemon declines to match these when the pushed session context is
    /// stale, so a dead app cannot leave a rule latched on.
    public var needsSessionContext: Bool {
        switch self {
        case .timeWindow:
            return false
        case .onBattery, .onAC, .clamshellClosed, .externalDisplayConnected,
             .appRunning, .gameDetected:
            return true
        }
    }

    /// One description shared by the daemon (for `activeRule` in telemetry) and
    /// the rule list, so the two can never drift apart.
    public var displayDescription: String {
        switch self {
        case .onBattery:                return "On battery power"
        case .onAC:                     return "On AC power"
        case .clamshellClosed:          return "Clamshell closed"
        case .externalDisplayConnected: return "External display connected"
        case .appRunning(let bundleID): return "\(bundleID) is running"
        case .gameDetected:             return "Game detected"
        case .timeWindow(let start, let end):
            return String(format: "Between %02d:00 and %02d:00", start, end)
        }
    }
}

/// Engine parameters for the curve engine.
public struct EngineParams: Codable, Equatable {
    /// Default EMA time constant (seconds).
    public var defaultEMATimeConstantS: Double = 5.0

    /// Default hysteresis gap (°C).
    public var defaultHysteresisGapC: Double = 5.0

    /// Default hysteresis dwell (seconds).
    public var defaultHysteresisDwellS: Double = 20.0

    /// Max RPM slew rate (RPM/s).
    public var maxSlewRateRPMPerS: Double = 300.0

    /// Tick rate when cool and idle (seconds).
    // 2s, matching the app's poll: telemetry publishes per control tick, and a
    // 5s idle tick made the heat map visibly stale between updates.
    public var coolIdleTickS: Double = 2.0

    /// Tick rate when hot or loaded (seconds).
    public var hotLoadedTickS: Double = 1.0

    /// Validates these parameters.
    public func validate() throws {
        guard defaultEMATimeConstantS > 0 else {
            throw ConfigError.invalidProfile(name: "", reason: "EMA tau must be > 0")
        }
        guard maxSlewRateRPMPerS > 0 else {
            throw ConfigError.invalidProfile(name: "", reason: "Slew rate must be > 0")
        }
    }
}
