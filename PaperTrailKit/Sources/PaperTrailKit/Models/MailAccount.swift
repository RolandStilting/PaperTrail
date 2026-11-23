import Foundation

/// The mailbox Paper Trail checks. The password is not here: it lives in the Keychain.
///
/// Paper Trail files *every* email in `folder` and then moves it to `processedFolder`, so the
/// folder must hold only emails meant for Paper Trail. With an iCloud alias that means a mail
/// rule moving the alias's emails into their own folder; the Inbox is refused unless the whole
/// account is dedicated to Paper Trail.
public struct MailAccount: Codable, Hashable, Sendable {
    public static let defaultFolder = "Paper Trail"
    public static let defaultProcessedFolder = "Paper Trail Processed"

    public var isEnabled: Bool
    /// The address emails are sent to (for iCloud: the alias). Only informational.
    public var address: String
    /// The account to sign in with. For iCloud this is the *main* iCloud address (or the part
    /// before @icloud.com), never an alias.
    public var username: String
    public var server: String
    public var port: Int
    public var checkIntervalMinutes: Int
    /// The folder whose emails are filed.
    public var folder: String
    /// Where filed emails are moved. Never deleted.
    public var processedFolder: String
    /// Only true when the whole account is used for nothing but Paper Trail.
    public var accountIsDedicated: Bool

    public init(isEnabled: Bool = false, address: String = "", username: String = "",
                server: String = "imap.mail.me.com", port: Int = 993, checkIntervalMinutes: Int = 5,
                folder: String = MailAccount.defaultFolder, processedFolder: String = MailAccount.defaultProcessedFolder,
                accountIsDedicated: Bool = false) {
        self.isEnabled = isEnabled
        self.address = address
        self.username = username
        self.server = server
        self.port = port
        self.checkIntervalMinutes = checkIntervalMinutes
        self.folder = folder
        self.processedFolder = processedFolder
        self.accountIsDedicated = accountIsDedicated
    }

    enum CodingKeys: String, CodingKey {
        case isEnabled, address, username, server, port, checkIntervalMinutes, folder, processedFolder, accountIsDedicated
    }

    /// Settings saved before the folder setting existed get the safe defaults.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        address = try c.decode(String.self, forKey: .address)
        username = try c.decode(String.self, forKey: .username)
        server = try c.decode(String.self, forKey: .server)
        port = try c.decode(Int.self, forKey: .port)
        checkIntervalMinutes = try c.decode(Int.self, forKey: .checkIntervalMinutes)
        folder = try c.decodeIfPresent(String.self, forKey: .folder) ?? Self.defaultFolder
        processedFolder = try c.decodeIfPresent(String.self, forKey: .processedFolder) ?? Self.defaultProcessedFolder
        accountIsDedicated = try c.decodeIfPresent(Bool.self, forKey: .accountIsDedicated) ?? false
    }

    /// Defaults for an iCloud address: the server from Apple's iCloud Mail settings and the
    /// part before the @ as user name.
    public static func iCloud(address: String) -> MailAccount {
        let name = address.split(separator: "@").first.map(String.init) ?? address
        return MailAccount(isEnabled: true, address: address, username: name)
    }

    public var isComplete: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty && !server.trimmingCharacters(in: .whitespaces).isEmpty
            && (1...65535).contains(port) && validationErrors.isEmpty
    }

    public var isICloud: Bool { server.trimmingCharacters(in: .whitespaces).lowercased() == "imap.mail.me.com" }

    public var watchesInbox: Bool { folder.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("INBOX") == .orderedSame }

    /// Problems that stop the mailbox from being checked, as user-facing messages.
    public var validationErrors: [String] {
        var errors: [String] = []
        let folder = folder.trimmingCharacters(in: .whitespaces)
        let processed = processedFolder.trimmingCharacters(in: .whitespaces)
        if folder.isEmpty || processed.isEmpty {
            errors.append(String(localized: "Enter both mailbox folders.", bundle: .module))
        }
        if !folder.isEmpty, folder.caseInsensitiveCompare(processed) == .orderedSame {
            errors.append(String(localized: "The folder to check and the Processed folder must be different.", bundle: .module))
        }
        if watchesInbox, !accountIsDedicated {
            errors.append(String(localized: "Paper Trail won't check the Inbox of an account you also use for other mail: it would file and move every email. Use a mail rule that moves the Paper Trail address's emails to their own folder, and enter that folder.", bundle: .module))
        }
        // IMAP folder names outside ASCII need modified UTF-7, which Paper Trail doesn't do.
        if !(folder + processed).allSatisfy(\.isASCII) {
            errors.append(String(localized: "Use folder names without accents or special letters.", bundle: .module))
        }
        return errors
    }
}
