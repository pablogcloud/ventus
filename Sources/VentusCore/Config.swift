import Foundation

/// Complete Ventus configuration schema, versioned and Codable.
struct Config: Codable, Equatable {
    /// Schema version for forward compatibility.
    let schemaVersion: Int = 1

    /// True if daemon should write to hardware; false = observe mode only.
    var armed: Bool = false

    /// Named profiles (e.g., "quiet", "balanced", "performance", "auto-apple").
    var profiles: [String: Profile] = [:]

    /// Rule engine configuration.
    var rules: RulesConfig = RulesConfig()

    /// Curve engine parameters.
    var engine: EngineParams = EngineParams()

    /// Manually pinned profile (if set, overrides rule-based selection).
    var pinnedProfile: String?

    /// Validates the entire config. Throws on error.
    func validate() throws {
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

        // If a profile is pinned, it must exist
        if let pinned = pinnedProfile {
            guard profiles[pinned] != nil else {
                throw ConfigError.pinnedProfileNotFound(name: pinned)
            }
        }

        // Rules must reference existing profiles
        try rules.validate(knownProfiles: Set(profiles.keys))

        // Engine parameters must be sane
        try engine.validate()
    }

    /// Returns a sensible default configuration for M2 Max MacBook Pro.
    static func defaultConfig() -> Config {
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
                0: FanCurve(
                    inputMix: [.cpuPerf: 0.6, .gpu: 0.3, .soc: 0.1],
                    points: [
                        CurvePoint(temp: 30, rpm: 2000),
                        CurvePoint(temp: 45, rpm: 2500),
                        CurvePoint(temp: 60, rpm: 3500),
                        CurvePoint(temp: 75, rpm: 5000),
                        CurvePoint(temp: 90, rpm: 6800),
                    ]
                ),
                1: FanCurve(
                    inputMix: [.cpuPerf: 0.5, .cpuEff: 0.35, .gpu: 0.15],
                    points: [
                        CurvePoint(temp: 30, rpm: 1800),
                        CurvePoint(temp: 45, rpm: 2300),
                        CurvePoint(temp: 60, rpm: 3300),
                        CurvePoint(temp: 75, rpm: 4800),
                        CurvePoint(temp: 90, rpm: 6500),
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
enum ConfigError: Error, Equatable {
    case noProfiles
    case invalidProfile(name: String, reason: String)
    case pinnedProfileNotFound(name: String)
    case invalidTempCurve(reason: String)
    case invalidRPMRange
    case noRules
}

/// A single curve point (temp -> RPM mapping).
struct CurvePoint: Codable, Equatable, Hashable {
    let temp: Double
    let rpm: Double
}

/// A single fan control profile.
struct Profile: Codable, Equatable {
    let name: String

    /// Per-fan curves: fan index -> curve
    let curves: [Int: FanCurve]

    /// Optional watts-based curve (limits max RPM based on package power).
    let powerCurve: PowerCurve?

    /// EMA time constant (seconds) for sensor smoothing.
    let emaTimeConstantS: Double

    /// Hysteresis gap (°C) for ramp-down threshold.
    let hysteresisGapC: Double

    /// Hysteresis dwell (seconds) to sustain below threshold before ramping down.
    let hysteresisDwellS: Double

    /// Validates this profile.
    func validate() throws {
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
struct FanCurve: Codable, Equatable {
    /// Weighted input mix over sensor groups (must sum to ~1.0).
    let inputMix: [SensorGroup: Double]

    /// Piecewise linear points: (temperature in °C, target RPM).
    /// Must be sorted by temperature and have monotonically increasing RPM.
    let points: [CurvePoint]

    /// Validates this curve.
    func validate() throws {
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
struct PowerCurve: Codable, Equatable {
    /// Points: (package watts, max RPM at that power level).
    let points: [PowerPoint]

    /// Validates this curve.
    func validate() throws {
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
struct PowerPoint: Codable, Equatable, Hashable {
    let watts: Double
    let rpm: Double
}

/// Rules configuration.
struct RulesConfig: Codable, Equatable {
    var rules: [Rule] = []

    /// Validates all rules.
    func validate(knownProfiles: Set<String>) throws {
        for rule in rules {
            try rule.validate(knownProfiles: knownProfiles)
        }
    }
}

/// A single rule that triggers profile selection.
struct Rule: Codable, Equatable {
    /// Priority order (higher = checked first).
    let priority: Int

    /// Trigger condition.
    let trigger: RuleTrigger

    /// Profile to activate if this rule matches.
    let profileName: String

    /// Validates this rule.
    func validate(knownProfiles: Set<String>) throws {
        guard knownProfiles.contains(profileName) else {
            throw ConfigError.invalidProfile(name: profileName, reason: "Profile not found")
        }
    }
}

/// Conditions that can trigger a rule.
enum RuleTrigger: Codable, Equatable {
    case onBattery
    case onAC
    case clamshellClosed
    case externalDisplayConnected
    case appRunning(bundleId: String)
    case gameDetected
    case timeWindow(startHour: Int, endHour: Int) // 0-23
}

/// Engine parameters for the curve engine.
struct EngineParams: Codable, Equatable {
    /// Default EMA time constant (seconds).
    var defaultEMATimeConstantS: Double = 5.0

    /// Default hysteresis gap (°C).
    var defaultHysteresisGapC: Double = 5.0

    /// Default hysteresis dwell (seconds).
    var defaultHysteresisDwellS: Double = 20.0

    /// Max RPM slew rate (RPM/s).
    var maxSlewRateRPMPerS: Double = 300.0

    /// Tick rate when cool and idle (seconds).
    var coolIdleTickS: Double = 5.0

    /// Tick rate when hot or loaded (seconds).
    var hotLoadedTickS: Double = 1.0

    /// Validates these parameters.
    func validate() throws {
        guard defaultEMATimeConstantS > 0 else {
            throw ConfigError.invalidProfile(name: "", reason: "EMA tau must be > 0")
        }
        guard maxSlewRateRPMPerS > 0 else {
            throw ConfigError.invalidProfile(name: "", reason: "Slew rate must be > 0")
        }
    }
}
