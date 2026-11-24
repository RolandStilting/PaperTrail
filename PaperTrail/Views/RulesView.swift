import PaperTrailKit
import SwiftData
import SwiftUI

/// Lists the rules learned from filed documents. Deleting a rule takes effect at once;
/// filing a document from that sender again learns a new one.
struct RulesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FilingRuleRecord.senderName) private var rules: [FilingRuleRecord]
    @State private var errorMessage: String?

    var body: some View {
        List {
            if rules.isEmpty {
                ContentUnavailableView(
                    "No rules yet",
                    systemImage: "arrow.triangle.branch",
                    description: Text("When you file a document, Paper Trail remembers where documents from that sender go, and their ledger code.")
                )
            }
            ForEach(rules) { rule in
                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.senderName)
                        .font(.headline)
                    Text("\(rule.ownerName) › \(rule.categoryName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    let codes = rule.rule.ledgerCodes
                    if !codes.isEmpty {
                        Text(codes.map { "\($0.owner) › \($0.category): \($0.code)" }.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contextMenu {
                    Button("Delete Rule", systemImage: "trash", role: .destructive) { delete([rule]) }
                }
            }
            .onDelete { offsets in delete(offsets.map { rules[$0] }) }
        }
        .navigationTitle("Learned rules")
        .alert("Could not delete the rule", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func delete(_ records: [FilingRuleRecord]) {
        records.forEach(modelContext.delete)
        do {
            try modelContext.save()
        } catch {
            errorMessage = String(localized: "\(error.localizedDescription) Try again.")
        }
    }
}
