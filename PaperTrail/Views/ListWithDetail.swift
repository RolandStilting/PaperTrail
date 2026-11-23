import SwiftUI

/// Wide screens (Mac, iPad): a list with the selected item's details beside it, like Mail.
/// Narrow screens: just the list, whose rows open their item on their own.
struct ListWithDetail<ListContent: View, Detail: View>: View {
    /// From this width the details appear beside the list.
    var minimumWidth: CGFloat = 640
    @ViewBuilder var list: (_ split: Bool) -> ListContent
    @ViewBuilder var detail: () -> Detail

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= minimumWidth {
                HStack(spacing: 0) {
                    list(true)
                        .frame(width: min(420, max(290, geometry.size.width * 0.38)))
                    Divider()
                    detail()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                list(false)
            }
        }
    }
}

extension View {
    /// ↑ and ↓ move the selection through `ids` (in the order the list shows them).
    func arrowKeySelection<ID: Hashable>(_ selection: Binding<ID?>, in ids: [ID]) -> some View {
        func move(_ step: Int) -> KeyPress.Result {
            guard !ids.isEmpty else { return .ignored }
            guard let current = selection.wrappedValue, let index = ids.firstIndex(of: current) else {
                selection.wrappedValue = step > 0 ? ids.first : ids.last
                return .handled
            }
            let next = min(max(index + step, 0), ids.count - 1)
            guard next != index else { return .handled }
            selection.wrappedValue = ids[next]
            return .handled
        }
        return self
            .onKeyPress(.downArrow) { move(1) }
            .onKeyPress(.upArrow) { move(-1) }
    }
}
