import Foundation

/// How long Paper Trail may be away (in the background, or another app in front on the Mac)
/// before it asks for Face ID, Touch ID or the passcode again.
public enum LockTimeout: Int, CaseIterable, Sendable, Identifiable {
    case immediately = 0
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case oneHour = 3600

    public var id: Int { rawValue }
    public var seconds: TimeInterval { TimeInterval(rawValue) }
}

public enum AppLockPolicy {
    /// True when the app must be unlocked as it comes back after being away since `awaySince`.
    /// Never away (nil): no lock. The lock at launch is decided separately.
    public static func shouldLock(enabled: Bool, awaySince: Date?, now: Date, timeout: LockTimeout) -> Bool {
        guard enabled, let awaySince else { return false }
        return now.timeIntervalSince(awaySince) >= timeout.seconds
    }
}
