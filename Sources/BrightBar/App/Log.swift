import Foundation

/// Appends diagnostics to ~/Library/Logs/BrightBar.log (and the system log).
enum Log {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/BrightBar.log")
    private static let queue = DispatchQueue(label: "dev.local.BrightBar.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f
    }()

    static func write(_ message: String) {
        NSLog("BrightBar: %@", message)
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                try? handle.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}
