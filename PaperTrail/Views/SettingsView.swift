import PaperTrailKit
import SwiftUI

/// Edit the owners and categories that make up the folder structure.
struct SettingsView: View {
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ArchiveSettings.defaults
    @State private var errors: [String] = []

    var body: some View {
        Form {
            Section {
                ForEach($draft.owners) { $owner in
                    TextField("Owner name", text: $owner.name)
                }
                .onDelete { draft.owners.remove(atOffsets: $0) }
                .onMove { draft.owners.move(fromOffsets: $0, toOffset: $1) }
                Button("Add owner", systemImage: "plus") {
                    draft.owners.append(Owner(name: ""))
                }
            } header: {
                Text("Owners")
            } footer: {
                Text("Each owner gets a top-level folder. Renaming only affects documents filed afterwards.")
            }

            Section {
                ForEach($draft.categories) { $category in
                    TextField("Category name", text: $category.name)
                }
                .onDelete { draft.categories.remove(atOffsets: $0) }
                .onMove { draft.categories.move(fromOffsets: $0, toOffset: $1) }
                Button("Add category", systemImage: "plus") {
                    draft.categories.append(DocumentCategory(name: ""))
                }
            } header: {
                Text("Categories")
            } footer: {
                Text("Folders inside each owner's year folder.")
            }

            Section {
                ForEach($draft.owners) { $owner in
                    DisclosureGroup(owner.name.isEmpty ? String(localized: "New owner") : owner.name) {
                        Picker("Pay with", selection: $owner.paymentMethod) {
                            Text("QR code and copy buttons").tag(PaymentMethod.qrCode)
                            Text("SEPA batch file").tag(PaymentMethod.sepaFile)
                        }
                        TextField("Account name", text: $owner.payingAccount.name, prompt: Text("Name on the paying account"))
                        TextField("IBAN", text: $owner.payingAccount.iban, prompt: Text("Paying account"))
                            .autocorrectionDisabled()
                        TextField("BIC (optional)", text: $owner.payingAccount.bic)
                            .autocorrectionDisabled()
                    }
                }
            } header: {
                Text("Paying bills")
            } footer: {
                Text("Each owner gets its own To pay list in Reminders. A SEPA batch file needs the account it pays from; for QR codes the account is optional. Stored with your settings in iCloud.")
            }

            Section {
                NavigationLink("Learned rules") { RulesView() }
            } footer: {
                Text("Paper Trail remembers owner and category for each sender you file.")
            }

            if !errors.isEmpty {
                Section {
                    ForEach(errors, id: \.self) { Text($0).foregroundStyle(.red) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    for index in draft.owners.indices {
                        draft.owners[index].payingAccount.iban = IBAN.normalize(draft.owners[index].payingAccount.iban)
                        draft.owners[index].payingAccount.bic = IBAN.normalize(draft.owners[index].payingAccount.bic)
                        draft.owners[index].payingAccount.name = draft.owners[index].payingAccount.name.trimmingCharacters(in: .whitespaces)
                    }
                    errors = settingsStore.update(draft)
                    if errors.isEmpty { dismiss() }
                }
            }
        }
        .onAppear { draft = settingsStore.settings }
    }
}
