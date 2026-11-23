import Foundation
import Observation
import PaperTrailKit

protocol SettingsPersisting {
    func load() -> ArchiveSettings?
    func save(_ settings: ArchiveSettings)
}

/// Keeps settings in iCloud key-value storage so they sync between devices,
/// with a local copy in UserDefaults for when iCloud is unavailable.
final class CloudSettingsPersistence: SettingsPersisting {
    static let key = "archiveSettings.v1"
    private let cloud = NSUbiquitousKeyValueStore.default
    private let local = UserDefaults.standard

    func load() -> ArchiveSettings? {
        for data in [cloud.data(forKey: Self.key), local.data(forKey: Self.key)].compactMap({ $0 }) {
            if let settings = try? JSONDecoder().decode(ArchiveSettings.self, from: data) { return settings }
        }
        return nil
    }

    func save(_ settings: ArchiveSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        local.set(data, forKey: Self.key)
        cloud.set(data, forKey: Self.key)
    }
}

@Observable
final class SettingsStore {
    private(set) var settings: ArchiveSettings
    @ObservationIgnored private let persistence: any SettingsPersisting
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    init(persistence: any SettingsPersisting = CloudSettingsPersistence()) {
        self.persistence = persistence
        self.settings = persistence.load() ?? .defaults
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    /// Saves valid settings. Returns the validation errors; empty means saved.
    @discardableResult
    func update(_ newSettings: ArchiveSettings) -> [String] {
        let errors = newSettings.validationErrors
        guard errors.isEmpty else { return errors }
        settings = newSettings
        persistence.save(newSettings)
        return []
    }

    private func reload() {
        if let loaded = persistence.load() { settings = loaded }
    }
}
