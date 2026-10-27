import Foundation

/// Automatic patch timeout policy is intentionally disabled.
/// Patch activation remains active until the user explicitly turns it off or
/// a verified conflicting patch transaction must be replaced.
enum AutoDisablePatchPolicy {
    static let defaultEnabled = false
    static let defaultTimeoutSeconds: TimeInterval = 0

    static func deadline(from start: Date, timeoutSeconds: TimeInterval = defaultTimeoutSeconds) -> Date {
        start.addingTimeInterval(max(0, timeoutSeconds))
    }
}
