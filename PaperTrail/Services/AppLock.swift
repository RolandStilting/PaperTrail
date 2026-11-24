import LocalAuthentication
import Observation
import PaperTrailKit
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Optional lock with Face ID, Touch ID or Optic ID (the device passcode or Mac password as
/// fallback). A device setting, not synced: each device decides for itself.
///
/// While locked, every window gets a cover in a layer of its own, so sheets such as the
/// filing screen are hidden too. On iPhone and iPad a cover also hides the app in the app
/// switcher. Locking is only what's shown: mail intake and syncing go on.
@Observable
final class AppLock {
    static let enabledKey = "appLockEnabled"
    static let timeoutKey = "appLockTimeout"

    #if os(iOS)
    static let defaultTimeout = LockTimeout.immediately
    #else
    static let defaultTimeout = LockTimeout.fiveMinutes
    #endif

    private(set) var isLocked: Bool
    private(set) var isAuthenticating = false
    /// Why the last unlock failed, shown on the lock screen.
    var problem: String?
    /// iPhone/iPad: covered while in the app switcher, without being locked.
    private var privacyCover = false
    private var awaySince: Date?
    /// Ask for Face ID by itself only at launch and after being away; after a cancel the user
    /// taps Unlock (the prompt closing makes the app active again, which must not re-prompt).
    private var promptsOnReturn = true

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    var timeout: LockTimeout {
        (UserDefaults.standard.object(forKey: Self.timeoutKey) as? Int).flatMap(LockTimeout.init(rawValue:)) ?? Self.defaultTimeout
    }

    init() {
        // Locked from the start when the lock is on.
        isLocked = UserDefaults.standard.bool(forKey: Self.enabledKey)
        #if os(macOS)
        observeMac()
        #endif
    }

    // MARK: Unlocking

    /// What this device unlocks with, for labels and symbols.
    enum Method {
        case faceID, touchID, opticID, passcode

        static var current: Method {
            let context = LAContext()
            var error: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { return .passcode }
            switch context.biometryType {
            case .faceID: return .faceID
            case .touchID: return .touchID
            case .opticID: return .opticID
            default: return .passcode
            }
        }

        var name: String {
            switch self {
            case .faceID: "Face ID"
            case .touchID: "Touch ID"
            case .opticID: "Optic ID"
            #if os(iOS)
            case .passcode: String(localized: "Passcode")
            #else
            case .passcode: String(localized: "Password")
            #endif
            }
        }

        var systemImage: String {
            switch self {
            case .faceID: "faceid"
            case .touchID: "touchid"
            case .opticID: "opticid"
            case .passcode: "lock"
            }
        }
    }

    /// False when the device has no passcode, so a lock could never be opened.
    static var isAvailable: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    /// Asks for Face ID, Touch ID or Optic ID, with the passcode as fallback.
    func authenticate(reason: String) async -> Bool {
        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            let success = try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            if success { problem = nil }
            return success
        } catch let error as LAError where [.userCancel, .appCancel, .systemCancel].contains(error.code) {
            return false
        } catch {
            problem = error.localizedDescription
            return false
        }
    }

    func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        if await authenticate(reason: String(localized: "Unlock your documents.")) {
            isLocked = false
            awaySince = nil
            updateCovers()
        }
    }

    /// Lock now, e.g. when the Mac goes to sleep.
    func lockNow() {
        guard isEnabled, !isLocked else { return }
        isLocked = true
        updateCovers()
    }

    /// The lock was turned off in Settings.
    func turnedOff() {
        isLocked = false
        privacyCover = false
        updateCovers()
    }

    // MARK: Coming and going

    /// The app went to the background (iPhone/iPad) or another app came to the front (Mac).
    func wentAway() {
        guard !isAuthenticating else { return }
        if awaySince == nil { awaySince = .now }
        promptsOnReturn = true
    }

    /// The app is in front again: lock if it was away long enough, and ask to unlock.
    func cameBack() {
        guard !isAuthenticating else { return }
        if AppLockPolicy.shouldLock(enabled: isEnabled, awaySince: awaySince, now: .now, timeout: timeout) {
            isLocked = true
        }
        awaySince = nil
        privacyCover = false
        updateCovers()
        if isLocked, promptsOnReturn {
            promptsOnReturn = false
            Task { await unlock() }
        }
    }

    #if os(iOS)
    /// Follows the scene phase. Face ID's own prompt makes the app inactive briefly; that is ignored.
    func scenePhaseChanged(to phase: ScenePhase) {
        guard !isAuthenticating else { return }
        switch phase {
        case .active:
            cameBack()
        case .inactive:
            // App switcher or Control Center: hide the documents in the snapshot.
            if isEnabled { privacyCover = true; updateCovers() }
        case .background:
            if isEnabled { privacyCover = true; updateCovers() }
            wentAway()
        @unknown default:
            break
        }
    }
    #endif

    // MARK: Covers

    private var isCovered: Bool { isLocked || privacyCover }

    #if os(iOS)
    private var coverWindows: [ObjectIdentifier: UIWindow] = [:]

    /// One cover window per scene, above everything else in it, sheets and keyboard included.
    func updateCovers() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard isCovered else {
            coverWindows.values.forEach { $0.isHidden = true }
            coverWindows = [:]
            // Give the keyboard back to the app's own window.
            for scene in scenes { scene.windows.first { $0.windowLevel == .normal }?.makeKey() }
            return
        }
        for scene in scenes where coverWindows[ObjectIdentifier(scene)] == nil {
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            window.rootViewController = UIHostingController(rootView: LockScreen(lock: self))
            window.makeKeyAndVisible()
            coverWindows[ObjectIdentifier(scene)] = window
        }
    }
    #else
    private var covers: [ObjectIdentifier: NSView] = [:]

    /// A cover over every titled window and sheet. Windows opened while locked are covered as
    /// they appear.
    func updateCovers() {
        guard isCovered else {
            covers.values.forEach { $0.removeFromSuperview() }
            covers = [:]
            return
        }
        for window in NSApp.windows where window.isVisible && (window.styleMask.contains(.titled) || window.isSheet) {
            let key = ObjectIdentifier(window)
            guard covers[key] == nil, let content = window.contentView else { continue }
            let cover = NSHostingView(rootView: LockScreen(lock: self))
            cover.frame = content.bounds
            cover.autoresizingMask = [.width, .height]
            content.addSubview(cover)
            // Typing must not reach a text field under the cover.
            window.makeFirstResponder(nil)
            covers[key] = cover
        }
    }

    private func observeMac() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wentAway() }
        }
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cameBack() }
        }
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateCovers() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lockNow() }
            }
        }
    }
    #endif
}

/// What a locked window shows.
struct LockScreen: View {
    let lock: AppLock

    var body: some View {
        let method = AppLock.Method.current
        VStack(spacing: 18) {
            Image(systemName: lock.isLocked ? "lock.fill" : "doc.text.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text(lock.isLocked ? "Paper Trail is locked" : "Paper Trail")
                .font(.title2.weight(.semibold))
            if lock.isLocked {
                Button {
                    Task { await lock.unlock() }
                } label: {
                    Label("Unlock with \(method.name)", systemImage: method.systemImage)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(lock.isAuthenticating)
                if let problem = lock.problem {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
        .tint(Color.accentColor)
    }
}
