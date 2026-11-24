import SwiftUI

/// Wraps a screen in its own NavigationStack when shown as a sheet, and not when it is embedded
/// in the app's navigation (a tab or the sidebar), where a stack already exists.
struct SheetNavigation<Content: View>: View {
    let embedded: Bool
    var path: Binding<[UUID]>?
    @ViewBuilder var content: Content

    var body: some View {
        if embedded {
            content
        } else if let path {
            NavigationStack(path: path) { content }
        } else {
            NavigationStack { content }
        }
    }
}
