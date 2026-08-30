import Foundation
import IOKit
import IOKit.pwr_mgt
import os

/// Keeps the Mac awake while the lid is open.
///
/// A power assertion, which is the sanctioned way to do this: no privileges, and the kernel releases
/// it automatically if we die. Nothing here can outlive the app, which is exactly why the lid-closed
/// half needs an entirely different mechanism.
final class SleepAssertion {
    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "KeepAwake")
    private var systemAssertion: IOPMAssertionID?
    private var displayAssertion: IOPMAssertionID?

    var isHeld: Bool { systemAssertion != nil }

    /// - Parameter keepDisplayOn: also prevents the display sleeping, not just the system idling.
    func acquire(keepDisplayOn: Bool) {
        release()

        var assertion: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Sarvkrit - Keep Awake" as CFString,
            &assertion
        )
        guard result == kIOReturnSuccess else {
            log.error("could not create sleep assertion (\(result))")
            return
        }
        systemAssertion = assertion

        guard keepDisplayOn else { return }
        var display: IOPMAssertionID = 0
        if IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Sarvkrit - Keep Display On" as CFString,
            &display
        ) == kIOReturnSuccess {
            displayAssertion = display
        }
    }

    func release() {
        if let systemAssertion { IOPMAssertionRelease(systemAssertion) }
        if let displayAssertion { IOPMAssertionRelease(displayAssertion) }
        systemAssertion = nil
        displayAssertion = nil
    }

    deinit { release() }
}
