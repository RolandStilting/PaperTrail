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

#if os(iOS)
import UIKit
#endif

extension View {
    /// iPhone and iPad: a Done button above the keyboard, and swiping the form down hides the
    /// keyboard. Number pads have no return key, so without this the keyboard can't be closed.
    func keyboardDismissal() -> some View {
        #if os(iOS)
        self
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                    .fontWeight(.semibold)
                }
            }
        #else
        self
        #endif
    }
}
