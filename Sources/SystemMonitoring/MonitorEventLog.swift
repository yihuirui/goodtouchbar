import Foundation

public final class MonitorEventLog {
    private let url: URL
    private let queue = DispatchQueue(label: "io.github.yihuirui.goodtouchbar.metrics.log", qos: .utility)
    public init(url: URL) { self.url = url }
    public func record(_ event: String, code: String? = nil, fields: [String: Int] = [:], requestID: String? = nil) {
        queue.async { [url] in
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                var record: [String: Any] = ["time": ISO8601DateFormatter().string(from: Date()), "build": AppBuild.current, "event": event]
                if let code { record["code"] = String(code.prefix(128)) }
                if let requestID, UUID(uuidString:requestID) != nil { record["requestID"] = requestID }
                for (key, value) in fields where ["elapsed_ms", "launches", "samples", "pid", "attempts"].contains(key) { record[key] = value }
                let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) + Data([10])
                let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
                if size + data.count > 1_048_576 {
                    let oldest = URL(fileURLWithPath: url.path + ".3")
                    if fm.fileExists(atPath: oldest.path) { try fm.removeItem(at: oldest) }
                    for i in stride(from: 2, through: 0, by: -1) {
                        let from = i == 0 ? url : URL(fileURLWithPath: url.path + ".\(i)")
                        let to = URL(fileURLWithPath: url.path + ".\(i+1)")
                        if fm.fileExists(atPath: from.path) { try fm.moveItem(at: from, to: to) }
                    }
                }
                if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
                let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
                try handle.seekToEnd(); try handle.write(contentsOf: data)
            } catch { /* Logging must not break monitoring. */ }
        }
    }
}
