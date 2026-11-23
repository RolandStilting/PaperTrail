import PaperTrailKit
import SwiftUI

/// Edits the VAT lines of one document: rate, amount excluding VAT and VAT per line.
struct VATEditor: View {
    @Binding var vat: VATInfo

    var body: some View {
        ForEach($vat.lines.indices, id: \.self) { index in
            HStack {
                Picker("Rate", selection: $vat.lines[index].rate) {
                    ForEach(Self.rates(including: vat.lines[index].rate), id: \.self) { rate in
                        Text(Self.rateText(rate)).tag(rate)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 90)
                TextField("Excl. VAT", value: $vat.lines[index].base, format: .number.precision(.fractionLength(2)))
                TextField("VAT", value: $vat.lines[index].amount, format: .number.precision(.fractionLength(2)))
                Button("Remove", systemImage: "minus.circle") { vat.lines.remove(at: index) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
        }
        Button("Add VAT Line", systemImage: "plus.circle") { vat.lines.append(VATLine(rate: 21, amount: 0)) }
        Toggle("Foreign VAT (not in the Dutch return)", isOn: $vat.isForeign)
        Toggle("Reverse charge (BTW verlegd)", isOn: $vat.isReverseCharge)
    }

    static func rates(including rate: Double) -> [Double] {
        Array(Set([21, 9, 0, rate])).sorted(by: >)
    }

    static func rateText(_ rate: Double) -> String {
        rate == rate.rounded() ? "\(Int(rate)) %" : "\(rate) %"
    }
}
