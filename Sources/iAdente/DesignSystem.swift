import AppKit
import SwiftUI

// Neutral surfaces keep telemetry readable; mint marks active controls.
enum Palette {
    static let background = Color(red: 0.06, green: 0.08, blue: 0.095)
    static let sidebar = Color(red: 0.075, green: 0.095, blue: 0.11)
    static let surface = Color(red: 0.095, green: 0.12, blue: 0.135)
    static let surfaceRaised = Color(red: 0.135, green: 0.16, blue: 0.175)
    static let green = Color(red: 0.43, green: 0.88, blue: 0.70)
    static let accentSoft = green.opacity(0.10)
    static let blue = Color(red: 0.59, green: 0.74, blue: 0.82)
    static let orange = Color(red: 0.90, green: 0.72, blue: 0.49)
    static let purple = Color(red: 0.71, green: 0.71, blue: 0.80)
    static let pink = Color(red: 0.80, green: 0.67, blue: 0.74)
    static let red = Color(red: 0.93, green: 0.51, blue: 0.51)
    static let text = Color(red: 0.92, green: 0.95, blue: 0.96)
    static let secondary = Color(red: 0.75, green: 0.81, blue: 0.83)
    static let tertiary = Color(red: 0.64, green: 0.71, blue: 0.74)
    static let line = Color.white.opacity(0.08)
    static let gradient = LinearGradient(colors: [Color(red: 0.32, green: 0.72, blue: 0.59), green], startPoint: .leading, endPoint: .trailing)
}

enum DesignMetrics {
    static let cardRadius: CGFloat = 18
    static let controlRadius: CGFloat = 9
    static let cardPadding: CGFloat = 18
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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        ZStack {
            if settings.material == .solid || reduceTransparency {
                Palette.background
            } else if staticRendering {
                // A readable approximation for exported layout checks. Native
                // refraction is verified in a live AppKit window instead.
                switch settings.material {
                case .solid: Palette.background
                case .glass:
                    LinearGradient(colors: [Color(red: 0.16, green: 0.21, blue: 0.23), Palette.background], startPoint: .topLeading, endPoint: .bottomTrailing)
                case .soft: Color(red: 0.13, green: 0.16, blue: 0.18)
                }
            } else {
                // The window backdrop stays vibrancy, so individual glass
                // surfaces have one refractive layer and a desktop to sample.
                GlassBackground(style: settings.material)
                Palette.background.opacity(settings.material == .soft ? 0.52 : 0.32)
            }
        }.ignoresSafeArea()
    }
}

/// Shared surfaces keep the persisted `glass` preference compatible while
/// using native Liquid Glass on macOS 26 and later.
private struct LiquidSurfaceModifier: ViewModifier {
    let material: InterfaceMaterial
    let cornerRadius: CGFloat
    var prominence = false
    var interactive = false
    var tinted = false
    var visible = true
    @Environment(\.staticRendering) private var staticRendering
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }
    private var accent: Bool { prominence || tinted }

    @ViewBuilder func body(content: Content) -> some View {
        if !visible {
            content
        } else if material == .solid || reduceTransparency {
            content
                .background(interactive ? (tinted ? Palette.accentSoft : Palette.surfaceRaised) : Palette.surface, in: shape)
                .overlay(shape.stroke(accent ? Palette.green.opacity(0.20) : Palette.line, lineWidth: 1))
        } else if !staticRendering, material == .glass {
            if #available(macOS 26.0, *) {
                content.glassEffect(
                    .regular.tint(accent ? Palette.green.opacity(0.10) : Palette.background.opacity(0.30))
                        .interactive(interactive && isEnabled && !reduceMotion),
                    in: shape
                )
            } else {
                fallback(content: content)
            }
        } else {
            fallback(content: content)
        }
    }

    private func fallback(content: Content) -> some View {
        content
            .background {
                if !staticRendering {
                    shape.fill(material == .soft ? .thinMaterial : .ultraThinMaterial)
                }
                shape.fill(LinearGradient(
                    colors: [Palette.surfaceRaised.opacity(staticRendering ? 0.88 : 0.38), Palette.surface.opacity(staticRendering ? 0.94 : 0.24)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                if accent { shape.fill(Palette.green.opacity(0.055)) }
            }
            .overlay(shape.stroke(LinearGradient(
                colors: [.white.opacity(0.28), (accent ? Palette.green : .white).opacity(0.06), .white.opacity(0.13)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ), lineWidth: 0.8))
            .shadow(color: .black.opacity(interactive ? 0.06 : 0.13), radius: interactive ? 3 : 9, x: 0, y: interactive ? 2 : 5)
    }
}

extension View {
    func liquidSurface(settings: AppSettings, cornerRadius: CGFloat = DesignMetrics.cardRadius, prominence: Bool = false) -> some View {
        modifier(LiquidSurfaceModifier(material: settings.material, cornerRadius: cornerRadius, prominence: prominence))
    }

    func glassControl(settings: AppSettings, cornerRadius: CGFloat = DesignMetrics.controlRadius, tinted: Bool = false, visible: Bool = true) -> some View {
        modifier(LiquidSurfaceModifier(material: settings.material, cornerRadius: cornerRadius, interactive: true, tinted: tinted, visible: visible))
    }

    func liquidSurface(material: InterfaceMaterial, cornerRadius: CGFloat = DesignMetrics.cardRadius, prominence: Bool = false) -> some View {
        modifier(LiquidSurfaceModifier(material: material, cornerRadius: cornerRadius, prominence: prominence))
    }

    func glassControl(material: InterfaceMaterial, cornerRadius: CGFloat = DesignMetrics.controlRadius, tinted: Bool = false) -> some View {
        modifier(LiquidSurfaceModifier(material: material, cornerRadius: cornerRadius, interactive: true, tinted: tinted))
    }
}

struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 34
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.44, weight: .medium))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: size * 0.28))
            .overlay(RoundedRectangle(cornerRadius: size * 0.28).stroke(Palette.line, lineWidth: 1))
    }
}

struct BrandText: View {
    var size: CGFloat = 18
    var body: some View {
        Text(AppIdentity.displayName).font(.system(size: size, weight: .semibold))
            .foregroundStyle(Palette.text)
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    let color: Color
    @ViewBuilder let content: Content
    @Environment(\.interfaceMaterial) private var material
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                IconTile(symbol: symbol, color: color)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.text)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            Rectangle().fill(Palette.line).frame(height: 1)
            content
        }
        .padding(DesignMetrics.cardPadding)
        .liquidSurface(material: material)
    }
}

struct Panel<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.interfaceMaterial) private var material
    var body: some View {
        content.padding(DesignMetrics.cardPadding)
            .liquidSurface(material: material)
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
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.text)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if staticRendering {
                Capsule().fill(isOn ? Palette.green : Palette.surfaceRaised)
                    .frame(width: 34, height: 20)
                    .overlay(Capsule().stroke(isOn ? Color.clear : Palette.line, lineWidth: 1))
                    .overlay(alignment: isOn ? .trailing : .leading) {
                        Circle()
                            .fill(isOn ? Color.white : Palette.secondary)
                            .frame(width: 16, height: 16)
                            .padding(2)
                    }
                    .accessibilityLabel(title)
                    .accessibilityValue(isOn ? "开启" : "关闭")
            } else {
                Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(Palette.green).controlSize(.small)
                    .accessibilityLabel(title)
            }
        }.padding(.vertical, 3)
    }
}

struct SegmentedChoice<Value: Hashable>: View {
    let choices: [(Value, String)]
    @Binding var selection: Value
    @Environment(\.interfaceMaterial) private var material
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(choices.enumerated()), id: \.offset) { _, item in
                Button { selection = item.0 } label: {
                    Text(item.1).font(.system(size: 12, weight: selection == item.0 ? .semibold : .medium))
                        .foregroundStyle(selection == item.0 ? Palette.green : Palette.secondary)
                        .padding(.horizontal, 13).frame(height: 28)
                        .glassControl(material: material, cornerRadius: 6, tinted: selection == item.0)
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain).accessibilityAddTraits(selection == item.0 ? .isSelected : [])
            }
        }.padding(3)
            .background(Palette.background.opacity(material == .solid ? 0.60 : 0.15), in: RoundedRectangle(cornerRadius: DesignMetrics.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: DesignMetrics.controlRadius).stroke(Palette.line, lineWidth: 1))
    }
}

struct SmallButton: View {
    let title: String
    var symbol: String? = nil
    var color: Color = Palette.green
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.interfaceMaterial) private var material
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }.font(.system(size: 12, weight: .medium))
                .foregroundStyle(isEnabled ? color : Palette.tertiary)
                .padding(.horizontal, 12).frame(minHeight: 30)
                .glassControl(material: material)
                .contentShape(RoundedRectangle(cornerRadius: DesignMetrics.controlRadius))
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

private struct InterfaceMaterialKey: EnvironmentKey {
    static let defaultValue = InterfaceMaterial.glass
}

extension EnvironmentValues {
    var interfaceMaterial: InterfaceMaterial {
        get { self[InterfaceMaterialKey.self] }
        set { self[InterfaceMaterialKey.self] = newValue }
    }

    /// ImageRenderer cannot draw AppKit-backed controls. Normal app windows
    /// always use the default false value and retain the native controls.
    var staticRendering: Bool {
        get { self[StaticRenderingKey.self] }
        set { self[StaticRenderingKey.self] = newValue }
    }
}
