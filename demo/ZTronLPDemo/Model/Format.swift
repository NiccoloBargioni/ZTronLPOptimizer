// Number formatting for the log.

import Foundation

enum Format {
    /// A value as a person would write it: integers without decimals, six significant digits
    /// otherwise, scientific notation for very small or very large magnitudes.
    static func number(_ x: Double) -> String {
        guard x.isFinite else { return x.isNaN ? "NaN" : (x > 0 ? "∞" : "−∞") }
        let v = abs(x) < 1e-12 ? 0 : x
        let r = v.rounded()
        if abs(v - r) <= 1e-9 * max(1, abs(v)), abs(r) < 1e12 {
            return String(format: "%.0f", r == 0 ? 0 : r)
        }
        let a = abs(v)
        if a >= 1e-3 && a < 1e7 { return String(format: "%.6g", v) }
        return String(format: "%.2e", v)
    }

    /// Scientific notation with two significant digits, for residuals and errors.
    static func sci(_ x: Double) -> String {
        guard x.isFinite else { return number(x) }
        return x == 0 ? "0" : String(format: "%.1e", x)
    }

    /// An integer in superscript digits, for exponents: 10 → "¹⁰".
    static func superscriptDigits(_ n: Int) -> String {
        String(String(n).map { ch in ch == "-" ? "⁻" : Array("⁰¹²³⁴⁵⁶⁷⁸⁹")[ch.wholeNumberValue ?? 0] })
    }

    /// An integer in subscript digits, for indices: 6 → "₆".
    static func subscriptDigits(_ n: Int) -> String {
        String(String(n).map { ch in ch == "-" ? "₋" : Array("₀₁₂₃₄₅₆₇₈₉")[ch.wholeNumberValue ?? 0] })
    }

    /// Shortens the full-precision numbers that engine messages print, such as
    /// 295140301.1979848, to three significant digits. Numbers with fewer than eight digits stay.
    static func tidy(_ text: String) -> String {
        text.replacing(#/-?\d+\.\d+(?:[eE][-+]?\d+)?/#) { match in
            let literal = String(match.output)
            let mantissa = literal.prefix { $0 != "e" && $0 != "E" }
            guard mantissa.filter(\.isNumber).count >= 8, let value = Double(literal) else { return literal }
            return String(format: "%.3g", value)
        }
    }

    /// A count with thousands separators.
    static func count(_ n: Int) -> String {
        let digits = String(abs(n))
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return n < 0 ? "-" + out : out
    }

    /// "1 node", "3 nodes".
    static func plural(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(count(n)) \(n == 1 ? singular : (plural ?? singular + "s"))"
    }

    static func duration(_ seconds: Double) -> String {
        if seconds < 0.001 { return String(format: "%.0f µs", max(0, seconds) * 1e6) }
        if seconds < 1 { return String(format: "%.1f ms", seconds * 1e3) }
        return String(format: "%.2f s", seconds)
    }

    static func percent(_ fraction: Double) -> String {
        if fraction > 0 && fraction < 1e-4 { return "<0.01%" }
        return String(format: "%.2f%%", fraction * 100)
    }

    /// "name = value, …" for the entries `include` accepts, at most `limit` of them.
    static func assignments(
        names: (Int) -> String, values: [Double], limit: Int = 8, include: (Double) -> Bool = { abs($0) > 1e-9 }
    ) -> String? {
        let picked = values.indices.filter { include(values[$0]) }
        guard !picked.isEmpty else { return nil }
        var parts = picked.prefix(limit).map { "\(names($0)) = \(number(values[$0]))" }
        if picked.count > limit { parts.append("… \(picked.count - limit) more") }
        return parts.joined(separator: ", ")
    }
}
