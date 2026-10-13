enum AppIdentity {
    static let displayName = "电池管家"
    static var brandSymbol: String {
        if #available(macOS 14.0, *) { return "battery.100percent.bolt" }
        return "battery.100.bolt"
    }
}
