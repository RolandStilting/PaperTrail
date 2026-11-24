import Foundation
import Testing
@testable import PaperTrailKit

@Suite("AppLockPolicy")
struct AppLockPolicyTests {
    let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test func locksAfterTheTimeout() {
        #expect(AppLockPolicy.shouldLock(enabled: true, awaySince: now.addingTimeInterval(-61), now: now, timeout: .oneMinute))
        #expect(AppLockPolicy.shouldLock(enabled: true, awaySince: now.addingTimeInterval(-60), now: now, timeout: .oneMinute))
        #expect(!AppLockPolicy.shouldLock(enabled: true, awaySince: now.addingTimeInterval(-59), now: now, timeout: .oneMinute))
        #expect(AppLockPolicy.shouldLock(enabled: true, awaySince: now, now: now, timeout: .immediately))
    }

    @Test func noLockWhenOffOrNeverAway() {
        #expect(!AppLockPolicy.shouldLock(enabled: false, awaySince: now.addingTimeInterval(-9999), now: now, timeout: .immediately))
        #expect(!AppLockPolicy.shouldLock(enabled: true, awaySince: nil, now: now, timeout: .immediately))
    }
}
