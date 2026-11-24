import PaperTrailKit
import SwiftUI

/// Settings section: per owner, optional ledger code lists for some categories. Edits go into
/// the settings draft and are kept with Save, like the rest of Settings.
struct LedgerCodesSection: View {
    @Binding var draft: ArchiveSettings

    var body: some View {
        Section {
            ForEach($draft.owners) { $owner in
                NavigationLink {
                    LedgerOwnerView(owner: $owner, categories: draft.categories)
                } label: {
                    LabeledContent(owner.name.isEmpty ? String(localized: "New owner") : owner.name,
                                   value: Self.summary(owner, categories: draft.categories))
                }
            }
        } header: {
            Text("Ledger codes")
        } footer: {
            Text("Optional. Add the ledger codes your administration books on for some categories, such as Invoices and Receipts. When filing, you then pick a code; Paper Trail remembers it per sender and suggests one for new senders. Codes are in the exports, not in file names.")
        }
    }

    /// "None", or "Invoices, Receipts".
    static func summary(_ owner: Owner, categories: [DocumentCategory]) -> String {
        let names = categories.filter { !owner.ledgerCodes(categoryID: $0.id).isEmpty }.map(\.name)
        return names.isEmpty ? String(localized: "None") : names.formatted(.list(type: .and))
    }
}

/// One owner's categories, each with its own list of codes.
struct LedgerOwnerView: View {
    @Binding var owner: Owner
    let categories: [DocumentCategory]

    var body: some View {
        Form {
            Section {
                ForEach(categories) { category in
                    NavigationLink {
                        LedgerCodeListEditor(codes: codes(for: category),
                                             title: String(localized: "\(owner.name) › \(category.name)"))
                    } label: {
                        let count = owner.ledgerCodes(categoryID: category.id).filter { !$0.code.isEmpty }.count
                        LabeledContent(category.name, value: count == 0 ? String(localized: "None") : count.formatted())
                    }
                }
            } footer: {
                Text("Categories without codes show no ledger code when filing.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(owner.name)
    }

    private func codes(for category: DocumentCategory) -> Binding<[LedgerCode]> {
        Binding(get: { owner.ledgerCodes(categoryID: category.id) },
                set: { owner.setLedgerCodes($0, categoryID: category.id) })
    }
}

/// The codes of one owner and category: code and description, in the order shown when filing.
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
                Text("Each code once. Empty rows are removed when you save the settings.")
            }
        }
        .formStyle(.grouped)
        .keyboardDismissal()
        .navigationTitle(title)
    }
}
