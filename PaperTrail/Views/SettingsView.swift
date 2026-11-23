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
                    errors = settingsStore.update(draft)
                    if errors.isEmpty { dismiss() }
                }
            }
        }
        .onAppear { draft = settingsStore.settings }
    }
}
