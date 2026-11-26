import Foundation

/// Sends and receives raw bytes for an IMAP session (a TLS connection in the app, a script in tests).
public protocol IMAPTransport: Sendable {
    func send(_ data: Data) async throws
    /// The next bytes from the server; throws when the connection is closed.
    func receive() async throws -> Data
}

public enum IMAPError: LocalizedError, Equatable, Sendable {
    /// The server answered NO or BAD. The text is the server's, without credentials.
    case commandFailed(command: String, response: String)
    case loginFailed(String)
    case unexpectedResponse(String)
    case connectionClosed

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let command, let response):
            String(localized: "The mail server refused \(command): \(response)", bundle: .module)
        case .loginFailed(let response):
            String(localized: "Could not sign in to the mailbox (\(response)). For iCloud: sign in with your main iCloud address, not an alias, and an app-specific password; your normal Apple Account password doesn't work with two-factor authentication.", bundle: .module)
        case .unexpectedResponse(let text):
            String(localized: "The mail server sent something Paper Trail didn't expect: \(text)", bundle: .module)
        case .connectionClosed:
            String(localized: "The connection to the mail server was closed. Check your internet connection and try again.", bundle: .module)
        }
    }
}

/// One untagged server response: its text, with any literals ({n} byte blocks) taken out.
public struct IMAPUntagged: Sendable, Equatable {
    public var text: String
    public var literals: [Data]
}

/// The small part of IMAP4rev1 (RFC 3501) that Paper Trail needs, plus MOVE (RFC 6851)
/// and UIDPLUS (RFC 4315) when the server has them.
public actor IMAPSession {
    private let transport: any IMAPTransport
    private var buffer = Data()
    private var tagNumber = 0
    public private(set) var capabilities: Set<String> = []

    public init(transport: any IMAPTransport) {
        self.transport = transport
    }

    // MARK: Commands

    public func start() async throws {
        let greeting = try await readResponse()
        guard greeting.text.hasPrefix("* OK") || greeting.text.hasPrefix("* PREAUTH") else {
            throw IMAPError.unexpectedResponse(greeting.text)
        }
    }

    /// Signs in with SASL PLAIN (RFC 4616) when the server offers it, else with LOGIN.
    /// Both send the credentials only over the TLS connection.
    public func login(user: String, password: String) async throws {
        // A line break or NUL would end the command early (and could add another one).
        guard !Self.hasControlCharacters(user), !Self.hasControlCharacters(password) else {
            throw IMAPError.loginFailed(String(localized: "the user name or password contains a line break or other control character", bundle: .module))
        }
        try await refreshCapabilities()
        do {
            if capabilities.contains("AUTH=PLAIN") {
                let credentials = Data("\u{0}\(user)\u{0}\(password)".utf8).base64EncodedString()
                if capabilities.contains("SASL-IR") {
                    _ = try await run("AUTHENTICATE PLAIN \(credentials)", display: "AUTHENTICATE")
                } else {
                    _ = try await run("AUTHENTICATE PLAIN", display: "AUTHENTICATE", continuation: credentials)
                }
            } else if capabilities.contains("LOGINDISABLED") {
                throw IMAPError.loginFailed("the server offers no sign-in method Paper Trail supports")
            } else {
                _ = try await run("LOGIN \(Self.quoted(user)) \(Self.quoted(password))", display: "LOGIN")
            }
        } catch IMAPError.commandFailed(_, let response) {
            throw IMAPError.loginFailed(response)
        }
        try await refreshCapabilities()
    }

    /// The sign-in method the server will be asked for, for diagnostics (no credentials).
    public var signInMethod: String {
        capabilities.contains("AUTH=PLAIN") ? "AUTHENTICATE PLAIN" : "LOGIN"
    }

    public func refreshCapabilities() async throws {
        let responses = try await run("CAPABILITY")
        for response in responses where response.text.uppercased().hasPrefix("* CAPABILITY ") {
            capabilities = Set(response.text.dropFirst("* CAPABILITY ".count).uppercased().split(separator: " ").map(String.init))
        }
    }

    public func select(_ mailbox: String) async throws {
        _ = try await run("SELECT \(Self.quoted(mailbox))")
    }

    /// UIDs of all messages in the selected mailbox.
    public func allUIDs() async throws -> [UInt32] {
        let responses = try await run("UID SEARCH ALL")
        return responses
            .filter { $0.text.uppercased().hasPrefix("* SEARCH") }
            .flatMap { $0.text.dropFirst("* SEARCH".count).split(separator: " ").compactMap { UInt32($0) } }
    }

    /// The full raw message, without marking it read.
    public func fetchMessage(uid: UInt32) async throws -> Data {
        let responses = try await run("UID FETCH \(uid) (BODY.PEEK[])")
        guard let message = responses.first(where: { $0.text.uppercased().contains("FETCH") && !$0.literals.isEmpty })?.literals.first else {
            throw IMAPError.unexpectedResponse("no message body for UID \(uid)")
        }
        return message
    }

    /// Creates a mailbox; an existing one is fine.
    public func createMailboxIfNeeded(_ name: String) async throws {
        do {
            _ = try await run("CREATE \(Self.quoted(name))")
        } catch IMAPError.commandFailed(_, let response) {
            // Servers answer NO (often with [ALREADYEXISTS]) when it exists; check that it does.
            let listed = try await run("LIST \"\" \(Self.quoted(name))")
            guard listed.contains(where: { $0.text.uppercased().hasPrefix("* LIST") }) else {
                throw IMAPError.commandFailed(command: "CREATE", response: response)
            }
        }
    }

    /// Moves one message: UID MOVE when available, else copy, flag deleted and expunge.
    public func move(uid: UInt32, to mailbox: String) async throws {
        if capabilities.contains("MOVE") {
            _ = try await run("UID MOVE \(uid) \(Self.quoted(mailbox))")
            return
        }
        _ = try await run("UID COPY \(uid) \(Self.quoted(mailbox))")
        _ = try await run("UID STORE \(uid) +FLAGS.SILENT (\\Deleted)")
        if capabilities.contains("UIDPLUS") {
            _ = try await run("UID EXPUNGE \(uid)")
        } else {
            _ = try await run("EXPUNGE")
        }
    }

    public func logout() async {
        _ = try? await run("LOGOUT")
    }

    // MARK: Protocol

    /// Sends a tagged command and returns its untagged responses. Throws on NO or BAD.
    /// `display` replaces the command in errors, so passwords never end up in messages.
    @discardableResult
    func run(_ command: String, display: String? = nil, continuation: String? = nil) async throws -> [IMAPUntagged] {
        tagNumber += 1
        let tag = String(format: "A%03d", tagNumber)
        try await transport.send(Data("\(tag) \(command)\r\n".utf8))
        var untagged: [IMAPUntagged] = []
        var pendingContinuation = continuation
        while true {
            let response = try await readResponse()
            if response.text.hasPrefix("+") {
                // The server asks for more: send it once, or cancel with "*" (RFC 3501 6.2.2).
                try await transport.send(Data("\(pendingContinuation ?? "*")\r\n".utf8))
                pendingContinuation = nil
                continue
            }
            if response.text.hasPrefix("\(tag) ") {
                let status = response.text.dropFirst(tag.count + 1)
                if status.uppercased().hasPrefix("OK") { return untagged }
                let name = display ?? String(command.prefix { $0 != " " })
                throw IMAPError.commandFailed(command: name, response: String(status))
            }
            if response.text.hasPrefix("*") { untagged.append(response) }
        }
    }

    /// Reads one response: a line, plus any literals it announces with {n}.
    func readResponse() async throws -> IMAPUntagged {
        var text = ""
        var literals: [Data] = []
        while true {
            let line = try await readLine()
            if let size = Self.literalSize(atEndOf: line) {
                text += String(line[..<line.lastIndex(of: "{")!])
                literals.append(try await readBytes(size))
                text += "{}"
            } else {
                text += line
                return IMAPUntagged(text: text, literals: literals)
            }
        }
    }

    /// "… BODY[] {1234}" → 1234 (also "{1234+}").
    static func literalSize(atEndOf line: String) -> Int? {
        guard line.hasSuffix("}"), let open = line.lastIndex(of: "{") else { return nil }
        return Int(line[line.index(after: open)..<line.index(before: line.endIndex)].filter(\.isNumber))
    }

    private func fill() async throws {
        let chunk = try await transport.receive()
        guard !chunk.isEmpty else { throw IMAPError.connectionClosed }
        buffer.append(chunk)
    }

    private func readLine() async throws -> String {
        while true {
            if let index = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                var lineData = buffer[buffer.startIndex..<index]
                if lineData.last == UInt8(ascii: "\r") { lineData = lineData.dropLast() }
                buffer = Data(buffer[buffer.index(after: index)...])
                return String(decoding: lineData, as: UTF8.self)
            }
            try await fill()
        }
    }

    private func readBytes(_ count: Int) async throws -> Data {
        while buffer.count < count { try await fill() }
        let bytes = Data(buffer.prefix(count))
        buffer = Data(buffer.dropFirst(count))
        return bytes
    }

    /// An IMAP quoted string.
    static func hasControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// A quoted string; control characters (which can't be quoted) are left out.
    static func quoted(_ value: String) -> String {
        let value = String(String.UnicodeScalarView(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
