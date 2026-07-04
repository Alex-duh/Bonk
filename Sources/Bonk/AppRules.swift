import Foundation
import AppKit

// A per-app override: when `bundleID` is frontmost and `pattern` knocks are
// detected, run `command` instead of the global mapping.
struct AppRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var bundleID: String
    var appName: String     // display only
    var pattern: Int        // 1, 2, or 3 knocks
    var command: String
    var arg: String

    static let patternLabels = [1: "Single", 2: "Double", 3: "Triple"]
}

extension Array where Element == AppRule {
    // First matching rule for the frontmost app, or nil to use the global mapping.
    func match(count: Int, frontmost: NSRunningApplication?) -> AppRule? {
        guard let bundleID = frontmost?.bundleIdentifier else { return nil }
        return first { $0.bundleID == bundleID && $0.pattern == count }
    }
}
