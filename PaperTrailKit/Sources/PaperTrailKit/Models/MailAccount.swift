import Foundation

/// The dedicated mailbox Paper Trail checks. The password is not here: it lives in the Keychain.
public struct MailAccount: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    public var address: String
    /// iCloud: usually the part before @icloud.com; some clients need the full address.
    public var username: String
    public var server: String
    public var port: Int
    public var checkIntervalMinutes: Int

    public init(isEnabled: Bool = false, address: String = "", username: String = "",
                server: String = "imap.mail.me.com", port: Int = 993, checkIntervalMinutes: Int = 5) {
        self.isEnabled = isEnabled
        self.address = address
        self.username = username
        self.server = server
        self.port = port
        self.checkIntervalMinutes = checkIntervalMinutes
    }

    /// Defaults for an iCloud address: the server from Apple's iCloud Mail settings and the
    /// part before the @ as user name.
    public static func iCloud(address: String) -> MailAccount {
        let name = address.split(separator: "@").first.map(String.init) ?? address
        return MailAccount(isEnabled: true, address: address, username: name)
    }

    public var isComplete: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty && !server.trimmingCharacters(in: .whitespaces).isEmpty && (1...65535).contains(port)
    }
}
