import Foundation

enum BatteryTemperature {
    /// Public IOPS temperatures are already in Celsius. Zero placeholders,
    /// non-finite values and implausible readings remain unavailable.
    static func celsius(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0, value < 90 else { return nil }
        return value
    }

    /// Registry battery temperatures use hundredths of a degree Celsius.
    /// They must not be interpreted as SMBus tenths-of-kelvin values.
    static func fromCentiCelsius(_ value: Double?) -> Double? {
        celsius(value.map { $0 / 100 })
    }
}
