import Foundation
import IOKit

// Apple Silicon exposes each display connector's I2C bus through a DCPAVServiceProxy registry
// entry. These IOKit calls are private (not App Store safe) but stable since macOS 11; they are
// what MonitorControl, BetterDisplay and m1ddc use.
@_silgen_name("IOAVServiceCreateWithService")
private func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOAVServiceReadI2C")
private func IOAVServiceReadI2C(_ service: CFTypeRef, _ chipAddress: UInt32, _ offset: UInt32,
                                _ outputBuffer: UnsafeMutableRawPointer, _ outputBufferSize: UInt32) -> IOReturn
@_silgen_name("IOAVServiceWriteI2C")
private func IOAVServiceWriteI2C(_ service: CFTypeRef, _ chipAddress: UInt32, _ dataAddress: UInt32,
                                 _ inputBuffer: UnsafeRawPointer, _ inputBufferSize: UInt32) -> IOReturn

/// MCCS Virtual Control Panel codes.
enum VCP {
    static let brightness: UInt8 = 0x10
    static let contrast: UInt8 = 0x12
}

/// What a monitor says about itself in the first 128 bytes of its EDID.
struct EDIDInfo {
    var vendor: UInt16       // same encoding as CGDisplayVendorNumber (e.g. 0x10AC = Dell)
    var product: UInt16      // same as CGDisplayModelNumber
    var serial: UInt32       // same as CGDisplaySerialNumber
    var name: String?        // "Monitor name" descriptor, e.g. "DELL P2422H"
    var serialString: String?

    init?(_ bytes: [UInt8]) {
        guard bytes.count >= 128,
              bytes[0] == 0x00, bytes[1] == 0xFF, bytes[2] == 0xFF, bytes[3] == 0xFF,
              bytes[4] == 0xFF, bytes[5] == 0xFF, bytes[6] == 0xFF, bytes[7] == 0x00 else { return nil }
        vendor = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
        product = UInt16(bytes[11]) << 8 | UInt16(bytes[10])
        serial = UInt32(bytes[15]) << 24 | UInt32(bytes[14]) << 16 | UInt32(bytes[13]) << 8 | UInt32(bytes[12])
        for i in 0..<4 {
            let d = 54 + 18 * i
            guard bytes[d] == 0, bytes[d + 1] == 0, bytes[d + 2] == 0 else { continue }
            let text = String(bytes: bytes[(d + 5)..<(d + 18)], encoding: .ascii)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            switch bytes[d + 3] {
            case 0xFC: name = text
            case 0xFF: serialString = text
            default: break
            }
        }
    }
}

/// One DDC/CI channel to an external monitor. All I2C traffic goes through `DDCService.queue`.
/// Immutable after init and every transaction runs on `queue`, so sharing it across threads is safe.
final class DDCService: @unchecked Sendable {
    /// Serial queue for every DDC transaction; the I2C bus does not like concurrent chatter.
    static let queue = DispatchQueue(label: "dev.local.BrightBar.ddc", qos: .userInitiated)

    let registryID: UInt64
    private let avService: CFTypeRef

    private static let ddcChip: UInt32 = 0x37      // DDC/CI slave address (0x6E >> 1)
    private static let edidChip: UInt32 = 0x50     // EDID EEPROM address (0xA0 >> 1)
    private static let hostAddress: UInt8 = 0x51   // source address in every DDC packet
    private static let dest: UInt8 = 0x6E          // destination address, used in the checksum only

    private init?(entry: io_service_t) {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(entry, &id)
        guard let svc = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)?.takeRetainedValue() else { return nil }
        registryID = id
        avService = svc
    }

    /// Every connector with an external display attached, in a stable order.
    static func externalServices() -> [DDCService] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == kIOReturnSuccess else {
            Log.write("IOServiceGetMatchingServices(DCPAVServiceProxy) failed")
            return []
        }
        defer { IOObjectRelease(iterator) }
        var result: [DDCService] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            guard location == "External" else { continue }
            if let service = DDCService(entry: entry) { result.append(service) }
        }
        return result.sorted { $0.registryID < $1.registryID }
    }

    // MARK: - Transactions (call on `DDCService.queue`)

    func readEDID() -> EDIDInfo? {
        dispatchPrecondition(condition: .onQueue(Self.queue))
        var buffer = [UInt8](repeating: 0, count: 128)
        for _ in 0..<3 {
            let status = IOAVServiceReadI2C(avService, Self.edidChip, 0, &buffer, 128)
            if status == kIOReturnSuccess, let info = EDIDInfo(buffer) { return info }
            usleep(30_000)
        }
        return nil
    }

    /// Reads a VCP feature. Returns nil if the monitor does not answer or reports the code unsupported.
    func read(_ vcp: UInt8, attempts: Int = 4) -> (current: UInt16, maximum: UInt16)? {
        dispatchPrecondition(condition: .onQueue(Self.queue))
        let request = Self.packet([0x82, 0x01, vcp])
        var reply = [UInt8](repeating: 0, count: 12)
        for attempt in 0..<attempts {
            if attempt > 0 { usleep(UInt32(60_000 * attempt)) }
            guard IOAVServiceWriteI2C(avService, Self.ddcChip, UInt32(Self.hostAddress), request, UInt32(request.count)) == kIOReturnSuccess else { continue }
            usleep(40_000)
            guard IOAVServiceReadI2C(avService, Self.ddcChip, UInt32(Self.hostAddress), &reply, 12) == kIOReturnSuccess else { continue }
            // 6E 88 02 RC VCP TYPE MAXH MAXL CURH CURL CHK
            guard reply[2] == 0x02, reply[4] == vcp else { continue }
            if reply[3] != 0x00 { return nil }  // RC 0x01 = unsupported VCP code
            return (UInt16(reply[8]) << 8 | UInt16(reply[9]), UInt16(reply[6]) << 8 | UInt16(reply[7]))
        }
        return nil
    }

    @discardableResult
    func write(_ vcp: UInt8, value: UInt16, attempts: Int = 3) -> Bool {
        dispatchPrecondition(condition: .onQueue(Self.queue))
        let request = Self.packet([0x84, 0x03, vcp, UInt8(value >> 8), UInt8(value & 0xFF)])
        for attempt in 0..<attempts {
            if attempt > 0 { usleep(UInt32(60_000 * attempt)) }
            if IOAVServiceWriteI2C(avService, Self.ddcChip, UInt32(Self.hostAddress), request, UInt32(request.count)) == kIOReturnSuccess {
                usleep(50_000)  // MCCS asks for >= 50 ms between commands
                return true
            }
        }
        return false
    }

    /// Appends the DDC/CI checksum. `body` starts with the length byte (0x80 | n).
    private static func packet(_ body: [UInt8]) -> [UInt8] {
        var checksum = dest ^ hostAddress
        for byte in body { checksum ^= byte }
        return body + [checksum]
    }
}
