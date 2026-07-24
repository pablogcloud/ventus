import Foundation

/// Pure logic for computing fan RPM targets from sensor readings.
/// Fully deterministic; injected inputs, clock, and state for testability.
/// NOT thread-safe: holds mutable EMA/hysteresis/slew state. The owner must
/// confine all compute() calls to one actor or serial queue.
public final class CurveEngine {
    /// Explanation of which input term won for a fan target.
    public struct Explanation: Equatable, Sendable {
        public let fan: Int
        public let targetRPM: Double
        public let tempCurveRPM: Double
        public let powerCurveRPM: Double
        public let pressureFloorRPM: Double
        public let safetyOverrideRPM: Double
        /// Post-slew, pre-floor value (differs from targetRPM when a floor/override raised it).
        public let slewLimitedRPM: Double
        /// Which term dominated the final decision (computed at decision time).
        public let winner: String
    }

    private let logger: (String) -> Void

    /// EMA state for each sensor group: (smoothedValue, lastUpdateTime)
    private var emaState: [SensorGroup: (value: Double, time: Date)] = [:]

    /// Hysteresis state per fan: (lastHighTemp, belowThresholdSince)
    private var hysteresisState: [Int: (highTemp: Double, belowSince: Date?)] = [:]

    /// Last actual RPM per fan for slew limiting.
    private var lastActualRPM: [Int: Double] = [:]

    /// Last compute time for calculating deltaTime.
    private var lastComputeTime: Date?

    /// Adaptive tick rate decision.
    public var suggestedTickS: Double = 1.0

    public init(logger: @escaping (String) -> Void = { _ in }) {
        self.logger = logger
    }

    /// Computes per-fan RPM targets given current sensor readings and profile.
    /// Returns array of (fan index, targetRPM, explanation) tuples.
    public func compute(
        sensors: [SensorGroup: GroupReading],
        profile: Profile,
        actualRPMs: [Int: Double],
        now: Date,
        thermalState: ThermalState = .nominal,
        safetyOverride: Double = 0,
        packageWatts: Double? = nil
    ) -> [Explanation] {
        // Compute actual time delta since last compute call
        let deltaTime: Double
        if let lastTime = lastComputeTime {
            deltaTime = max(0.01, now.timeIntervalSince(lastTime))
        } else {
            deltaTime = 1.0  // First call, assume 1 second
        }
        lastComputeTime = now

        // Step 1: Update EMA for each sensor group (only groups actually present)
        let smoothedSensors = updateEMA(sensors: sensors, now: now, tau: profile.emaTimeConstantS)

        // Step 2: For each fan, compute temperature curve output
        var results: [Explanation] = []
        for (fanIndex, curve) in profile.curves.sorted(by: { $0.key < $1.key }) {
            let actual = actualRPMs[fanIndex] ?? 0
            let maxRPM = curve.points.last?.rpm ?? 6000

            // Blend inputs
            let blendedTemp = blendInputs(curve.inputMix, smoothedSensors: smoothedSensors)

            // Interpolate on curve
            let tempCurveRPM = interpolateCurve(blendedTemp, points: curve.points)

            // Power curve: leading indicator, active only when a watts sample is available
            let powerCurveRPM: Double
            if let pc = profile.powerCurve, let watts = packageWatts {
                powerCurveRPM = interpolatePowerCurve(watts, points: pc.points)
            } else {
                powerCurveRPM = 0
            }

            // Pressure floor based on thermal state
            let pressureFloor = computePressureFloor(thermalState: thermalState, maxRPM: maxRPM)

            // Hysteresis ramp-down (asymmetric) — temperature term ONLY, so a
            // power-led ramp-up is never masked by a temperature ramp-down dwell
            let hystereticTempRPM = applyHysteresis(
                fan: fanIndex,
                targetRPM: tempCurveRPM,
                blendedTemp: blendedTemp,
                gap: profile.hysteresisGapC,
                dwell: profile.hysteresisDwellS,
                now: now
            )
            let curveTargetRPM = max(hystereticTempRPM, powerCurveRPM)

            // Slew rate limiting (applied before pressure floor/safety)
            let slewLimited = applySlewRateLimit(
                fan: fanIndex,
                targetRPM: curveTargetRPM,
                lastActual: actual,
                maxSlewRPMPerS: 300.0,
                deltaTime: deltaTime
            )

            // Safety override (hard ceiling)
            let safetyRPM: Double = safetyOverride > 0 ? safetyOverride : 0

            // Pressure floor and safety override are hard minimums that bypass slew limiting
            let finalRPM = max(slewLimited, pressureFloor, safetyRPM)

            // Cache actual for next iteration
            lastActualRPM[fanIndex] = finalRPM

            let winner: String
            if safetyRPM > 0 && finalRPM == safetyRPM && safetyRPM > slewLimited {
                winner = "safety_override"
            } else if pressureFloor > 0 && finalRPM == pressureFloor && pressureFloor > slewLimited {
                winner = "pressure_floor"
            } else if slewLimited != curveTargetRPM {
                winner = "slew_limited"
            } else if powerCurveRPM > 0 && powerCurveRPM >= hystereticTempRPM {
                winner = "power_curve"
            } else {
                winner = "temp_curve"
            }

            results.append(Explanation(
                fan: fanIndex,
                targetRPM: finalRPM,
                tempCurveRPM: tempCurveRPM,
                powerCurveRPM: powerCurveRPM,
                pressureFloorRPM: pressureFloor,
                safetyOverrideRPM: safetyRPM,
                slewLimitedRPM: slewLimited,
                winner: winner
            ))
        }

        // Step 3: Adapt tick rate based on state
        let maxTargetRPM = results.map { $0.targetRPM }.max() ?? 0
        let maxTemp = sensors.values.map { $0.max }.max() ?? 0
        suggestedTickS = (maxTargetRPM > 4000 || maxTemp > 70) ? 1.0 : 5.0

        return results
    }

    // MARK: - Private Helpers

    /// Updates EMA for each sensor group.
    /// FIX #7: Only update and return entries for groups actually present in input.
    /// Do NOT fabricate 0-value entries for absent groups.
    private func updateEMA(sensors: [SensorGroup: GroupReading], now: Date, tau: Double) -> [SensorGroup: Double] {
        var result: [SensorGroup: Double] = [:]

        // Only process groups that are present in the current snapshot
        for group in sensors.keys {
            let newReading = sensors[group]?.mean ?? 0

            if let (oldValue, lastTime) = emaState[group] {
                let deltaS = now.timeIntervalSince(lastTime)
                let alpha = 1.0 - exp(-deltaS / max(0.1, tau))
                let smoothed = oldValue * (1 - alpha) + newReading * alpha
                result[group] = smoothed
                emaState[group] = (smoothed, now)
            } else {
                result[group] = newReading
                emaState[group] = (newReading, now)
            }
        }

        return result
    }

    /// Blends multiple sensor group readings using the input mix weights.
    /// Returns 0 if mix is empty or no sensors matched; does NOT fabricate missing groups.
    private func blendInputs(_ mix: [SensorGroup: Double], smoothedSensors: [SensorGroup: Double]) -> Double {
        let mixSum = mix.values.reduce(0, +)
        guard mixSum > 0 else { return 0 }

        // Only blend groups that are actually present in smoothedSensors
        var weighted = 0.0
        var appliedWeight = 0.0
        for (group, weight) in mix {
            if let sensorValue = smoothedSensors[group] {
                weighted += sensorValue * weight
                appliedWeight += weight
            }
        }

        // If no requested groups are present, fail HOT: use the hottest
        // available sensor rather than 0, which would pin the curve at its
        // minimum RPM while the machine could be cooking.
        guard appliedWeight > 0 else {
            return smoothedSensors.values.max() ?? 0
        }

        return weighted / appliedWeight
    }

    /// Piecewise-linear interpolation on a temperature curve.
    private func interpolateCurve(_ x: Double, points: [CurvePoint]) -> Double {
        guard !points.isEmpty else { return 0 }

        // Clamp to range
        if x <= points.first!.temp {
            return points.first!.rpm
        }
        if x >= points.last!.temp {
            return points.last!.rpm
        }

        // Find bracketing pair
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

    /// Piecewise-linear interpolation on a power curve.
    private func interpolatePowerCurve(_ x: Double, points: [PowerPoint]) -> Double {
        guard !points.isEmpty else { return 0 }

        // Clamp to range
        if x <= points.first!.watts {
            return points.first!.rpm
        }
        if x >= points.last!.watts {
            return points.last!.rpm
        }

        // Find bracketing pair
        for i in 0 ..< points.count - 1 {
            let p1 = points[i]
            let p2 = points[i + 1]

            if x >= p1.watts && x <= p2.watts {
                let alpha = (x - p1.watts) / (p2.watts - p1.watts)
                return p1.rpm * (1 - alpha) + p2.rpm * alpha
            }
        }

        return points.last!.rpm
    }

    /// Applies hysteresis: ramp-up uses live value; ramp-down requires gap + dwell.
    private func applyHysteresis(
        fan: Int,
        targetRPM: Double,
        blendedTemp: Double,
        gap: Double,
        dwell: Double,
        now: Date
    ) -> Double {
        let state = hysteresisState[fan] ?? (blendedTemp, nil)
        var newState = state

        // Ramp-up: immediate
        if blendedTemp > state.highTemp {
            newState.highTemp = blendedTemp
            newState.belowSince = nil
            hysteresisState[fan] = newState
            return targetRPM
        }

        // Ramp-down: requires temp < (highTemp - gap) for at least dwell seconds
        let threshold = state.highTemp - gap
        if blendedTemp < threshold {
            if let belowSince = state.belowSince {
                let sustainedFor = now.timeIntervalSince(belowSince)
                if sustainedFor >= dwell {
                    newState.highTemp = blendedTemp
                    newState.belowSince = nil
                    hysteresisState[fan] = newState
                    return targetRPM
                }
            } else {
                newState.belowSince = now
                hysteresisState[fan] = newState
            }
            // Still waiting; return current (do not ramp down yet)
            return lastActualRPM[fan] ?? targetRPM
        } else {
            // Above threshold again; reset dwell timer
            newState.belowSince = nil
            hysteresisState[fan] = newState
            return targetRPM
        }
    }

    /// Computes thermal pressure floor.
    private func computePressureFloor(thermalState: ThermalState, maxRPM: Double) -> Double {
        switch thermalState {
        case .nominal, .fair:
            return 0
        case .serious:
            return maxRPM * 0.8
        case .critical:
            return maxRPM * 1.0
        }
    }

    /// Applies RPM slew-rate limiting.
    private func applySlewRateLimit(
        fan: Int,
        targetRPM: Double,
        lastActual: Double,
        maxSlewRPMPerS: Double,
        deltaTime: Double
    ) -> Double {
        let maxChange = maxSlewRPMPerS * deltaTime
        let delta = targetRPM - lastActual
        if abs(delta) <= maxChange {
            return targetRPM
        }
        return lastActual + (delta > 0 ? maxChange : -maxChange)
    }
}

/// Thermal state from ProcessInfo.
public enum ThermalState: Equatable {
    case nominal
    case fair
    case serious
    case critical
}
