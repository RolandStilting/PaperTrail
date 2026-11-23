import Foundation
import Testing
@testable import PaperTrailKit

/// Measures how well the on-device model extracts filing details from synthetic
/// Dutch and English documents. Opt-in because it is slow and its output can change
/// with OS updates:
///
///     PAPERTRAIL_MODEL_EVAL=1 swift test --filter ModelEvaluation
///
/// It reports scores instead of failing on individual wrong answers.
@Suite("ModelEvaluation", .enabled(if: ProcessInfo.processInfo.environment["PAPERTRAIL_MODEL_EVAL"] == "1"))
struct ModelEvaluationTests {
    struct Expected: Decodable {
        var file: String
        var senders: [String]
        var documentDate: String
        var category: String
        var isUnpaidBill: Bool
        var amount: Double
        var dueDate: String
        var iban: String
        var reference: String
    }

    static let fields = ["sender", "docDate", "category", "unpaid", "amount", "dueDate", "iban", "reference"]

    static func fixturesURL() throws -> URL {
        try #require(Bundle.module.url(forResource: "Fixtures/Extraction", withExtension: nil))
    }

    static func squash(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func score(_ got: ModelExtraction, _ want: Expected) -> [String: Bool] {
        [
            "sender": want.senders.map(squash).contains(squash(got.sender)),
            "docDate": got.documentDate.trimmingCharacters(in: .whitespaces) == want.documentDate,
            "category": got.category.caseInsensitiveCompare(want.category) == .orderedSame,
            "unpaid": got.isUnpaidBill == want.isUnpaidBill,
            "amount": abs(got.amount - want.amount) < 0.005,
            "dueDate": got.dueDate.trimmingCharacters(in: .whitespaces) == want.dueDate,
            "iban": squash(got.iban) == squash(want.iban),
            "reference": squash(got.reference) == squash(want.reference),
        ]
    }

    @Test func extractsFilingDetails() async throws {
        guard case .available = ModelExtractor.availability else {
            Issue.record("On-device model unavailable: \(ModelExtractor.availability)")
            return
        }
        let folder = try Self.fixturesURL()
        let expected = try JSONDecoder().decode([Expected].self, from: Data(contentsOf: folder.appending(path: "expected.json")))
        let extractor = ModelExtractor(categories: ArchiveSettings.defaults.categories.map(\.name))

        var totals = Dictionary(uniqueKeysWithValues: Self.fields.map { ($0, 0) })
        var report = ["| document | " + Self.fields.joined(separator: " | ") + " | seconds |",
                      "|---|" + Self.fields.map { _ in "---" }.joined(separator: "|") + "|---|"]
        var details: [String] = []

        for want in expected {
            let text = try String(contentsOf: folder.appending(path: "\(want.file).txt"), encoding: .utf8)
            let start = ContinuousClock.now
            let got: ModelExtraction
            do {
                got = try await extractor.extract(from: text)
            } catch {
                report.append("| \(want.file) | error: \(error) |")
                continue
            }
            let seconds = (ContinuousClock.now - start).components.seconds
            let scores = Self.score(got, want)
            for (field, ok) in scores where ok { totals[field, default: 0] += 1 }
            report.append("| \(want.file) | " + Self.fields.map { scores[$0]! ? "✓" : "✗" }.joined(separator: " | ") + " | \(seconds) |")
            details.append("\(want.file): sender=\(got.sender) | date=\(got.documentDate) | cat=\(got.category) | desc=\(got.description) | unpaid=\(got.isUnpaidBill) | amount=\(got.amount) | due=\(got.dueDate) | iban=\(got.iban) | ref=\(got.reference)")
        }
        report.append("| **total / \(expected.count)** | " + Self.fields.map { "\(totals[$0]!)" }.joined(separator: " | ") + " | |")

        print("\n=== Model extraction evaluation ===\n" + report.joined(separator: "\n") + "\n\n" + details.joined(separator: "\n") + "\n")
    }
}
