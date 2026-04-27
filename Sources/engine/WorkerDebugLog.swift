//
//  WorkerDebugLog.swift
//  摸鱼侠 plugin
//
//  Plugin-bundle NSLog calls don't reliably surface in `log show` from
//  the host process. This helper writes timestamped lines to a known
//  file so we can `tail -f` it during debugging.
//

import Foundation

enum WorkerDebugLog {
    static let path = "/tmp/worker-plugin.log"
    private static let queue = DispatchQueue(label: "worker.debug.log")
    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        let stamp = dateFmt.string(from: Date())
        let line = "[\(stamp)] \(message)\n"
        queue.async {
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: path) {
                    if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
                        do {
                            try handle.seekToEnd()
                            try handle.write(contentsOf: data)
                            try handle.close()
                        } catch {
                            // best-effort log: ignore write failures.
                        }
                    }
                } else {
                    try? data.write(to: URL(fileURLWithPath: path))
                }
            }
        }
    }
}
