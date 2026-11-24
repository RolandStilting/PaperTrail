import PaperTrailKit
import SwiftUI

/// Settings section for ledger codes: one list per owner (its chart of accounts). Which
/// categories use them is switched in the Categories list. Edits go into the settings draft,
/// which Settings saves automatically.
struct LedgerCodesSection: View {
    @Binding var draft: ArchiveSettings

    var body: some View {
        Section {
            ForEach($draft.owners) { $owner in
                NavigationLink {
                    LedgerCodeListEditor(codes: $owner.ledgerCodes,
                                         title: String(localized: "Ledger codes \(owner.name)"))
                } label: {
                    let count = owner.ledgerCodes.filter { !$0.code.trimmingCharacters(in: .whitespaces).isEmpty }.count
                    LabeledContent(owner.name.isEmpty ? String(localized: "New owner") : owner.name,
                                   value: count == 0 ? String(localized: "None") : count.formatted())
                }
            }
        } header: {
            Text("Ledger codes")
        } footer: {
            Text("Optional. Each owner's ledger codes, as its administration books them. When filing, you pick a code; Paper Trail remembers it per sender and suggests one for new senders. Codes are in the exports, not in file names. Switch them on per category under Categories.")
        }
    }
}

/// One owner's codes: code and description, in the order shown when filing.
struct LedgerCodeListEditor: View {
    @Binding var codes: [LedgerCode]
    let title: String

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
    }
}
