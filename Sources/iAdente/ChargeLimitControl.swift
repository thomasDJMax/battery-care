import SwiftUI

/// Only an explicit drag completion or button click submits a system change.
struct ChargeLimitControl: View {
    @Binding var value: Double
    let limits: [Int]
    let isEnabled: Bool
    let onCommit: (Int) -> Void
    @Environment(\.staticRendering) private var staticRendering

    private var options: ChargeLimitOptions { ChargeLimitOptions(limits) }

    var body: some View {
        VStack(spacing: 9) {
            HStack(spacing: 10) {
                adjustmentButton(increasing: false)
                ChargeSlider(value: $value, limits: limits, onCommit: onCommit)
                    .disabled(!isEnabled || options.values.count < 2 || staticRendering)
                adjustmentButton(increasing: true)
            }
            HStack {
                Text(options.values.first.map { "\($0)%" } ?? "—")
                Spacer()
                Text(isEnabled ? "拖动松手即应用 · ± 逐档调整" : "当前不可调整")
                Spacer()
                Text(options.values.last.map { "\($0)%" } ?? "—")
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Palette.secondary)
        }
    }

    private func adjustmentButton(increasing: Bool) -> some View {
        let next = options.adjacent(to: value, increasing: increasing)
        return Button {
            guard let next else { return }
            value = Double(next)
            onCommit(next)
        } label: {
            Image(systemName: increasing ? "plus" : "minus")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Palette.green)
                .frame(width: 29, height: 29)
                .background(Color(red: 0.15, green: 0.18, blue: 0.19), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(ChargeAdjustmentButtonStyle())
        .opacity(isEnabled ? 1 : 0.45)
        .disabled(!isEnabled || next == nil || staticRendering)
        .help(next == nil ? (increasing ? "已达到系统最高上限" : "已达到系统最低上限") : "调整后立即应用")
        .accessibilityLabel(increasing ? "提高充电上限并应用" : "降低充电上限并应用")
    }
}

private struct ChargeAdjustmentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.75 : 1)
    }
}
