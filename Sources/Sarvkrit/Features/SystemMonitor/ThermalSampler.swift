import Foundation
import IOKit
import os

/// CPU and GPU temperatures, from the HID sensor system.
///
/// **This is the one place Sarvkrit uses a private API**, and the README says so rather than
/// leaving it to be discovered. It is worth being precise about what that does and does not mean:
/// `IOHIDEventSystemClient` is undocumented, but it is *unprivileged* — no root, no helper daemon,
/// no password prompt, no TCC permission, and nothing leaves the Mac. The alternative is not a
/// public API; it is not showing temperatures at all, because macOS exposes none. The battery's
/// temperature deliberately does not come through here: `AppleSmartBattery` publishes it openly,
/// so that one reading stays on the documented path.
///
/// Resolved through `dlopen`/`dlsym` rather than by declaring the symbols, so a macOS release that
/// removes any of them fails as a missing sensor — a dash on the panel — instead of failing to
/// launch the app.
///
/// **Call from `workQueue`, never the main thread.** It walks every sensor the Mac has, and the
/// main thread hosts the event tap.
final class ThermalSampler {
    struct Reading: Equatable {
        var cpu: Double?
        var gpu: Double?
    }

    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "Thermal")

    // MARK: - The private surface, resolved once

    private typealias ClientCreate = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatching = @convention(c) (AnyObject, CFDictionary) -> Void
    private typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias EventFloatValue = @convention(c) (AnyObject, Int32) -> Double
    private typealias CopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?

    private struct Symbols {
        let create: ClientCreate
        let setMatching: SetMatching
        let copyServices: CopyServices
        let copyEvent: CopyEvent
        let floatValue: EventFloatValue
        let copyProperty: CopyProperty
    }

    /// The HID usage page and usage that select temperature sensors. Not named constants anywhere
    /// public; these are the values every tool that reads Apple Silicon temperatures uses.
    private static let temperatureUsagePage = 0xff00
    private static let temperatureUsage = 5
    private static let eventTypeTemperature: Int64 = 15

    private static let symbols: Symbols? = {
        guard let handle = dlopen(
            "/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else { return nil }
        func resolve<T>(_ name: String, _ type: T.Type) -> T? {
            guard let symbol = dlsym(handle, name) else { return nil }
            return unsafeBitCast(symbol, to: type)
        }
        guard let create = resolve("IOHIDEventSystemClientCreate", ClientCreate.self),
              let setMatching = resolve("IOHIDEventSystemClientSetMatching", SetMatching.self),
              let copyServices = resolve("IOHIDEventSystemClientCopyServices", CopyServices.self),
              let copyEvent = resolve("IOHIDServiceClientCopyEvent", CopyEvent.self),
              let floatValue = resolve("IOHIDEventGetFloatValue", EventFloatValue.self),
              let copyProperty = resolve("IOHIDServiceClientCopyProperty", CopyProperty.self)
        else { return nil }
        return Symbols(create: create, setMatching: setMatching, copyServices: copyServices,
                       copyEvent: copyEvent, floatValue: floatValue, copyProperty: copyProperty)
    }()

    // MARK: - Cached client

    private var client: AnyObject?
    /// Name and service, paired once. Reading the `Product` property of sixty-odd services on every
    /// tick is the expensive half of this, and the set does not change while the Mac is running.
    private var sensors: [(name: String, service: AnyObject)] = []
    private var isUnavailable = false

    /// `nil` on a Mac with no readable sensors — an Intel Mac, which reports through the SMC
    /// instead, or any machine where the symbols have gone. Once that has been established it is
    /// not retried: the answer will not change before the next launch, and probing every two
    /// seconds forever to be told the same thing is worse than a dash.
    func read() -> Reading? {
        guard !isUnavailable, let symbols = Self.symbols else { return nil }

        if sensors.isEmpty {
            discoverSensors(using: symbols)
            guard !sensors.isEmpty else {
                isUnavailable = true
                log.info("No HID temperature sensors; temperatures will read as unavailable")
                return nil
            }
        }

        var readings: [(sensor: ThermalSensor, celsius: Double)] = []
        for sensor in sensors {
            guard let kind = ThermalSensor.classify(sensor.name), kind != .battery else { continue }
            guard let event = symbols.copyEvent(
                sensor.service, Self.eventTypeTemperature, 0, 0)?.takeRetainedValue()
            else { continue }
            let celsius = symbols.floatValue(
                event, Int32(truncatingIfNeeded: Self.eventTypeTemperature << 16))
            guard ThermalSensor.isPlausible(celsius: celsius) else { continue }
            readings.append((kind, celsius))
        }

        let reduced = ThermalSensor.reduce(readings)
        return Reading(cpu: reduced.cpu, gpu: reduced.gpu)
    }

    private func discoverSensors(using symbols: Symbols) {
        if client == nil {
            client = symbols.create(kCFAllocatorDefault)?.takeRetainedValue()
            guard let client else { return }
            let matching: [String: Int] = [
                "PrimaryUsagePage": Self.temperatureUsagePage,
                "PrimaryUsage": Self.temperatureUsage,
            ]
            symbols.setMatching(client, matching as CFDictionary)
        }
        guard let client,
              let services = symbols.copyServices(client)?.takeRetainedValue() as? [AnyObject]
        else { return }

        sensors = services.compactMap { service in
            guard let name = symbols.copyProperty(service, "Product" as CFString)?
                .takeRetainedValue() as? String else { return nil }
            return (name, service)
        }
    }
}
