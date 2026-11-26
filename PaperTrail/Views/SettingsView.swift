import PaperTrailKit
import SwiftData
import SwiftUI

/// Edit the owners and categories that make up the folder structure. Changes are saved
/// automatically a moment after the last edit, as long as the settings are valid.
struct SettingsView: View {
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(MailIntakeService.self) private var mail

    @State private var draft = ArchiveSettings.defaults
    @State private var loadedDraft = false
    /// The owner whose screen is open (also right after Add owner).
    @State private var openedOwner: Owner.ID?
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var modelContext
    @State private var errors: [String] = []
    @AppStorage(SpotlightIndexer.enabledKey) private var spotlightEnabled = true
    @Environment(AppLock.self) private var appLock
    @AppStorage(AppLock.enabledKey) private var lockEnabled = false
    @AppStorage(AppLock.timeoutKey) private var lockTimeout = AppLock.defaultTimeout.rawValue

    /// Turning the lock on or off asks for Face ID / Touch ID first: on, to be sure it works;
    /// off, so nobody else can switch it off.
    private var lockBinding: Binding<Bool> {
        Binding(get: { lockEnabled }, set: { wanted in
            Task {
                let reason = wanted ? String(localized: "Turn on the lock for Paper Trail.") : String(localized: "Turn off the lock for Paper Trail.")
                guard await appLock.authenticate(reason: reason) else { return }
                lockEnabled = wanted
                if !wanted { appLock.turnedOff() }
            }
        })
    }

    @ViewBuilder
    private var lockSection: some View {
        let method = AppLock.Method.current
        Section {
            Toggle(String(localized: "Require \(method.name)"), isOn: lockBinding)
                .disabled(!AppLock.isAvailable && !lockEnabled)
            if lockEnabled {
                Picker("Lock", selection: $lockTimeout) {
                    ForEach(LockTimeout.allCases) { Text(Self.label(for: $0)).tag($0.rawValue) }
                }
            }
        } header: {
            Text("Lock")
        } footer: {
            if AppLock.isAvailable {
                Text("Paper Trail asks for \(method.name) when it opens and after it has been away for the chosen time; your passcode works too. This device only. Files in iCloud Drive aren't locked, and Spotlight can still show document titles; turn Spotlight off below to hide them.")
            } else {
                Text("Set a passcode on this device to use the lock.")
            }
        }
    }

    private static func label(for timeout: LockTimeout) -> String {
        switch timeout {
        case .immediately: String(localized: "Immediately")
        case .oneMinute: String(localized: "After 1 minute")
        case .fiveMinutes: String(localized: "After 5 minutes")
        case .fifteenMinutes: String(localized: "After 15 minutes")
        case .oneHour: String(localized: "After 1 hour")
        }
    }

    var body: some View {
        Form {
            if !errors.isEmpty {
                Section {
                    ForEach(errors, id: \.self) { Text($0).foregroundStyle(.red) }
                } header: {
                    Label("Not saved", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                } footer: {
                    Text("Your changes stay here and are saved as soon as this is fixed.")
                }
            }

            Section {
                ForEach(draft.owners) { owner in
                    NavigationLink(value: OwnerRoute(id: owner.id)) {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(draft.color(ofOwner: owner.name).color)
                                .frame(width: 12, height: 12)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(owner.name.isEmpty ? String(localized: "New owner") : owner.name)
                                Text(OwnerSettingsView.summary(owner))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete { draft.owners.remove(atOffsets: $0) }
                .onMove { draft.owners.move(fromOffsets: $0, toOffset: $1) }
                Button("Add owner", systemImage: "plus") {
                    let owner = Owner(name: "")
                    draft.owners.append(owner)
                    openedOwner = owner.id
                }
            } header: {
                Text("Owners")
            } footer: {
                Text("A top-level folder for each person or company. Open an owner for paying bills, VAT and ledger codes.")
            }

            Section {
                ForEach($draft.categories) { $category in
                    HStack {
                        TextField("Category name", text: $category.name)
                        Text("Ledger codes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Toggle("Ledger codes", isOn: $category.usesLedgerCodes)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .accessibilityLabel(Text("Ledger codes for \(category.name)"))
                    }
                }
                .onDelete { draft.categories.remove(atOffsets: $0) }
                .onMove { draft.categories.move(fromOffsets: $0, toOffset: $1) }
                Button("Add category", systemImage: "plus") {
                    draft.categories.append(DocumentCategory(name: ""))
                }
            } header: {
                Text("Categories")
            } footer: {
                Text("Folders inside each owner's year folder. Switch on ledger codes for categories that are booked, such as invoices and receipts; the codes themselves are set per owner.")
            }

            Section {
                NavigationLink("Email") { MailSettingsView(mail: mail) }
            } footer: {
                Text("A dedicated mailbox; its emails go to Needs Review. Set it up on each device that should check it.")
            }

            lockSection

            Section {
                Toggle("Show Documents in Spotlight", isOn: $spotlightEnabled)
            } header: {
                Text("Search")
            } footer: {
                Text("Find documents by sender, description, amount or their text from the system search. The search index stays on this device; turn this off to remove it.")
            }

            BackupSection()

            Section {
                NavigationLink("Learned rules") { RulesView() }
            } footer: {
                Text("Paper Trail remembers owner and category for each sender you file.")
            }

            #if os(macOS)
            Section {
                NavigationLink("Clear All Documents…") { ResetArchiveView() }
            } header: {
                Text("Start over")
            } footer: {
                Text("Moves all documents to the Trash and clears the lists, for example after testing. Settings stay.")
            }
            #endif

            #if DEBUG
            Section {
                Button("Add Sample Documents", systemImage: "doc.badge.plus") {
                    Task {
                        do { try await SampleDocuments.add(using: model.filingService, context: modelContext) } catch { model.errorMessage = error.localizedDescription }
                    }
                }
            } header: {
                Text("Debug")
            } footer: {
                Text("Debug builds only. Files a few made-up documents to try the screens.")
            }
            #endif
        }
        .formStyle(.grouped)
        .keyboardDismissal()
        .navigationTitle("Settings")
        .navigationDestination(for: OwnerRoute.self) { route in ownerScreen(route.id) }
        .navigationDestination(item: $openedOwner) { id in ownerScreen(id) }
        // Load the draft once: onAppear also runs when coming back from a pushed screen (such as
        // the ledger code editor), and reloading then would throw away the edits made there.
        .onAppear {
            guard !loadedDraft else { return }
            draft = settingsStore.settings
            loadedDraft = true
        }
        // Settings changed on another device: take them over while nothing here is unsaved.
        .onChange(of: settingsStore.settings) { old, new in
            if Self.saveable(draft) == old { draft = new }
        }
        // Save a moment after the last change, so a half-typed name doesn't sync to other devices.
        .task(id: draft) {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            save()
        }
        // Leaving the screen (or opening a sub-screen) saves at once.
        .onDisappear { save() }
    }

    private func ownerScreen(_ id: Owner.ID) -> some View {
        OwnerSettingsView(owner: ownerBinding(id), automaticColor: automaticColor(of: id), errors: errors, save: save) {
            draft.owners.removeAll { $0.id == id }
            openedOwner = nil
            save()
        }
    }

    /// The owner with `id` in the draft; by ID, so a deleted owner can't crash an open screen.
    private func ownerBinding(_ id: Owner.ID) -> Binding<Owner> {
        Binding(get: { draft.owners.first { $0.id == id } ?? Owner(id: id, name: "") },
                set: { new in
                    if let index = draft.owners.firstIndex(where: { $0.id == id }) { draft.owners[index] = new }
                })
    }

    private func automaticColor(of id: Owner.ID) -> OwnerColor {
        .automatic(index: draft.owners.firstIndex { $0.id == id } ?? 0)
    }

    /// The draft as it is saved: IBAN and BIC without spaces, names trimmed, empty ledger code
    /// rows dropped. The draft itself keeps what was typed, so fields don't change while typing.
    private static func saveable(_ draft: ArchiveSettings) -> ArchiveSettings {
        var settings = draft
        for index in settings.owners.indices {
            settings.owners[index].payingAccount.iban = IBAN.normalize(settings.owners[index].payingAccount.iban)
            settings.owners[index].payingAccount.bic = IBAN.normalize(settings.owners[index].payingAccount.bic)
            settings.owners[index].payingAccount.name = settings.owners[index].payingAccount.name.trimmingCharacters(in: .whitespaces)
        }
        return settings.cleaningLedgerCodes()
    }

    private func save() {
        guard loadedDraft else { return }
        let settings = Self.saveable(draft)
        guard settings != settingsStore.settings else {
            errors = []
            return
        }
        errors = settingsStore.update(settings)
    }
}

/// A link to one owner's screen in Settings.
struct OwnerRoute: Hashable {
    let id: Owner.ID
}
