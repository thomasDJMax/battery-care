import Foundation

/// The system's advertised values determine both input and write validation.
struct ChargeLimitOptions: Equatable {
    let values: [Int]

    init(_ values: [Int]) {
        self.values = Array(Set(values.filter { (1...100).contains($0) })).sorted()
    }

    var range: ClosedRange<Double> {
        let lower = Double(values.first ?? 80)
        let upper = Double(values.last ?? 100)
        return lower...max(lower + 1, upper)
    }

    func nearest(to value: Double) -> Int? {
        guard value.isFinite else { return nil }
        return values.min { abs(Double($0) - value) < abs(Double($1) - value) }
    }

    func adjacent(to value: Double, increasing: Bool) -> Int? {
        guard let selected = nearest(to: value), let index = values.firstIndex(of: selected) else { return nil }
        let next = increasing ? index + 1 : index - 1
        return values.indices.contains(next) ? values[next] : nil
    }

    var caption: String { values.map { "\($0)%" }.joined(separator: "、") }
}

struct ChargeLimitReadback {
    let known: Bool
    let enabled: Bool
    let limit: Int?

    func confirms(_ target: Int) -> Bool {
        // On this system setting 100% succeeds with MCL disabled: there is
        // no lower cap to enforce. Lower limits require active management.
        known && limit == target && (enabled || target == 100)
    }

    func confirmsRestore(limit original: Int, enabled originallyEnabled: Bool) -> Bool {
        known && (originallyEnabled ? enabled && limit == original : !enabled)
    }
}

func runChargeLimitOptionsChecks() {
    let options = ChargeLimitOptions([100, 80, 85, 90, 95, 80, -1, 0, 101])
    precondition(options.values == [80, 85, 90, 95, 100])
    precondition(options.nearest(to: 100) == 100)
    precondition(options.nearest(to: 99) == 100)
    precondition(options.nearest(to: 83) == 85)
    precondition(options.nearest(to: .nan) == nil)
    precondition(options.nearest(to: .infinity) == nil)
    precondition(options.adjacent(to: 95, increasing: true) == 100)
    precondition(options.adjacent(to: 100, increasing: true) == nil)
    precondition(options.adjacent(to: 80, increasing: false) == nil)
    let future = ChargeLimitOptions([60, 61, 62, 100])
    precondition(future.nearest(to: 61) == 61 && future.adjacent(to: 60, increasing: true) == 61)
    precondition(ChargeLimitOptions([]).nearest(to: 100) == nil)
    precondition(ChargeLimitOptions([80]).adjacent(to: 80, increasing: true) == nil)
    precondition(ChargeLimitReadback(known: true, enabled: false, limit: 100).confirms(100))
    precondition(!ChargeLimitReadback(known: true, enabled: false, limit: 80).confirms(80))
    precondition(!ChargeLimitReadback(known: false, enabled: true, limit: 100).confirms(100))
    precondition(!ChargeLimitReadback(known: true, enabled: true, limit: 80).confirms(100))
    precondition(!ChargeLimitReadback(known: false, enabled: false, limit: nil).confirmsRestore(limit: 100, enabled: false))
    precondition(!ChargeLimitReadback(known: true, enabled: false, limit: 80).confirmsRestore(limit: 80, enabled: true))
    precondition(ChargeLimitReadback(known: true, enabled: true, limit: 80).confirmsRestore(limit: 80, enabled: true))
    print("Charge limit selection checks passed: system values, 100% endpoint, adjacent values and invalid inputs.")
}
