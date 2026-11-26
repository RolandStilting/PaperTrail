import PaperTrailKit
import SwiftUI

/// Everything about one owner: name and colour, paying bills, VAT and ledger codes. Opened
/// from the Owners list in Settings; changes go into the settings draft and are saved
/// automatically, like the rest of Settings.
struct OwnerSettingsView: View {
    @Binding var owner: Owner
    /// The colour shown when the owner has no choice of its own (automatic by position).
    let automaticColor: OwnerColor
    /// Why the settings can't be saved right now; shown at the top.
    let errors: [String]
    /// Saves the settings (when valid).
    let save: () -> Void
    let delete: () -> Void

    @State private var confirmingDelete = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            if !errors.isEmpty {
                Section {
                    ForEach(errors, id: \.self) { Text($0).foregroundStyle(.red) }
                } header: {
                    Label("Not saved", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            Section {
                TextField("Name", text: $owner.name, prompt: Text("e.g. Private or a company name"))
                Picker("Colour", selection: $owner.color) {
                    Label { Text("Automatic") } icon: { Image(systemName: "circle.fill").foregroundStyle(automaticColor.color) }
                        .tag(OwnerColor?.none)
                    ForEach(OwnerColor.allCases, id: \.self) { color in
                        Label { Text(color.title) } icon: { Image(systemName: "circle.fill").foregroundStyle(color.color) }
                            .tag(OwnerColor?.some(color))
                    }
                }
                Toggle("Personal (not a company)", isOn: $owner.isPersonal)
            } footer: {
                Text("The owner's top-level folder and colour in lists. Renaming only affects documents filed afterwards. Personal: the owner you file expenses under that a company pays back.")
            }

            Section {
                Picker("Pay with", selection: $owner.paymentMethod) {
                    Text("QR code and copy buttons").tag(PaymentMethod.qrCode)
                    Text("SEPA batch file").tag(PaymentMethod.sepaFile)
                }
                Toggle("Banking app scans standard QR codes", isOn: $owner.bankScansEPCQRCode)
                TextField("Account name", text: $owner.payingAccount.name, prompt: Text("Name on the paying account"))
                TextField("IBAN", text: $owner.payingAccount.iban, prompt: Text("Paying account"))
                    .autocorrectionDisabled()
                TextField("BIC (optional)", text: $owner.payingAccount.bic)
                    .autocorrectionDisabled()
            } header: {
                Text("Paying bills")
            } footer: {
                Text("Bills get a reminder in this owner's To pay list in Reminders. A SEPA batch file needs the account it pays from; for QR codes the account is optional. Some banking apps (such as Rabobank's) don't scan standard payment QR codes: turn that off, and Paper Trail shows only a QR code or pay link from the invoice itself.")
            }

            Section {
                Picker("VAT return", selection: $owner.vatPeriod) {
                    Text("None").tag(VATPeriodKind?.none)
                    Text("Monthly").tag(VATPeriodKind?.some(.month))
                    Text("Quarterly").tag(VATPeriodKind?.some(.quarter))
                    Text("Yearly").tag(VATPeriodKind?.some(.year))
                }
                if owner.vatPeriod != nil {
                    ForEach(VATLedgerCode.rates, id: \.self) { rate in
                        TextField(String(localized: "Input VAT ledger code \("\(Int(rate)) %")"), text: vatCode(rate), prompt: Text("Optional"))
                            .autocorrectionDisabled()
                    }
                }
            } header: {
                Text("VAT")
            } footer: {
                Text("With a VAT return, documents get VAT lines and the owner gets a VAT overview. The input VAT ledger codes go into the VAT, claim and index exports.")
            }

            Section {
                NavigationLink {
                    LedgerCodeListEditor(codes: $owner.ledgerCodes, title: String(localized: "Ledger codes \(owner.name)"), save: save)
                } label: {
                    LabeledContent("Ledger codes", value: Self.ledgerCount(owner))
                }
            } footer: {
                Text("Optional. The codes this owner's administration books on, offered when filing documents in categories with ledger codes. Paper Trail remembers the code per sender and suggests one for new senders.")
            }

            Section {
                Button("Delete Owner", systemImage: "trash", role: .destructive) { confirmingDelete = true }
            } footer: {
                Text("Filed documents and their folders stay where they are.")
            }
        }
        .formStyle(.grouped)
        .keyboardDismissal()
        .navigationTitle(owner.name.isEmpty ? String(localized: "New owner") : owner.name)
        .confirmationDialog("Delete \(owner.name.isEmpty ? String(localized: "this owner") : owner.name)?", isPresented: $confirmingDelete) {
            Button("Delete Owner", role: .destructive) {
                dismiss()
                delete()
            }
        } message: {
            Text("Its settings and ledger codes are removed. Filed documents and their folders stay where they are.")
        }
        // Saved a moment after the last change here too, and at once when leaving.
        .task(id: owner) {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            save()
        }
        .onDisappear(perform: save)
    }

    private func vatCode(_ rate: Double) -> Binding<String> {
        Binding(get: { owner.vatLedgerCodes.first { $0.rate == rate }?.code ?? "" },
                set: { owner.setVATLedgerCode($0, rate: rate) })
    }

    static func ledgerCount(_ owner: Owner) -> String {
        let count = owner.ledgerCodes.filter { !$0.code.trimmingCharacters(in: .whitespaces).isEmpty }.count
        return count == 0 ? String(localized: "None") : count.formatted()
    }

    /// One line under the owner's name in the list, e.g. "Company · VAT quarterly · Ledger codes: 12".
    static func summary(_ owner: Owner) -> String {
        var parts = [owner.isPersonal ? String(localized: "Personal") : String(localized: "Company")]
        switch owner.vatPeriod {
        case .month: parts.append(String(localized: "VAT monthly"))
        case .quarter: parts.append(String(localized: "VAT quarterly"))
        case .year: parts.append(String(localized: "VAT yearly"))
        case nil: break
        }
        if owner.paymentMethod == .sepaFile { parts.append(String(localized: "SEPA file")) }
        let count = owner.ledgerCodes.filter { !$0.code.trimmingCharacters(in: .whitespaces).isEmpty }.count
        if count > 0 { parts.append(String(localized: "Ledger codes: \(count)")) }
        return parts.joined(separator: " · ")
    }
}

/// One owner's codes: code and description, in the order shown when filing.
struct LedgerCodeListEditor: View {
    @Binding var codes: [LedgerCode]
    let title: String
    var save: () -> Void = {}

    var body: some View {
        Form {
            Section {
                ForEach($codes) { $code in
                    HStack {
                        TextField("Code", text: $code.code, prompt: Text("4300"))
                            .autocorrectionDisabled()
                            .frame(maxWidth: 110)
                        TextField("Description", text: $code.description, prompt: Text("e.g. Telephone and internet"))
                    }
                    .labelsHidden()
                }
                .onDelete { codes.remove(atOffsets: $0) }
                .onMove { codes.move(fromOffsets: $0, toOffset: $1) }
                Button("Add Code", systemImage: "plus") {
                    codes.append(LedgerCode(code: ""))
                }
            } footer: {
                Text("Each code once. Empty rows are ignored.")
            }
        }
        .formStyle(.grouped)
        .keyboardDismissal()
        .navigationTitle(title)
        .task(id: codes) {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            save()
        }
        .onDisappear(perform: save)
    }
}
