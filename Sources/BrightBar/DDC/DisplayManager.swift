import AppKit
import Combine

struct ControlledDisplay: Identifiable, Equatable {
    enum Kind { case external, builtin }

    let id: String
    let kind: Kind
    var name: String
    var brightness: Int
    var maxBrightness: Int
    /// nil when the display does not expose contrast (the built-in panel, or a monitor without it).
    var contrast: Int?
    var maxContrast: Int

    var brightnessFraction: Double { Double(brightness) / Double(maxBrightness) }
}

/// Finds DDC-capable external displays plus the built-in panel and keeps their brightness /
/// contrast in sync with the UI. Slider changes are applied optimistically and coalesced so a
/// drag sends one I2C write per ~80 ms.
@MainActor
final class DisplayManager: ObservableObject {
    @Published private(set) var displays: [ControlledDisplay] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var lastError: String?

    static let builtinID = "builtin"

    private var services: [String: DDCService] = [:]
    private let builtin = BuiltinDisplayControl()
    private var pendingBrightness: [String: Int] = [:]
    private var pendingContrast: [String: Int] = [:]
    private var flushScheduled = false
    private var inFlight = 0
    private var screenObserver: Any?
    private var reconfigureWork: DispatchWorkItem?
    private var builtinPoll: Timer?

    private struct ScreenInfo {
        let vendor: UInt32, model: UInt32, serial: UInt32
        let name: String
        let originX: CGFloat
    }

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.screensChanged() }
        }
        refresh()
    }

    /// Monitors take a moment to come up after (re)connecting; wait before probing them.
    private func screensChanged() {
        reconfigureWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        reconfigureWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    /// While the panel is on screen, keep the built-in row in step with the keyboard brightness keys.
    func setVisible(_ visible: Bool) {
        builtinPoll?.invalidate()
        builtinPoll = nil
        guard visible, builtin != nil else { return }
        builtinPoll = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncBuiltin() }
        }
    }

    private func syncBuiltin() {
        guard pendingBrightness[Self.builtinID] == nil, let fraction = builtin?.read(),
              let index = displays.firstIndex(where: { $0.id == Self.builtinID }) else { return }
        let value = Int((fraction * 100).rounded())
        if displays[index].brightness != value { displays[index].brightness = value }
    }

    private func builtinRow() -> ControlledDisplay? {
        guard let builtin, let fraction = builtin.read() else { return nil }
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == builtin.displayID
        }
        return ControlledDisplay(id: Self.builtinID, kind: .builtin, name: screen?.localizedName ?? "Built-in Display",
                                 brightness: Int((fraction * 100).rounded()), maxBrightness: 100, contrast: nil, maxContrast: 100)
    }

    /// Re-enumerates connectors and reads the current values from each display.
    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let screens = Self.externalScreens()

        DDCService.queue.async { [weak self] in
            var found: [(display: ControlledDisplay, service: DDCService, order: CGFloat)] = []
            var usedKeys = Set<String>()
            let services = DDCService.externalServices()

            for service in services {
                let edid = service.readEDID()
                var key = edid.map { "\($0.vendor)-\($0.product)-\($0.serial)" } ?? "connector-\(service.registryID)"
                if usedKeys.contains(key) { key += "-\(service.registryID)" }
                usedKeys.insert(key)

                let screen = edid.flatMap { e in
                    screens.first { $0.vendor == UInt32(e.vendor) && $0.model == UInt32(e.product) && $0.serial == e.serial }
                }
                let name = screen?.name ?? edid?.name ?? "External display"

                guard let brightness = service.read(VCP.brightness) else {
                    Log.write("\(name) [\(service.registryID)] did not answer a brightness query; skipping")
                    continue
                }
                let contrast = service.read(VCP.contrast)
                let display = ControlledDisplay(
                    id: key, kind: .external, name: name,
                    brightness: Int(brightness.current), maxBrightness: max(1, Int(brightness.maximum)),
                    contrast: contrast.map { Int($0.current) }, maxContrast: max(1, Int(contrast?.maximum ?? 100))
                )
                found.append((display, service, screen?.originX ?? .greatestFiniteMagnitude))
                Log.write("\(name) [\(service.registryID)] brightness=\(brightness.current)/\(brightness.maximum) contrast=\(contrast.map { "\($0.current)/\($0.maximum)" } ?? "n/a")")
            }

            found.sort { $0.order < $1.order }
            let error: String? = found.isEmpty && !services.isEmpty
                ? "\(services.count) external display\(services.count == 1 ? "" : "s") connected, but none answered over DDC/CI."
                : nil

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.services = Dictionary(uniqueKeysWithValues: found.map { ($0.display.id, $0.service) })
                var rows = found.map(\.display)
                if let builtin = self.builtinRow() { rows.append(builtin) }
                // Keep any value the user is mid-way through dragging.
                self.displays = rows.map { row in
                    var d = row
                    if let p = self.pendingBrightness[d.id] { d.brightness = p }
                    if let p = self.pendingContrast[d.id], d.contrast != nil { d.contrast = p }
                    return d
                }
                self.lastError = error
                self.lastRefresh = Date()
                self.isRefreshing = false
            }
        }
    }

    /// True when the cached values are old enough that the monitor's own buttons may have moved them.
    var isStale: Bool {
        guard let lastRefresh else { return true }
        return Date().timeIntervalSince(lastRefresh) > 5
    }

    // MARK: - Setting values

    func setBrightness(_ value: Int, for id: String) {
        guard let index = displays.firstIndex(where: { $0.id == id }) else { return }
        let clamped = min(max(value, 0), displays[index].maxBrightness)
        guard displays[index].brightness != clamped else { return }
        displays[index].brightness = clamped
        pendingBrightness[id] = clamped
        scheduleFlush()
    }

    func setContrast(_ value: Int, for id: String) {
        guard let index = displays.firstIndex(where: { $0.id == id }), displays[index].contrast != nil else { return }
        let clamped = min(max(value, 0), displays[index].maxContrast)
        guard displays[index].contrast != clamped else { return }
        displays[index].contrast = clamped
        pendingContrast[id] = clamped
        scheduleFlush()
    }

    /// Sets every display to the same fraction of its range.
    func setBrightnessForAll(fraction: Double) {
        for display in displays {
            setBrightness(Int((fraction * Double(display.maxBrightness)).rounded()), for: display.id)
        }
    }

    /// Mean brightness across displays as a 0...1 fraction (drives the "All displays" slider).
    var averageBrightnessFraction: Double {
        guard !displays.isEmpty else { return 0 }
        return displays.map(\.brightnessFraction).reduce(0, +) / Double(displays.count)
    }

    /// Flush immediately (the slider was released).
    func commit() { flush() }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in self?.flush() }
    }

    private func flush() {
        flushScheduled = false
        var brightness = pendingBrightness
        let contrast = pendingContrast
        pendingBrightness.removeAll()
        pendingContrast.removeAll()

        if let value = brightness.removeValue(forKey: Self.builtinID) {
            if builtin?.write(Double(value) / 100) != true { Log.write("built-in brightness write failed") }
        }
        guard !brightness.isEmpty || !contrast.isEmpty else { return }

        var jobs: [(DDCService, UInt8, UInt16, String)] = []
        for (id, value) in brightness { if let s = services[id] { jobs.append((s, VCP.brightness, UInt16(value), id)) } }
        for (id, value) in contrast { if let s = services[id] { jobs.append((s, VCP.contrast, UInt16(value), id)) } }
        guard !jobs.isEmpty else { return }

        inFlight += 1
        DDCService.queue.async { [weak self] in
            var failures: [String] = []
            for (service, vcp, value, id) in jobs where !service.write(vcp, value: value) {
                failures.append(id)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.inFlight -= 1
                if !failures.isEmpty {
                    let names = failures.compactMap { id in self.displays.first { $0.id == id }?.name }
                    self.lastError = "Could not reach \(names.joined(separator: ", "))."
                    Log.write("DDC write failed for \(names)")
                } else if self.lastError != nil && self.inFlight == 0 {
                    self.lastError = nil
                }
            }
        }
    }

    // MARK: - CoreGraphics side

    private static func externalScreens() -> [ScreenInfo] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        return ids.prefix(Int(count)).compactMap { id in
            guard CGDisplayIsBuiltin(id) == 0 else { return nil }
            let screen = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id
            }
            return ScreenInfo(vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id),
                              name: screen?.localizedName ?? "External display",
                              originX: screen?.frame.minX ?? CGDisplayBounds(id).minX)
        }
    }
}
