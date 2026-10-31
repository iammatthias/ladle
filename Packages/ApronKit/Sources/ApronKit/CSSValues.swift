import Foundation

/// Reads the CSS values a theme sets, in the syntaxes people write by hand, without a CSS engine:
/// `var()` with its fallback, colors (`#hex`, `rgb()`, `hsl()`, `oklch()`, `oklab()`,
/// `light-dark()`, `color-mix(in srgb, …)`, `transparent`, the named colors), lengths in `px`,
/// durations, percentages, numbers, `cubic-bezier()` and a `0 Ypx Bpx <color>` shadow. Anything
/// else reads as nil, and the token keeps its default.
enum CSSValue {
    /// The value with each `var(--name[, fallback])` replaced by `lookup`'s value, itself read
    /// the same way; nil for a name with neither a value nor a fallback, or a cycle.
    static func substitute(_ value: String, depth: Int = 0, lookup: (String) -> String?) -> String? {
        guard depth < 24 else { return nil }
        var text = value
        while let start = text.range(of: "var(", options: .caseInsensitive) {
            guard let close = closingParen(in: text, from: start.upperBound) else { return nil }
            let inner = text[start.upperBound..<close]
            let parts = topLevel(inner, separator: ",", limit: 2)
            let name = parts[0].trimmingCharacters(in: .jsWhitespace)
            let replacement: String
            if let found = lookup(name), let resolved = substitute(found, depth: depth + 1, lookup: lookup) {
                replacement = resolved
            } else if parts.count == 2, let fallback = substitute(parts[1], depth: depth + 1, lookup: lookup) {
                replacement = fallback.trimmingCharacters(in: .jsWhitespace)
            } else {
                return nil
            }
            text.replaceSubrange(start.lowerBound...close, with: replacement)
        }
        return text.trimmingCharacters(in: .jsWhitespace)
    }

    // MARK: Colors

    static func color(_ value: String, mode: ColorMode) -> RGBA? {
        let text = value.trimmingCharacters(in: .jsWhitespace).lowercased()
        if text == "transparent" { return RGBA(0, 0) }
        if let named = namedColors[text] { return RGBA(named) }
        if text.hasPrefix("#") { return hex(String(text.dropFirst())) }
        guard let (function, args) = call(text) else { return nil }
        switch function {
        case "light-dark":
            guard args.count == 2 else { return nil }
            return color(mode == .light ? args[0] : args[1], mode: mode)
        case "rgb", "rgba": return rgb(args)
        case "hsl", "hsla": return hsl(args)
        case "oklch", "oklab": return oklab(args, polar: function == "oklch")
        case "color-mix": return colorMix(args, mode: mode)
        default: return nil
        }
    }

    private static func hex(_ digits: String) -> RGBA? {
        guard [3, 4, 6, 8].contains(digits.count), digits.allSatisfy(\.isHexDigit) else { return nil }
        let full = digits.count <= 4 ? digits.map { "\($0)\($0)" }.joined() : digits
        guard let n = UInt64(full, radix: 16) else { return nil }
        if full.count == 8 { return RGBA(UInt32(n >> 8), Double(n & 0xFF) / 255) }
        return RGBA(UInt32(n))
    }

    /// The components of a color function: comma-separated (legacy) or space-separated with an
    /// optional `/ alpha`, as the alpha last.
    private static func components(_ args: [String]) -> (values: [String], alpha: String?)? {
        if args.count > 1 { return args.count == 3 || args.count == 4 ? (Array(args.prefix(3)), args.count == 4 ? args[3] : nil) : nil }
        let halves = topLevel(Substring(args.first ?? ""), separator: "/", limit: 2)
        let values = halves[0].split(whereSeparator: \.isWhitespace).map(String.init)
        guard values.count == 3 else { return nil }
        return (values, halves.count == 2 ? halves[1].trimmingCharacters(in: .jsWhitespace) : nil)
    }

    private static func alphaValue(_ text: String?) -> Double? {
        guard let text else { return 1 }
        if text.hasSuffix("%") { return Double(text.dropLast()).map { $0 / 100 } }
        return Double(text)
    }

    private static func rgb(_ args: [String]) -> RGBA? {
        guard let (values, alphaText) = components(args), let alpha = alphaValue(alphaText) else { return nil }
        let channels = values.map { v -> Double? in v.hasSuffix("%") ? Double(v.dropLast()).map { $0 * 2.55 } : Double(v) }
        guard let r = channels[0], let g = channels[1], let b = channels[2] else { return nil }
        return RGBA(channels: (r, g, b), alpha: alpha)
    }

    private static func hue(_ text: String) -> Double? {
        if text.hasSuffix("deg") { return Double(text.dropLast(3)) }
        if text.hasSuffix("turn") { return Double(text.dropLast(4)).map { $0 * 360 } }
        if text.hasSuffix("rad") { return Double(text.dropLast(3)).map { $0 * 180 / .pi } }
        return Double(text)
    }

    private static func hsl(_ args: [String]) -> RGBA? {
        guard let (values, alphaText) = components(args), let alpha = alphaValue(alphaText),
              let h = hue(values[0]), let s = Double(values[1].replacingOccurrences(of: "%", with: "")),
              let l = Double(values[2].replacingOccurrences(of: "%", with: "")) else { return nil }
        let (sat, light) = (min(max(s, 0), 100) / 100, min(max(l, 0), 100) / 100)
        func f(_ n: Double) -> Double {
            let k = (n + h / 30).truncatingRemainder(dividingBy: 12)
            let k12 = k < 0 ? k + 12 : k
            return light - sat * min(light, 1 - light) * max(-1, min(k12 - 3, 9 - k12, 1))
        }
        return RGBA(channels: (f(0) * 255, f(8) * 255, f(4) * 255), alpha: alpha)
    }

    private static func oklab(_ args: [String], polar: Bool) -> RGBA? {
        guard let (values, alphaText) = components(args), let alpha = alphaValue(alphaText) else { return nil }
        func number(_ text: String, percentOf scale: Double) -> Double? {
            text.hasSuffix("%") ? Double(text.dropLast()).map { $0 / 100 * scale } : Double(text)
        }
        guard let l = number(values[0], percentOf: 1) else { return nil }
        let a: Double, b: Double
        if polar {
            guard let c = number(values[1], percentOf: 0.4), let h = hue(values[2]) else { return nil }
            (a, b) = (c * cos(h * .pi / 180), c * sin(h * .pi / 180))
        } else {
            guard let x = number(values[1], percentOf: 0.4), let y = number(values[2], percentOf: 0.4) else { return nil }
            (a, b) = (x, y)
        }
        let l_ = pow(l + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m_ = pow(l - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s_ = pow(l - 0.0894841775 * a - 1.2914855480 * b, 3)
        let linear = (
            4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_,
            -1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_,
            -0.0041960863 * l_ - 0.7034186147 * m_ + 1.7076147010 * s_
        )
        func encode(_ v: Double) -> Double {
            let c = min(max(v, 0), 1)
            return (c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055) * 255
        }
        return RGBA(channels: (encode(linear.0), encode(linear.1), encode(linear.2)), alpha: alpha)
    }

    /// `color-mix(in srgb, a [p%], b [q%])`, interpolated with premultiplied alpha as CSS does.
    private static func colorMix(_ args: [String], mode: ColorMode) -> RGBA? {
        guard args.count == 3, args[0].split(whereSeparator: \.isWhitespace) == ["in", "srgb"] else { return nil }
        func stop(_ text: String) -> (RGBA, Double?)? {
            let trimmed = text.trimmingCharacters(in: .jsWhitespace)
            if let match = trimmed.wholeMatch(of: /(.*\S)\s+(-?[\d.]+)%/), let color = color(String(match.1), mode: mode) {
                return (color, Double(match.2).map { $0 / 100 })
            }
            return color(trimmed, mode: mode).map { ($0, nil) }
        }
        guard let (a, p) = stop(args[1]), let (b, q) = stop(args[2]) else { return nil }
        var (pa, pb) = (p ?? q.map { 1 - $0 } ?? 0.5, q ?? p.map { 1 - $0 } ?? 0.5)
        let sum = pa + pb
        guard sum > 0 else { return nil }
        let scale = min(sum, 1)
        (pa, pb) = (pa / sum, pb / sum)
        let alpha = a.alpha * pa + b.alpha * pb
        guard alpha > 0 else { return RGBA(0, 0) }
        func channel(_ x: Double, _ y: Double) -> Double { (x * a.alpha * pa + y * b.alpha * pb) / alpha }
        return RGBA(channels: (channel(a.red, b.red), channel(a.green, b.green), channel(a.blue, b.blue)), alpha: alpha * scale)
    }

    // MARK: Other values

    static func length(_ value: String) -> Double? {
        let text = value.trimmingCharacters(in: .jsWhitespace).lowercased()
        if text == "0" { return 0 }
        return text.hasSuffix("px") ? Double(text.dropLast(2)) : nil
    }

    /// Seconds.
    static func duration(_ value: String) -> Double? {
        let text = value.trimmingCharacters(in: .jsWhitespace).lowercased()
        if text.hasSuffix("ms") { return Double(text.dropLast(2)).map { $0 / 1000 } }
        if text.hasSuffix("s") { return Double(text.dropLast()) }
        return text == "0" ? 0 : nil
    }

    /// A percentage as a fraction, or a plain number.
    static func fraction(_ value: String) -> Double? {
        let text = value.trimmingCharacters(in: .jsWhitespace)
        return text.hasSuffix("%") ? Double(text.dropLast()).map { $0 / 100 } : Double(text)
    }

    static func number(_ value: String) -> Double? {
        Double(value.trimmingCharacters(in: .jsWhitespace))
    }

    static func curve(_ value: String) -> Curve? {
        guard let (function, args) = call(value.trimmingCharacters(in: .jsWhitespace).lowercased()), function == "cubic-bezier",
              args.count == 4 else { return nil }
        let n = args.compactMap { Double($0) }
        return n.count == 4 ? Curve(n[0], n[1], n[2], n[3]) : nil
    }

    /// `0 <y>px <blur>px <color>`: the shadows tokens.css writes. A sideways offset or a spread
    /// has no place in `ShadowToken`.
    static func shadow(_ value: String, mode: ColorMode) -> ShadowToken? {
        let parts = topLevel(Substring(value.trimmingCharacters(in: .jsWhitespace)), separator: " ", limit: 4)
            .filter { !$0.isEmpty }
        guard parts.count == 4, length(parts[0]) == 0, let y = length(parts[1]), let blur = length(parts[2]),
              let color = color(parts[3], mode: mode) else { return nil }
        return ShadowToken(y: y, blur: blur, color: color)
    }

    // MARK: Syntax

    /// `name(args)` as the name and its top-level, comma-separated arguments.
    private static func call(_ text: String) -> (String, [String])? {
        guard let open = text.firstIndex(of: "("), text.hasSuffix(")"),
              closingParen(in: text, from: text.index(after: open)) == text.index(before: text.endIndex) else { return nil }
        let name = String(text[..<open]).trimmingCharacters(in: .jsWhitespace)
        let inner = text[text.index(after: open)..<text.index(before: text.endIndex)]
        return (name, topLevel(inner, separator: ",").map { $0.trimmingCharacters(in: .jsWhitespace) })
    }

    private static func closingParen(in text: String, from start: String.Index) -> String.Index? {
        var depth = 1
        var index = start
        while index < text.endIndex {
            switch text[index] {
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// Splits at `separator` outside brackets and quotes; the last part keeps the rest once
    /// `limit` parts are found.
    private static func topLevel(_ text: Substring, separator: Character, limit: Int = .max) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        for c in text {
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "(" {
                depth += 1
            } else if c == ")" {
                depth -= 1
            } else if c == separator, depth == 0, parts.count < limit - 1 {
                parts.append(current)
                current = ""
                continue
            }
            current.append(c)
        }
        parts.append(current)
        return parts
    }

    static func topLevel(_ text: String, separator: Character) -> [String] {
        topLevel(Substring(text), separator: separator)
    }

    // MARK: Named colors

    /// The CSS named colors (CSS Color 4, §6.1).
    static let namedColors: [String: UInt32] = {
        let table = """
        aliceblue f0f8ff antiquewhite faebd7 aqua 00ffff aquamarine 7fffd4 azure f0ffff beige f5f5dc bisque ffe4c4
        black 000000 blanchedalmond ffebcd blue 0000ff blueviolet 8a2be2 brown a52a2a burlywood deb887
        cadetblue 5f9ea0 chartreuse 7fff00 chocolate d2691e coral ff7f50 cornflowerblue 6495ed cornsilk fff8dc
        crimson dc143c cyan 00ffff darkblue 00008b darkcyan 008b8b darkgoldenrod b8860b darkgray a9a9a9
        darkgreen 006400 darkgrey a9a9a9 darkkhaki bdb76b darkmagenta 8b008b darkolivegreen 556b2f
        darkorange ff8c00 darkorchid 9932cc darkred 8b0000 darksalmon e9967a darkseagreen 8fbc8f
        darkslateblue 483d8b darkslategray 2f4f4f darkslategrey 2f4f4f darkturquoise 00ced1 darkviolet 9400d3
        deeppink ff1493 deepskyblue 00bfff dimgray 696969 dimgrey 696969 dodgerblue 1e90ff firebrick b22222
        floralwhite fffaf0 forestgreen 228b22 fuchsia ff00ff gainsboro dcdcdc ghostwhite f8f8ff gold ffd700
        goldenrod daa520 gray 808080 green 008000 greenyellow adff2f grey 808080 honeydew f0fff0 hotpink ff69b4
        indianred cd5c5c indigo 4b0082 ivory fffff0 khaki f0e68c lavender e6e6fa lavenderblush fff0f5
        lawngreen 7cfc00 lemonchiffon fffacd lightblue add8e6 lightcoral f08080 lightcyan e0ffff
        lightgoldenrodyellow fafad2 lightgray d3d3d3 lightgreen 90ee90 lightgrey d3d3d3 lightpink ffb6c1
        lightsalmon ffa07a lightseagreen 20b2aa lightskyblue 87cefa lightslategray 778899 lightslategrey 778899
        lightsteelblue b0c4de lightyellow ffffe0 lime 00ff00 limegreen 32cd32 linen faf0e6 magenta ff00ff
        maroon 800000 mediumaquamarine 66cdaa mediumblue 0000cd mediumorchid ba55d3 mediumpurple 9370db
        mediumseagreen 3cb371 mediumslateblue 7b68ee mediumspringgreen 00fa9a mediumturquoise 48d1cc
        mediumvioletred c71585 midnightblue 191970 mintcream f5fffa mistyrose ffe4e1 moccasin ffe4b5
        navajowhite ffdead navy 000080 oldlace fdf5e6 olive 808000 olivedrab 6b8e23 orange ffa500 orangered ff4500
        orchid da70d6 palegoldenrod eee8aa palegreen 98fb98 paleturquoise afeeee palevioletred db7093
        papayawhip ffefd5 peachpuff ffdab9 peru cd853f pink ffc0cb plum dda0dd powderblue b0e0e6 purple 800080
        rebeccapurple 663399 red ff0000 rosybrown bc8f8f royalblue 4169e1 saddlebrown 8b4513 salmon fa8072
        sandybrown f4a460 seagreen 2e8b57 seashell fff5ee sienna a0522d silver c0c0c0 skyblue 87ceeb
        slateblue 6a5acd slategray 708090 slategrey 708090 snow fffafa springgreen 00ff7f steelblue 4682b4
        tan d2b48c teal 008080 thistle d8bfd8 tomato ff6347 turquoise 40e0d0 violet ee82ee wheat f5deb3
        white ffffff whitesmoke f5f5f5 yellow ffff00 yellowgreen 9acd32
        """
        let words = table.split(whereSeparator: \.isWhitespace)
        return Dictionary(uniqueKeysWithValues: stride(from: 0, to: words.count, by: 2).map {
            (String(words[$0]), UInt32(words[$0 + 1], radix: 16)!)
        })
    }()
}
