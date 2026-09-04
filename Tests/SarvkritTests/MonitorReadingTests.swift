import XCTest
@testable import Sarvkrit

/// The pure logic behind the readings added for the menu bar panels.
///
/// Each of these exists because the sampler around it can't be tested — a memory pressure level
/// can't be provoked, a battery can't be made to age, a counter can't be made to wrap — so the
/// decision is separated out and the table is the test.
final class MonitorReadingTests: XCTestCase {

    // MARK: - Memory pressure

    func testTheKernelsPressureLevelsMapToTheThreeStates() {
        XCTAssertEqual(MemoryPressure.level(raw: 1), .normal)
        XCTAssertEqual(MemoryPressure.level(raw: 2), .warning)
        XCTAssertEqual(MemoryPressure.level(raw: 4), .critical)
    }

    func testAnUnknownPressureLevelIsNotGuessedAt() {
        // The values are a bit field, not a sequence, so 3 and 8 are not "between" anything. A
        // future level rounded down to `.normal` would report a healthy Mac in a state the kernel
        // invented to mean something worse.
        for raw: Int32 in [0, 3, 5, 8, -1, 99] {
            XCTAssertNil(MemoryPressure.level(raw: raw), "level \(raw)")
        }
    }

    func testTheRealMacReportsAPressureLevelWeUnderstand() {
        // A smoke test against the live sysctl: if Apple ever changes the encoding, every panel
        // silently loses its pill and nothing else would notice.
        guard let pressure = MemoryPressure.read() else {
            return XCTFail("kern.memorystatus_vm_pressure_level reported a level we don't know")
        }
        XCTAssertFalse(pressure.title.isEmpty)
    }

    // MARK: - Uptime

    func testUptimeUsesTwoUnitsAtMost() {
        XCTAssertEqual(UptimeFormatting.string(uptime: 2 * 86_400 + 15 * 3_600 + 41 * 60), "2d 15h")
        XCTAssertEqual(UptimeFormatting.string(uptime: 15 * 3_600 + 4 * 60), "15h 4m")
        XCTAssertEqual(UptimeFormatting.string(uptime: 42 * 60), "42m")
    }

    func testUptimeBelowAMinuteDoesNotCountSeconds() {
        XCTAssertEqual(UptimeFormatting.string(uptime: 8), "just now")
        XCTAssertEqual(UptimeFormatting.string(uptime: 0), "just now")
        // Negative is not a real uptime, but clamping beats rendering "-1d -3h".
        XCTAssertEqual(UptimeFormatting.string(uptime: -500), "just now")
    }

    func testUptimeKeepsTheZeroUnit() {
        // "2d 0h" rather than "2d": dropping the zero makes the string change width as it crosses
        // midnight, and the row it sits in is fixed.
        XCTAssertEqual(UptimeFormatting.string(uptime: 2 * 86_400), "2d 0h")
        XCTAssertEqual(UptimeFormatting.string(uptime: 3 * 3_600), "3h 0m")
    }

    // MARK: - Battery health

    /// Read off this Mac with `ioreg -rc AppleSmartBattery`, not invented: which key holds the
    /// usable capacity varies by macOS version, so a fixture made up to fit the code would prove
    /// only that the code agrees with itself.
    func testBatteryHealthMatchesWhatSystemSettingsWouldSay() {
        let health = BatteryMath.healthPercent(nominalCapacity: 5_319, designCapacity: 6_075)
        XCTAssertEqual(try XCTUnwrap(health), 87.55, accuracy: 0.01)
    }

    func testBatteryHealthIsNotClampedAtFullCapacity() {
        // A new battery genuinely reports slightly above its design capacity. 102% is the truth,
        // and capping it would hide a real reading to make the number tidier.
        let health = BatteryMath.healthPercent(nominalCapacity: 6_200, designCapacity: 6_075)
        XCTAssertGreaterThan(try XCTUnwrap(health), 100)
    }

    func testBatteryHealthIsUnknownRatherThanZero() {
        // A desktop has no capacity keys at all. Zero percent would claim a dead battery.
        XCTAssertNil(BatteryMath.healthPercent(nominalCapacity: nil, designCapacity: 6_075))
        XCTAssertNil(BatteryMath.healthPercent(nominalCapacity: 5_319, designCapacity: nil))
        XCTAssertNil(BatteryMath.healthPercent(nominalCapacity: 5_319, designCapacity: 0))
    }

    func testBatteryTemperatureIsHundredthsOfADegree() {
        // 3043 is this Mac's reading; the sensor path independently reports 30 °C for the same
        // battery, which is what makes the scale factor more than a guess.
        XCTAssertEqual(try XCTUnwrap(BatteryMath.celsius(rawTemperature: 3_043)), 30.43,
                       accuracy: 0.001)
    }

    func testAnAbsentBatteryTemperatureIsNotAbsoluteZero() {
        XCTAssertNil(BatteryMath.celsius(rawTemperature: nil))
        XCTAssertNil(BatteryMath.celsius(rawTemperature: 0))
    }

    // MARK: - Session totals

    func testTotalsAccumulateDeltasNotCounters() {
        // The first reading establishes a baseline and contributes nothing. Adding it outright
        // would credit the session with the interface's entire history since boot.
        var totals = SessionTotals()
        totals.add(counter: 1_000_000)
        XCTAssertEqual(totals.total, 0)

        totals.add(counter: 1_000_500)
        XCTAssertEqual(totals.total, 500)

        totals.add(counter: 1_002_000)
        XCTAssertEqual(totals.total, 2_000)
    }

    func testACounterGoingBackwardsRebaselinesRatherThanResetting() {
        // A reset or wrap. `MetricRate` discards the sample because there is no honest per-second
        // number; a total cannot discard without losing everything counted so far.
        var totals = SessionTotals()
        totals.add(counter: 5_000)
        totals.add(counter: 6_000)
        XCTAssertEqual(totals.total, 1_000)

        totals.add(counter: 10)      // interface reconfigured
        XCTAssertEqual(totals.total, 1_000, "what was counted must survive a counter reset")

        totals.add(counter: 260)
        XCTAssertEqual(totals.total, 1_250, "counting resumes from the new baseline")
    }

    func testAStationaryCounterAddsNothing() {
        var totals = SessionTotals()
        totals.add(counter: 42)
        totals.add(counter: 42)
        totals.add(counter: 42)
        XCTAssertEqual(totals.total, 0)
    }

    func testResettingClearsTheBaselineToo() {
        // Otherwise the first reading after a reset is diffed against the old session's counter and
        // the new session opens with a large phantom total.
        var totals = SessionTotals()
        totals.add(counter: 1_000)
        totals.add(counter: 2_000)
        totals.reset()
        XCTAssertEqual(totals.total, 0)

        totals.add(counter: 9_000)
        XCTAssertEqual(totals.total, 0)
        totals.add(counter: 9_100)
        XCTAssertEqual(totals.total, 100)
    }

    // MARK: - Thermal sensor names

    func testCoreClusterSensorsAreCPU() {
        for name in ["PMU TP0s", "PMU TP1g", "PMU TP3g", "pACC MTR Temp Sensor1",
                     "eACC MTR Temp Sensor3"] {
            XCTAssertEqual(ThermalSensor.classify(name), .cpu, name)
        }
    }

    func testGPUSensorsAreRecognisedOnBothSpellings() {
        XCTAssertEqual(ThermalSensor.classify("PMU TG0V"), .gpu)
        XCTAssertEqual(ThermalSensor.classify("GPU MTR Temp Sensor1"), .gpu)
    }

    func testDieSensorsAreTheSoCNotTheCPU() {
        XCTAssertEqual(ThermalSensor.classify("PMU tdie0"), .soc)
        XCTAssertEqual(ThermalSensor.classify("PMU tdie10"), .soc)
    }

    func testTheCalibrationSensorIsExcluded() {
        // `PMU tcal` reads about 52 °C on a completely idle Mac. Grouped with the die sensors it
        // would become the reported temperature, because these are combined by taking the maximum.
        XCTAssertNil(ThermalSensor.classify("PMU tcal"))
    }

    func testSensorsWeDoNotReportAreIgnored() {
        for name in ["PMU tdev4", "NAND CH0 temp", "", "something else entirely"] {
            XCTAssertNil(ThermalSensor.classify(name), name)
        }
    }

    func testTheHottestClusterIsReportedNotTheAverage() {
        // The question anyone asks a CPU temperature is how close it is to throttling, which is a
        // property of the hottest cluster. An average buries exactly that.
        let reduced = ThermalSensor.reduce([(.cpu, 40), (.cpu, 62), (.cpu, 41)])
        XCTAssertEqual(reduced.cpu, 62)
    }

    func testTheDieIsUsedOnlyWhenNoClusterSensorAnswered() {
        XCTAssertEqual(ThermalSensor.reduce([(.soc, 55)]).cpu, 55)
        XCTAssertEqual(ThermalSensor.reduce([(.soc, 55), (.cpu, 48)]).cpu, 48)
    }

    func testAMissingGPUSensorIsNilRatherThanBorrowedFromTheCPU() {
        // This Mac has no GPU sensor at all, so the panel shows a dash. Falling back to the CPU or
        // the die would put a confident number under a label it doesn't belong to.
        XCTAssertNil(ThermalSensor.reduce([(.cpu, 48), (.soc, 55)]).gpu)
    }

    func testImplausibleTemperaturesAreRejected() {
        // A sensor unread since boot reports 0; a disconnected one reports hundreds. Both format
        // perfectly well and would be believed.
        XCTAssertFalse(ThermalSensor.isPlausible(celsius: 0))
        XCTAssertFalse(ThermalSensor.isPlausible(celsius: -40))
        XCTAssertFalse(ThermalSensor.isPlausible(celsius: 3_000))
        XCTAssertTrue(ThermalSensor.isPlausible(celsius: 38))
    }

    // MARK: - SMART

    func testAnyCriticalWarningBitIsAFailure() {
        // The byte is a bit field: spare below threshold, temperature past its limit, media errors,
        // read-only fallback, failed backup. Testing for one value rather than for zero is how an
        // overheating drive gets reported as fine.
        XCTAssertEqual(SMARTStatus.from(criticalWarning: 0), .ok)
        for bit in 0..<8 {
            XCTAssertEqual(SMARTStatus.from(criticalWarning: UInt8(1 << bit)), .failing,
                           "bit \(bit)")
        }
    }

    // MARK: - Volumes

    func testTheVolumeListerFindsTheBootVolumeAndNoMachinery() {
        // A Mac has a dozen or more mounts and most are machinery — Preboot, VM, Update, the
        // read-only system snapshot. Listing them would bury the ones a person recognises.
        let volumes = VolumeLister.list()
        XCTAssertFalse(volumes.isEmpty, "at least the boot volume must be listed")
        XCTAssertTrue(volumes.contains { $0.isInternal }, "the boot volume is internal")

        for volume in volumes {
            XCTAssertGreaterThan(volume.total, 0, volume.name)
            XCTAssertLessThanOrEqual(volume.used, volume.total, volume.name)
            XCTAssertFalse(volume.url.path.hasPrefix("/System/Volumes/VM"), volume.name)
            XCTAssertFalse(volume.url.path.hasPrefix("/System/Volumes/Preboot"), volume.name)
        }
    }
}
