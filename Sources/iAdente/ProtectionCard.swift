import SwiftUI

/// Displays system capabilities and binds only the app's reminder preference.
struct ProtectionCard: View {
    let state: ProtectionState
    @Binding var reminderEnabled: Bool
    let onReminderSettings: () -> Void
    let onChargeSettings: () -> Void
    let onNotificationSettings: () -> Void

    @Environment(\.staticRendering) private var staticRendering

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                header
                systemTemperatureRow
                reminderSection
                chargeLimitRow
                sleepChargingRow
                if state.reminderEnabled, let message = state.feedbackText {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "info.circle.fill").foregroundStyle(Palette.orange)
                        Text(message).foregroundStyle(Palette.text.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        settingsButton("通知设置", accessibilityLabel: "检查系统通知设置", action: onNotificationSettings)
                    }.font(.system(size: 10, weight: .medium))
                }
                Text("应用运行且 Mac 唤醒时监测")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 14, weight: .bold))
            Text("自动保护")
                .font(.system(size: 14, weight: .bold))
            Spacer(minLength: 0)
        }
        .foregroundStyle(Palette.text)
    }

    private var systemTemperatureRow: some View {
        HStack(spacing: 10) {
            IconTile(symbol: "thermometer.medium", color: Palette.orange, size: 28)
            rowText("系统温控", detail: state.hasBattery ? "macOS 管理" : "未检测到内置电池")
            Text(state.temperatureText)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(state.reminderIsWarning ? Palette.orange : (state.temperatureAvailable ? Palette.text : Palette.secondary))
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel(state.temperatureAvailable ? "电池实时温度 \(state.temperatureText)" : "暂无有效电池温度")
        }
        .frame(minHeight: 32)
    }

    private var reminderSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                IconTile(symbol: "bell.badge.fill", color: Palette.orange, size: 28)
                rowText("高温提醒", detail: "只提醒，不调整充电")
                reminderToggle
            }
            .frame(minHeight: 32)
            HStack(spacing: 8) {
                Text("提醒阈值 \(state.thresholdText)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(state.reminderStatusText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(reminderStatusColor)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                settingsButton("调整", accessibilityLabel: "调整高温提醒阈值", action: onReminderSettings)
            }
            .padding(.leading, 38)
            if state.reminderNeedsPermission {
                HStack(spacing: 8) {
                    Text("在系统设置中允许提醒通知")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    settingsButton("通知设置", accessibilityLabel: "打开系统通知设置", action: onNotificationSettings)
                }
                .padding(.leading, 38)
            }
        }
    }

    @ViewBuilder
    private var reminderToggle: some View {
        if staticRendering {
            Capsule()
                .fill(reminderEnabled ? Palette.orange : Color.white.opacity(0.17))
                .frame(width: 44, height: 20)
                .overlay(alignment: reminderEnabled ? .trailing : .leading) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.91))
                        .frame(width: 26, height: 16)
                        .padding(2)
                }
                .accessibilityLabel("高温提醒")
                .accessibilityValue(reminderEnabled ? "开启" : "关闭")
        } else {
            Toggle("高温提醒", isOn: $reminderEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Palette.orange)
                .controlSize(.small)
                .frame(width: 44, height: 20)
                .disabled(!state.hasBattery && !reminderEnabled)
                .accessibilityLabel("高温提醒")
                .accessibilityHint("达到提醒温度时发送通知，不改变系统充电设置")
        }
    }

    private var chargeLimitRow: some View {
        HStack(spacing: 10) {
            IconTile(symbol: "battery.75percent", color: chargeStatusColor, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("充电上限")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Palette.text)
                    Spacer(minLength: 0)
                    Text(state.capStatusText)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(chargeStatusColor)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !state.capDetailText.isEmpty && state.capDetailText != state.capStatusText {
                    Text(state.capDetailText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.text.opacity(0.70))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            settingsButton("设置", accessibilityLabel: "打开充电上限设置", action: onChargeSettings)
        }
        .frame(minHeight: 32)
    }

    private var sleepChargingRow: some View {
        HStack(spacing: 10) {
            IconTile(symbol: "moon.zzz.fill", color: Palette.purple, size: 28)
            rowText("睡眠充电", detail: "本应用不提供睡眠暂停控制")
            Text("系统决定")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(minHeight: 32)
    }

    private var reminderStatusColor: Color {
        if state.reminderNeedsPermission { return Palette.orange }
        if state.reminderIsWarning { return Palette.orange }
        return state.reminderEnabled && state.temperatureAvailable ? Palette.blue : Palette.secondary
    }

    private var chargeStatusColor: Color {
        if state.capIsTemporary { return Palette.orange }
        if !state.hasKnownChargeState { return Palette.secondary }
        return state.capIsActive ? Palette.green : Palette.secondary
    }

    private func rowText(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Palette.text)
            Text(detail)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Palette.text.opacity(0.70))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingsButton(_ title: String, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.blue)
                .padding(.horizontal, 10)
                .frame(minWidth: 44, minHeight: 32)
                .background(Palette.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7).stroke(Palette.blue.opacity(0.22), lineWidth: 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(accessibilityLabel)
    }
}
