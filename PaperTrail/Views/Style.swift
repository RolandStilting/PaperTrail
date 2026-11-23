import PaperTrailKit
import SwiftUI

/// The app's colours and symbols, in one place. Navy (the accent colour) and mint come from the
/// app icon; mint marks everything that is done.
extension Color {
    static let done = Color("DoneColor")
}

extension OwnerColor {
    var color: Color {
        switch self {
        case .blue: .blue
        case .teal: .teal
        case .green: .green
        case .orange: .orange
        case .red: .red
        case .pink: .pink
        case .purple: .purple
        case .gray: .gray
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .blue: "Blue"
        case .teal: "Teal"
        case .green: "Green"
        case .orange: "Orange"
        case .red: "Red"
        case .pink: "Pink"
        case .purple: "Purple"
        case .gray: "Gray"
        }
    }
}

enum CategoryStyle {
    /// A symbol for the default categories; others get a folder.
    static func symbol(for category: String) -> String {
        switch category.lowercased() {
        case "invoices", "facturen": "doc.text"
        case "receipts", "bonnen", "kassabonnen": "receipt"
        case "letters", "brieven": "envelope"
        case "contracts", "contracten": "signature"
        case "tax", "belasting", "belastingen": "building.columns"
        case "insurance", "verzekeringen", "verzekering": "shield"
        case "bank": "banknote"
        default: "folder"
        }
    }
}

/// A small coloured dot for an owner.
struct OwnerDot: View {
    let owner: String
    @Environment(SettingsStore.self) private var settingsStore

    var body: some View {
        Circle()
            .fill(settingsStore.settings.color(ofOwner: owner).color)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }
}

extension View {
    /// iPhone and iPad: swiping the form down hides the keyboard (number pads have no return key).
    func keyboardDismissal() -> some View {
        #if os(iOS)
        scrollDismissesKeyboard(.interactively)
        #else
        self
        #endif
    }
}

extension View {
    /// A pane beside a list leaves the window title to the list's screen.
    @ViewBuilder
    func titleUnlessEmbedded(_ embedded: Bool, _ title: String) -> some View {
        if embedded { self } else { navigationTitle(title) }
    }
}
