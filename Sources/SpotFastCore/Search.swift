import Foundation

public enum Matcher {
    public static func score(_ name: String, query: String) -> Int? {
        let text = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let q = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard !q.isEmpty else { return 0 }
        if text == q { return 1000 }
        if text.hasPrefix(q) { return 800 - text.count }
        if text.contains(q) { return 600 - text.count }
        var cursor = text.startIndex
        var gaps = 0
        for char in q {
            guard cursor < text.endIndex, let next = text[cursor...].firstIndex(of: char) else { return nil }
            gaps += text.distance(from: cursor, to: next)
            cursor = text.index(after: next)
        }
        return 300 - gaps - text.count
    }
}

/// Bounded arithmetic parser. Never invokes a shell, JavaScript, or NSExpression.
public enum Calculator {
    public static func evaluate(_ input: String) -> Double? {
        guard input.count <= 256, input.contains(where: { "+-*/^%".contains($0) }) else { return nil }
        var parser = Parser(input)
        guard let value = try? parser.expression(), parser.atEnd, value.isFinite else { return nil }
        return value
    }
    private enum Invalid: Error { case expression }
    private struct Parser {
        var chars: [Character]
        var position = 0
        var depth = 0
        init(_ input: String) { chars = Array(input.filter { !$0.isWhitespace }) }
        var atEnd: Bool { position == chars.count }
        mutating func take(_ c: Character) -> Bool {
            guard position < chars.count, chars[position] == c else { return false }
            position += 1
            return true
        }
        mutating func expression() throws -> Double {
            var value = try product()
            while true {
                if take("+") { value += try product() }
                else if take("-") { value -= try product() }
                else { return value }
            }
        }
        mutating func product() throws -> Double {
            var value = try unary()
            while true {
                if take("*") { value *= try unary() }
                else if take("/") { value /= try unary() }
                else if take("%") { value = value.truncatingRemainder(dividingBy: try unary()) }
                else { return value }
            }
        }
        mutating func unary() throws -> Double {
            depth += 1
            defer { depth -= 1 }
            guard depth < 64 else { throw Invalid.expression }
            if take("+") { return try unary() }
            if take("-") { return -(try unary()) }
            var value = try primary()
            if take("^") { value = pow(value, try unary()) }
            return value
        }
        mutating func primary() throws -> Double {
            if take("(") {
                let value = try expression()
                guard take(")") else { throw Invalid.expression }
                return value
            }
            let start = position
            while position < chars.count, chars[position].isASCII,
                  chars[position].isNumber || chars[position] == "." { position += 1 }
            guard position > start, let value = Double(String(chars[start..<position])) else { throw Invalid.expression }
            return value
        }
    }
}

public enum Converter {
    private struct Unit { let category: String; let scale: Double; var offset: Double = 0 }
    private static let units: [String: Unit] = [
        "mm": Unit(category: "length", scale: 0.001), "cm": Unit(category: "length", scale: 0.01),
        "m": Unit(category: "length", scale: 1), "km": Unit(category: "length", scale: 1000),
        "in": Unit(category: "length", scale: 0.0254), "ft": Unit(category: "length", scale: 0.3048),
        "yd": Unit(category: "length", scale: 0.9144), "mi": Unit(category: "length", scale: 1609.344),
        "g": Unit(category: "mass", scale: 0.001), "kg": Unit(category: "mass", scale: 1),
        "lb": Unit(category: "mass", scale: 0.45359237), "oz": Unit(category: "mass", scale: 0.028349523125),
        "s": Unit(category: "time", scale: 1), "min": Unit(category: "time", scale: 60),
        "hr": Unit(category: "time", scale: 3600), "day": Unit(category: "time", scale: 86400),
        "c": Unit(category: "temperature", scale: 1, offset: 273.15),
        "f": Unit(category: "temperature", scale: 5 / 9, offset: 255.3722222222222),
        "k": Unit(category: "temperature", scale: 1),
        "b": Unit(category: "data", scale: 1), "kb": Unit(category: "data", scale: 1000),
        "mb": Unit(category: "data", scale: 1e6), "gb": Unit(category: "data", scale: 1e9),
        "kib": Unit(category: "data", scale: 1024), "mib": Unit(category: "data", scale: 1048576),
        "gib": Unit(category: "data", scale: 1073741824)
    ]
    public static func convert(_ input: String) -> String? {
        guard input.count <= 256 else { return nil }
        let parts = input.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard parts.count == 4, ["to", "in"].contains(parts[2]),
              let value = Double(parts[0]), value.isFinite,
              let source = units[parts[1]], let target = units[parts[3]],
              source.category == target.category else { return nil }
        let result = (value * source.scale + source.offset - target.offset) / target.scale
        guard result.isFinite else { return nil }
        return "\(String(format: "%.10g", result)) \(parts[3])"
    }
}
