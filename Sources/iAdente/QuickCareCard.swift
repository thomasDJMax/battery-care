import SwiftUI

/// A state-driven card. All system changes belong to the supplied callbacks.
struct QuickCareCard: View {
    let state: QuickCareState
    let feedback: String?
    let onPreset: (Int) -> Void
    let onTemporary: () -> Void
    let onDefault: () -> Void
    let onSystemSettings: () -> Void
    let onDismissFeedback: () -> Void

    @State private var showsFeatureNotes = false
    @Environment(\.interfaceMaterial) private var material

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                header
                VStack(spacing: 11) {
                    presetRow
                    Divider().overlay(Palette.line)
                    temporaryRow
                    Divider().overlay(Palette.line)
                    systemRow
                }
                if state.temporaryFull {
                    informationLine("调整上限或系统管理前，请先恢复原设置。", color: Palette.orange)
                }
                if !state.isSupported {
                    unsupportedControls
                }
                featureNotes
                if let feedback, !feedback.isEmpty {
                    feedbackBanner(feedback)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text("快捷养护")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.text)
            Spacer(minLength: 8)
            Text(state.statusText)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(statusColor)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var presetRow: some View {
        HStack(spacing: 12) {
            rowText("充电上限", subtitle: state.presetCaption)
            HStack(spacing: 6) {
                presetButton(80)
                presetButton(90)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .frame(minHeight: 34)
    }

    private func presetButton(_ limit: Int) -> some View {
        let enabled = state.canApplyPreset && !state.isPresetActive(limit)
        let active = state.isPresetActive(limit) && !state.temporaryFull
        return Button { onPreset(limit) } label: {
            HStack(spacing: 3) {
                if active {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                }
                Text("\(limit)%")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(active ? Palette.green : (enabled ? Palette.text : Palette.tertiary))
            .frame(width: 52, height: 30)
            .glassControl(material: material, cornerRadius: 8, tinted: active)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel("应用 \(limit)% 系统充电上限")
        .accessibilityValue(active ? "已应用" : (enabled ? "可应用" : "不可用"))
    }

    private var temporaryRow: some View {
        HStack(spacing: 12) {
            rowText("临时 100%", subtitle: state.temporarySubtitle)
            actionButton(
                state.temporaryButtonTitle,
                enabled: state.canToggleTemporary,
                color: state.temporaryFull ? Palette.orange : Palette.green,
                action: onTemporary
            )
        }
        .frame(minHeight: 34)
    }

    private var systemRow: some View {
        HStack(spacing: 12) {
            rowText("系统管理", subtitle: systemSubtitle)
            actionButton(
                usesSystemDefault ? "当前使用" : "恢复默认",
                enabled: state.canRestoreSystem && !state.temporaryFull,
                color: usesSystemDefault ? Palette.green : Palette.text,
                current: usesSystemDefault,
                action: onDefault
            )
        }
        .frame(minHeight: 34)
    }

    private var usesSystemDefault: Bool {
        state.hasBattery && state.isSupported && state.hasKnownState && !state.isEnabled && !state.temporaryFull
    }

    private var systemSubtitle: String {
        if state.temporaryFull { return "先恢复临时模式的原设置" }
        if !state.hasBattery { return "未检测到内置电池" }
        if !state.isSupported { return "请使用系统电池设置" }
        if !state.hasKnownState { return "系统状态尚未确定" }
        if usesSystemDefault { return "当前由 macOS 自动管理" }
        return "交由 macOS 自动管理"
    }

    private var statusColor: Color {
        if state.temporaryFull { return Palette.orange }
        if !state.hasBattery || !state.isSupported || !state.hasKnownState { return Palette.secondary }
        return usesSystemDefault ? Palette.secondary : Palette.green
    }

    private func rowText(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.text)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func actionButton(_ title: String, enabled: Bool, color: Color, current: Bool = false, action: @escaping () -> Void) -> some View {
        if current {
            HStack(spacing: 4) {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .medium))
            }.foregroundStyle(Palette.green)
                .padding(.horizontal, 9).frame(minWidth: 70, minHeight: 30)
                .liquidSurface(material: material, cornerRadius: 8, prominence: true)
                .accessibilityElement(children: .combine).accessibilityLabel("系统默认充电管理，当前使用")
        } else {
            Button(action: action) {
                Text(title).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(enabled ? color : Palette.tertiary)
                    .padding(.horizontal, 9).frame(minWidth: 70, minHeight: 30)
                    .glassControl(material: material, cornerRadius: 8)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!enabled)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var unsupportedControls: some View {
        HStack(spacing: 8) {
            Text(state.hasBattery ? "此 Mac 暂不支持程序内充电控制。" : "此 Mac 未检测到内置电池。")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            actionButton("系统电池设置", enabled: true, color: Palette.green, action: onSystemSettings)
        }
    }

    private var featureNotes: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button { showsFeatureNotes.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: showsFeatureNotes ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 10)
                    Text("功能说明").font(.system(size: 10, weight: .medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Palette.tertiary)
                .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(showsFeatureNotes ? "已展开" : "已收起")
            if showsFeatureNotes {
                VStack(alignment: .leading, spacing: 4) {
                    Text("暂停充电和主动放电暂不支持；电池校准由系统管理。")
                    Text("充电时机仍由 macOS 决定。")
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 16)
            }
        }
    }

    private func informationLine(_ text: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle").font(.system(size: 10)).foregroundStyle(color)
                .padding(.top, 1)
            Text(text).font(.system(size: 10, weight: .medium))
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func feedbackBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(Palette.green)
                .padding(.top, 2)
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismissFeedback) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Palette.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭养护操作提示")
        }
        .padding(10)
        .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9).stroke(Palette.line, lineWidth: 0.8)
        }
    }
}
