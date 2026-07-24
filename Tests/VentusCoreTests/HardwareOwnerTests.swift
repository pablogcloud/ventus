import XCTest
@testable import VentusCore

/// Fake fan hardware with injectable failure/hang behavior for owner tests.
final class FakeFanHardware: FanHardware, @unchecked Sendable {
    var count: Int
    var mode: [Int: UInt8]           // fan -> current mode (0 auto / 1 forced)
    var maxRPM: [Int: Double]
    var unreadableModes: Set<Int> = []   // readMode returns nil for these
    var forceFails: Set<Int> = []        // force() returns false for these
    var toAutoFails: Set<Int> = []       // toAuto() "succeeds" but leaves mode forced
    var hangSeconds: Double = 0          // sleep injected into force() to simulate a wedge
    var fanCountReadings: [Int] = []     // scripted FNum reads before falling back to count
    private(set) var forceCalls: [Int] = []

    private let lock = NSLock()

    init(count: Int, maxRPM: Double = 6800) {
        self.count = count
        self.mode = Dictionary(uniqueKeysWithValues: (0..<count).map { ($0, UInt8(1)) }) // start forced
        self.maxRPM = Dictionary(uniqueKeysWithValues: (0..<count).map { ($0, maxRPM) })
    }

    func fanCount() -> Int {
        lock.withLock {
            guard !fanCountReadings.isEmpty else { return count }
            return fanCountReadings.removeFirst()
        }
    }
    func fanMax(_ fan: Int) -> Double? { lock.withLock { maxRPM[fan] } }

    func readMode(_ fan: Int) -> UInt8? {
        lock.withLock { unreadableModes.contains(fan) ? nil : mode[fan] }
    }

    func force(_ fan: Int, rpm: Double) -> Bool {
        if hangSeconds > 0 { Thread.sleep(forTimeInterval: hangSeconds) }
        return lock.withLock {
            forceCalls.append(fan)
            if forceFails.contains(fan) { return false }
            mode[fan] = 1
            return true
        }
    }

    func toAuto(_ fan: Int) -> Bool {
        lock.withLock {
            if toAutoFails.contains(fan) { return true }  // reports success but doesn't restore
            mode[fan] = 0
            return true
        }
    }
}

final class HardwareOwnerTests: XCTestCase {
    func testRestoreVerified_AllFansAuto() {
        let hw = FakeFanHardware(count: 2)
        let owner = HardwareOwner(hardware: hw)
        XCTAssertEqual(owner.submit(.restore, deadline: 1), .ok)
        XCTAssertEqual(hw.mode[0], 0)
        XCTAssertEqual(hw.mode[1], 0)
    }

    func testRestore_FailsWhenAFanCannotBeVerified() {
        // Finding #2: a toAuto that "succeeds" but leaves the fan forced must be
        // reported as failure, never silent success.
        let hw = FakeFanHardware(count: 2)
        hw.toAutoFails = [1]
        let owner = HardwareOwner(hardware: hw)
        guard case .failed = owner.submit(.restore, deadline: 1) else {
            return XCTFail("expected failure when fan 1 stays forced")
        }
    }

    func testRestore_ExpectedFanNowUnreadableIsFailureNotSkip() {
        // Finding #1: a forced fan that becomes unreadable at restore time must
        // fail the restore, not be skipped into a false success.
        let hw = FakeFanHardware(count: 2)
        hw.unreadableModes = [1]
        let owner = HardwareOwner(hardware: hw)
        guard case .failed = owner.submit(.restore, deadline: 1) else {
            return XCTFail("expected failure when an expected fan is unreadable")
        }
    }

    func testRestore_InitialFanCountZeroThenLiveFansAppear_FailsIfAnyStaysForced() {
        let hw = FakeFanHardware(count: 2)
        hw.fanCountReadings = [0, 2]
        hw.toAutoFails = [1]
        let owner = HardwareOwner(hardware: hw)

        guard case .failed = owner.submit(.restore, deadline: 1) else {
            return XCTFail("expected failure when a live fan stays forced")
        }
        XCTAssertTrue(hw.fanCountReadings.isEmpty, "restore must refresh a transiently-zero FNum")
        XCTAssertEqual(hw.mode[0], 0)
        XCTAssertEqual(hw.mode[1], 1)
    }

    func testForceMaxAll_InitialFanCountZeroThenLiveFansAppear_ForcesBoth() {
        let hw = FakeFanHardware(count: 2)
        hw.mode = [0: 0, 1: 0]
        hw.fanCountReadings = [0, 2]
        let owner = HardwareOwner(hardware: hw)

        XCTAssertEqual(owner.submit(.forceMaxAll, deadline: 1), .ok)
        XCTAssertTrue(hw.fanCountReadings.isEmpty, "forceMaxAll must refresh a transiently-zero FNum")
        XCTAssertEqual(hw.forceCalls, [0, 1])
        XCTAssertEqual(hw.mode[0], 1)
        XCTAssertEqual(hw.mode[1], 1)
    }

    func testRestore_UnknownFanCountAndNoReadableFansCannotCertify() {
        let hw = FakeFanHardware(count: 0)
        let owner = HardwareOwner(hardware: hw)

        XCTAssertEqual(
            owner.submit(.restore, deadline: 1),
            .failed("fan count unknown; cannot certify")
        )
    }

    func testEmergencyRestore_LatchesAndRefusesFurtherControl() {
        let hw = FakeFanHardware(count: 2)
        let owner = HardwareOwner(hardware: hw)
        XCTAssertEqual(owner.submit(.emergencyRestore, deadline: 1), .ok)
        XCTAssertTrue(owner.isLatched)
        // Any subsequent normal control is refused — no re-forcing after rescue.
        XCTAssertEqual(owner.submit(.apply([.init(fan: 0, rpm: 3000)]), deadline: 1), .refusedLatched)
        XCTAssertEqual(owner.submit(.forceMaxAll, deadline: 1), .refusedLatched)
        XCTAssertEqual(hw.mode[0], 0)  // stayed auto
    }

    func testApply_PartialFailureReported() {
        // Finding #3: apply must report real failure, not a blind ok.
        let hw = FakeFanHardware(count: 2)
        hw.forceFails = [1]
        let owner = HardwareOwner(hardware: hw)
        guard case .failed = owner.submit(.apply([.init(fan: 0, rpm: 3000), .init(fan: 1, rpm: 3000)]), deadline: 1) else {
            return XCTFail("expected failure when fan 1 force fails")
        }
        XCTAssertEqual(hw.mode[0], 1)  // fan 0 still forced successfully
    }

    func testApply_SuccessForcesAllFans() {
        let hw = FakeFanHardware(count: 2)
        let owner = HardwareOwner(hardware: hw)
        XCTAssertEqual(owner.submit(.apply([.init(fan: 0, rpm: 2500), .init(fan: 1, rpm: 3000)]), deadline: 1), .ok)
        XCTAssertEqual(hw.mode[0], 1)
        XCTAssertEqual(hw.mode[1], 1)
    }

    func testForceMaxAll_UsesPerFanHardwareMax() {
        let hw = FakeFanHardware(count: 2)
        hw.maxRPM = [0: 6000, 1: 6800]
        let owner = HardwareOwner(hardware: hw)
        XCTAssertEqual(owner.submit(.forceMaxAll, deadline: 1), .ok)
        XCTAssertEqual(hw.mode[0], 1)
        XCTAssertEqual(hw.mode[1], 1)
    }

    func testFanlessMac_ApplyAndForceMaxAreNoHardware_NeverWrite() {
        // MacBook Air: no fans. Control commands must return .noHardware and
        // physically force nothing — the app is monitor-only there.
        let hw = FakeFanHardware(count: 0)
        let owner = HardwareOwner(hardware: hw)
        XCTAssertFalse(owner.hasControllableFans)
        XCTAssertEqual(owner.submit(.apply([.init(fan: 0, rpm: 3000)]), deadline: 1), .noHardware)
        XCTAssertEqual(owner.submit(.forceMaxAll, deadline: 1), .noHardware)
        XCTAssertTrue(hw.forceCalls.isEmpty, "a fanless Mac must never receive a force write")
    }

    func testSubmit_TimesOutWhenHardwareWedged_WithoutTouchingHardware() {
        // Finding #1 core: a wedged write must return .timedOut to the caller so
        // it can exit — the caller must NOT be able to deadlock waiting.
        let hw = FakeFanHardware(count: 1)
        hw.hangSeconds = 2.0
        let owner = HardwareOwner(hardware: hw)
        let start = Date()
        let result = owner.submit(.apply([.init(fan: 0, rpm: 3000)]), deadline: 0.2)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(result, .timedOut)
        XCTAssertLessThan(elapsed, 1.0, "caller must return near the deadline, not wait for the hung write")
    }
}
