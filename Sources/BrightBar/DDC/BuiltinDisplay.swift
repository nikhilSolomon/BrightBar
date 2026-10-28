import CoreGraphics
import Foundation

/// Brightness of the Mac's own panel, through the private DisplayServices framework that
/// System Settings and the keyboard brightness keys use. Values are a 0...1 fraction.
final class BuiltinDisplayControl: @unchecked Sendable {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    let displayID: CGDirectDisplayID
    private let getBrightness: GetBrightness
    private let setBrightness: SetBrightness

    init?() {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        guard let builtin = ids.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) else { return nil }

        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let get = dlsym(handle, "DisplayServicesGetBrightness"),
              let set = dlsym(handle, "DisplayServicesSetBrightness") else {
            Log.write("DisplayServices framework not available; built-in display control disabled")
            return nil
        }
        displayID = builtin
        getBrightness = unsafeBitCast(get, to: GetBrightness.self)
        setBrightness = unsafeBitCast(set, to: SetBrightness.self)
    }

    func read() -> Double? {
        var value: Float = 0
        guard getBrightness(displayID, &value) == 0 else { return nil }
        return Double(value)
    }

    @discardableResult
    func write(_ fraction: Double) -> Bool {
        setBrightness(displayID, Float(min(max(fraction, 0), 1))) == 0
    }
}
