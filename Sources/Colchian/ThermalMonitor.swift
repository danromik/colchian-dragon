import Foundation

/// Watches the system thermal state.
///
/// macOS exposes no public API for raw sensor temperatures on Apple Silicon; the thermal state
/// is the public signal macOS itself uses to decide when to throttle, which makes it a sound
/// trigger for letting the Mac sleep.
final class ThermalMonitor {
    var onChange: ((ProcessInfo.ThermalState) -> Void)?
    var state: ProcessInfo.ThermalState { ProcessInfo.processInfo.thermalState }
    private var observer: NSObjectProtocol?

    func start() {
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.onChange?(self.state)
        }
    }
}

/// Temperatures from the Mac's sensors, in °C; nil where the Mac has no such sensor.
struct Temperatures: Equatable {
    var cpu: Double?
    var battery: Double?
    var ssd: Double?
}

/// Reads the Mac's temperature sensors, for display only: the thermal state is still what decides when
/// the Mac has to sleep. Apple Silicon exposes its sensors only through IOKit's private HID event system,
/// so its functions are looked up at run time, and a Mac without them simply has no readings.
final class TemperatureSensors {
    private typealias CreateClient = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatching = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias CopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloatValue = @convention(c) (AnyObject, Int32) -> Double

    private static let temperatureEvent: Int64 = 15  // kIOHIDEventTypeTemperature

    private struct Functions {
        let copyServices: CopyServices, copyProperty: CopyProperty, copyEvent: CopyEvent, getFloatValue: GetFloatValue
    }

    private let functions: Functions?
    private let client: AnyObject?

    init() {
        let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
        func load<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(iokit, name).map { unsafeBitCast($0, to: type) }
        }
        guard let create = load("IOHIDEventSystemClientCreate", as: CreateClient.self),
              let setMatching = load("IOHIDEventSystemClientSetMatching", as: SetMatching.self),
              let copyServices = load("IOHIDEventSystemClientCopyServices", as: CopyServices.self),
              let copyProperty = load("IOHIDServiceClientCopyProperty", as: CopyProperty.self),
              let copyEvent = load("IOHIDServiceClientCopyEvent", as: CopyEvent.self),
              let getFloatValue = load("IOHIDEventGetFloatValue", as: GetFloatValue.self),
              let client = create(kCFAllocatorDefault)?.takeRetainedValue()
        else {
            functions = nil
            client = nil
            return
        }
        // The vendor-defined page and usage of temperature sensors.
        _ = setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        functions = Functions(copyServices: copyServices, copyProperty: copyProperty, copyEvent: copyEvent, getFloatValue: getFloatValue)
        self.client = client
    }

    /// The hottest reading of each kind: the CPU from the processor die's sensors, the battery from its
    /// fuel gauge, and the SSD from its flash controller.
    func read() -> Temperatures {
        guard let functions, let client,
              let services = functions.copyServices(client)?.takeRetainedValue() as? [AnyObject] else { return Temperatures() }
        var temperatures = Temperatures()
        func record(_ value: Double, in keyPath: WritableKeyPath<Temperatures, Double?>) {
            temperatures[keyPath: keyPath] = max(temperatures[keyPath: keyPath] ?? value, value)
        }
        for service in services {
            guard let name = functions.copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String,
                  let event = functions.copyEvent(service, Self.temperatureEvent, 0, 0)?.takeRetainedValue() else { continue }
            let value = functions.getFloatValue(event, Int32(Self.temperatureEvent << 16))
            guard value > 0, value < 150 else { continue }
            if name.hasPrefix("PMU tdie") {
                record(value, in: \.cpu)
            } else if name.hasPrefix("gas gauge battery") {
                record(value, in: \.battery)
            } else if name.hasPrefix("NAND") {
                record(value, in: \.ssd)
            }
        }
        return temperatures
    }
}
