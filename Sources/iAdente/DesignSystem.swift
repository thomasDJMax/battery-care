import AppKit
import SwiftUI

// The two supplied Retina screenshots define this palette and component scale.
enum Palette {
    static let green = Color(red: 0.18, green: 0.84, blue: 0.50)
    static let blue = Color(red: 0.23, green: 0.56, blue: 0.98)
    static let orange = Color(red: 1.0, green: 0.59, blue: 0.18)
    static let purple = Color(red: 0.55, green: 0.42, blue: 0.98)
    static let pink = Color(red: 0.87, green: 0.29, blue: 0.85)
    static let red = Color(red: 1, green: 0.32, blue: 0.34)
    static let text = Color.white.opacity(0.90)
    static let secondary = Color.white.opacity(0.57)
    static let line = Color.white.opacity(0.11)
    static let gradient = LinearGradient(colors: [blue, Color(red: 0.15, green: 0.73, blue: 0.72), green], startPoint: .leading, endPoint: .trailing)
}

struct GlassBackground: NSViewRepresentable {
    var style: InterfaceMaterial
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.appearance = NSAppearance(named: .darkAqua)
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = style == .soft ? .hudWindow : .popover
        view.isHidden = style == .solid
    }
}

struct AppBackground: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.staticRendering) private var staticRendering
    var body: some View {
        ZStack {
            if staticRendering {
                Color(white: settings.material == .solid ? 0.19 : (settings.material == .soft ? 0.41 : 0.36))
            } else {
                Color(red: 0.19, green: 0.19, blue: 0.19)
                if settings.material != .solid {
                    GlassBackground(style: settings.material)
                    Color.white.opacity(settings.material == .soft ? 0.14 : 0.09)
                }
            }
        }.ignoresSafeArea()
    }
}

struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 34
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.47, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: size * 0.26))
            .overlay(RoundedRectangle(cornerRadius: size * 0.26).stroke(color.opacity(0.37), lineWidth: 1))
    }
}

struct BrandText: View {
    var size: CGFloat = 18
    var body: some View {
        Text(AppIdentity.displayName).font(.system(size: size, weight: .heavy, design: .rounded))
            .foregroundStyle(LinearGradient(colors: [Palette.blue, Palette.green, Palette.pink], startPoint: .leading, endPoint: .trailing))
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    let color: Color
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconTile(symbol: symbol, color: color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.text)
                    Text(subtitle).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.secondary)
                }
                Spacer(minLength: 0)
            }
            Rectangle().fill(Palette.line).frame(height: 1)
            content
        }
        .padding(15)
        .background(Color.black.opacity(0.27), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
    }
}

struct Panel<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content.padding(14)
            .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.13), lineWidth: 1))
    }
}

struct SettingRow: View {
    let symbol: String
    let color: Color
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    @Environment(\.staticRendering) private var staticRendering
    var body: some View {
        HStack(spacing: 11) {
            IconTile(symbol: symbol, color: color, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.text)
                if !subtitle.isEmpty { Text(subtitle).font(.system(size: 12)).foregroundStyle(Palette.secondary) }
            }
            Spacer()
            if staticRendering {
                Capsule().fill(isOn ? color : Color.white.opacity(0.17))
                    .frame(width: 44, height: 20)
                    .overlay(alignment: isOn ? .trailing : .leading) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.91))
                            .frame(width: 26, height: 16)
                            .padding(2)
                    }
                    .accessibilityLabel(title)
                    .accessibilityValue(isOn ? "开启" : "关闭")
            } else {
                Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(color).controlSize(.small)
                    .accessibilityLabel(title)
            }
        }.padding(.vertical, 1)
    }
}

struct SegmentedChoice<Value: Hashable>: View {
    let choices: [(Value, String)]
    @Binding var selection: Value
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(choices.enumerated()), id: \.offset) { _, item in
                Button { selection = item.0 } label: {
                    Text(item.1).font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(selection == item.0 ? Color.black : Palette.text)
                        .padding(.horizontal, 14).frame(height: 25)
                        .background(selection == item.0 ? Palette.green : .clear, in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain).accessibilityAddTraits(selection == item.0 ? .isSelected : [])
            }
        }.background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct SmallButton: View {
    let title: String
    var symbol: String? = nil
    var color: Color = Palette.green
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }.font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color).padding(.horizontal, 12).padding(.vertical, 7)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(color.opacity(0.2), lineWidth: 1))
        }.buttonStyle(.plain)
    }
}

extension Double {
    var wattsText: String { String(format: "%.2f W", self) }
}
extension Optional where Wrapped == Double {
    var wattsText: String { self.map { $0.wattsText } ?? "— W" }
}

private struct StaticRenderingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// ImageRenderer cannot draw AppKit-backed controls. Normal app windows
    /// always use the default false value and retain the native controls.
    var staticRendering: Bool {
        get { self[StaticRenderingKey.self] }
        set { self[StaticRenderingKey.self] = newValue }
    }
}
