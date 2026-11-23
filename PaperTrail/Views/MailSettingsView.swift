#if os(macOS)
import PaperTrailKit
import ServiceManagement
import SwiftUI

/// The dedicated mailbox the Mac checks. The password goes to the Keychain only.
struct MailSettingsView: View {
    let mail: MailIntakeService

    @State private var draft = MailAccount()
    @State private var password = ""
    @State private var message: String?
    @State private var isTesting = false
    @State private var startsAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Toggle("Check this mailbox", isOn: $draft.isEnabled)
                TextField("Email address", text: $draft.address, prompt: Text("name@icloud.com"))
                    .textContentType(.emailAddress)
                    .onChange(of: draft.address) { _, address in
                        if draft.username.isEmpty || address.hasPrefix(draft.username) {
                            draft.username = MailAccount.iCloud(address: address).username
                        }
                    }
                TextField("User name", text: $draft.username)
                SecureField("App-specific password", text: $password, prompt: Text(mail.hasPassword ? "Saved – type to replace" : "xxxx-xxxx-xxxx-xxxx"))
            } header: {
                Text("Mailbox")
            } footer: {
                Text("For iCloud, create an app-specific password at account.apple.com → Sign-In and Security. It gives access to the whole mailbox; Paper Trail only reads the folder below and keeps the password in this Mac's Keychain. If signing in fails, try the full email address as user name.")
            }

            Section {
                TextField("Folder to file from", text: $draft.folder)
                TextField("Move filed emails to", text: $draft.processedFolder)
                Toggle("This whole account is only for Paper Trail", isOn: $draft.accountIsDedicated)
                ForEach(draft.validationErrors, id: \.self) { error in
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            } header: {
                Text("Folders")
            } footer: {
                Text("Every email in the first folder is filed and then moved to the second. With an iCloud alias, add a rule on icloud.com (Mail → Settings → Rules) that moves emails sent to the alias into \(MailAccount.defaultFolder). Paper Trail creates the second folder if needed, and never deletes email.")
            }

            Section("Server") {
                TextField("IMAP server", text: $draft.server)
                TextField("Port", value: $draft.port, format: .number.grouping(.never))
                Stepper("Check every \(draft.checkIntervalMinutes) minutes", value: $draft.checkIntervalMinutes, in: 1...120)
            }

            Section {
                Toggle("Open Paper Trail at login", isOn: $startsAtLogin)
                    .onChange(of: startsAtLogin) { _, on in setLoginItem(on) }
            } footer: {
                Text("The mailbox is checked while Paper Trail runs. It keeps running in the menu bar after you close its window.")
            }

            if let message {
                Section { Text(message) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Email")
        .toolbar {
            ToolbarItem {
                Button(isTesting ? "Testing…" : "Test Connection") { Task { await test() } }
                    .disabled(isTesting || !draft.isComplete)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save Email Settings") { save() }
                    .disabled(draft.isEnabled && !draft.validationErrors.isEmpty)
            }
        }
        .onAppear { draft = mail.account }
    }

    private func save() {
        draft.address = draft.address.trimmingCharacters(in: .whitespaces)
        draft.username = draft.username.trimmingCharacters(in: .whitespaces)
        draft.server = draft.server.trimmingCharacters(in: .whitespaces)
        draft.folder = draft.folder.trimmingCharacters(in: .whitespaces)
        draft.processedFolder = draft.processedFolder.trimmingCharacters(in: .whitespaces)
        do {
            try mail.update(draft, password: password)
            password = ""
            message = String(localized: "Saved.")
        } catch {
            message = error.localizedDescription
        }
    }

    private func test() async {
        isTesting = true
        defer { isTesting = false }
        let secret = password.isEmpty ? ((try? KeychainPasswordStore().password(account: mail.account.username)) ?? nil) ?? "" : password
        guard !secret.isEmpty else {
            message = String(localized: "Enter the app-specific password first.")
            return
        }
        message = await mail.testConnection(draft, password: secret) ?? String(localized: "Signed in to the mailbox. Save to start checking it.")
    }

    private func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            if SMAppService.mainApp.status == .requiresApproval {
                message = String(localized: "Allow Paper Trail in System Settings → General → Login Items.")
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch {
            message = String(localized: "Could not change the login item: \(error.localizedDescription)")
            startsAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

/// The menu-bar menu: mailbox status and quick actions.
struct MailMenu: View {
    let mail: MailIntakeService
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusText)
        ForEach(mail.problems.prefix(3), id: \.self) { Text($0).lineLimit(2) }
        Button("Check Mail Now") { Task { await mail.checkNow() } }
            .disabled(mail.status == .checking || !mail.account.isEnabled)
        Divider()
        Button("Open Paper Trail") {
            openWindow(id: "main")
            NSApplication.shared.activate()
        }
        Button("Quit Paper Trail") { NSApplication.shared.terminate(nil) }
    }

    private var statusText: String {
        switch mail.status {
        case .off: String(localized: "Email: off (Settings → Email)")
        case .idle: String(localized: "Email: waiting for the first check")
        case .checking: String(localized: "Email: checking…")
        case .checked(let date, let filed):
            String(localized: "Email: checked \(date.formatted(date: .omitted, time: .shortened)), \(filed) filed")
        case .failed(let reason): String(localized: "Email: \(reason)")
        }
    }
}
#endif
