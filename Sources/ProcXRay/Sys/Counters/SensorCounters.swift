import Foundation

/// Temperature sensors from the HID event system (IOHIDEventSystemClient, private, looked up at run time; no
/// privileges needed): the services on usage page 0xff00, usage 5, each read as a temperature event (type 15).
/// 57 on an M1 MacBook Pro: CPU cluster (eACC/pACC MTR), GPU, PMU die (tdie), NAND, battery and others. Some
/// read nonsense (a PMU tdev at −22 °C); they are listed as they are, and the Thermal dashboard leaves them out.
final class SensorCounters: CounterSource {
    let kind = CounterSourceKind.sensors
    static let groupID = "sensors|temperature"

    private typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias SetMatching = @convention(c) (CFTypeRef, CFDictionary) -> Void
    private typealias CopyServices = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias CopyEvent = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias CopyProperty = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias GetFloat = @convention(c) (CFTypeRef, Int32) -> Double

    private static let temperatureEvent: Int64 = 15
    private static let temperatureField: Int32 = 15 << 16

    private var copyEvent: CopyEvent?
    private var getFloat: GetFloat?
    private var copyProperty: CopyProperty?
    private var client: CFTypeRef?
    /// The services that answered with a temperature, and their counter ids.
    private var sensors: [(service: CFTypeRef, id: String)] = []

    init() {
        let h = UnsafeMutableRawPointer(bitPattern: -2)   // RTLD_DEFAULT: IOKit is linked
        func f<T>(_ n: String) -> T? { dlsym(h, n).map { unsafeBitCast($0, to: T.self) } }
        guard let create: Create = f("IOHIDEventSystemClientCreate"), let match: SetMatching = f("IOHIDEventSystemClientSetMatching"),
              let copyEvent: CopyEvent = f("IOHIDServiceClientCopyEvent"), let getFloat: GetFloat = f("IOHIDEventGetFloatValue"),
              let copyProperty: CopyProperty = f("IOHIDServiceClientCopyProperty"),
              let c = create(kCFAllocatorDefault)?.takeRetainedValue() else { return }
        match(c, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        self.client = c
        self.copyEvent = copyEvent
        self.getFloat = getFloat
        self.copyProperty = copyProperty
    }

    func groups() -> [CounterGroup] {
        sensors = []
        let h = UnsafeMutableRawPointer(bitPattern: -2)
        guard let client, let copyEvent, let copyProperty,
              let sym = dlsym(h, "IOHIDEventSystemClientCopyServices"),
              let list = unsafeBitCast(sym, to: CopyServices.self)(client)?.takeRetainedValue() as? [CFTypeRef] else { return [] }
        var counters: [CounterInfo] = []
        var used: [String: Int] = [:]
        for s in list {
            guard copyEvent(s, Self.temperatureEvent, 0, 0) != nil else { continue }
            var name = (copyProperty(s, "Product" as CFString)?.takeRetainedValue() as? String) ?? "Sensor"
            used[name, default: 0] += 1
            if let n = used[name], n > 1 { name += " #\(n)" }
            let id = Self.groupID + "|" + name
            sensors.append((s, id))
            counters.append(CounterInfo(id: id, group: Self.groupID, name: name, unit: "°C"))
        }
        guard !counters.isEmpty else { return [] }
        return [CounterGroup(id: Self.groupID, source: .sensors, name: "Temperature sensors",
                             note: "IOHIDEventSystemClient temperature events (usage page 0xff00, usage 5), in °C", counters: counters)]
    }

    func read(_ groups: Set<String>?) -> [String: CounterValue] {
        guard groups?.contains(Self.groupID) ?? true, let copyEvent, let getFloat else { return [:] }
        var out: [String: CounterValue] = [:]
        for (s, id) in sensors {
            guard let e = copyEvent(s, Self.temperatureEvent, 0, 0)?.takeRetainedValue() else { continue }
            out[id] = .double((getFloat(e, Self.temperatureField) * 10).rounded() / 10)
        }
        return out
    }
}
