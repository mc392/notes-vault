import Foundation

/// HTML to plain text.
///
/// Apple Notes, Evernote, Bear, Notion and every "export my notes" tool in between emit
/// HTML, so this is the single most-used parser in the importer. It is deliberately not a
/// real HTML parser: it keeps the line breaks a reader depends on, drops everything else,
/// and never executes or fetches anything. There is no WebKit in this path — an app that
/// makes no network connections should not hand a counsellor's clinical history to a
/// rendering engine that would happily go and fetch a tracking pixel out of it.
public enum HTMLText {
    private static let blockTags: Set<String> = [
        "p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6",
        "blockquote", "section", "article", "table", "ul", "ol", "pre", "hr"
    ]
    private static let droppedTags: Set<String> = ["script", "style", "head", "title", "meta", "link"]

    public static func plainText(from html: String) -> String {
        var output = ""
        var index = html.startIndex
        var skippingUntil: String?

        while index < html.endIndex {
            let character = html[index]
            guard character == "<" else {
                if skippingUntil == nil { output.append(character) }
                index = html.index(after: index)
                continue
            }
            guard let close = html[index...].firstIndex(of: ">") else {
                if skippingUntil == nil { output.append(contentsOf: html[index...]) }
                break
            }
            let tagBody = String(html[html.index(after: index)..<close])
            let name = tagName(tagBody)

            if let skipping = skippingUntil {
                if tagBody.hasPrefix("/"), name == skipping { skippingUntil = nil }
            } else if droppedTags.contains(name) {
                if !tagBody.hasSuffix("/") { skippingUntil = name }
            } else if blockTags.contains(name) {
                // One break per boundary, not one per tag. `</div><div>` is a boundary
                // between two lines, and treating the closing and opening tags as two
                // breaks double-spaces every note that Apple Notes ever exported. An
                // explicit `<br>` still always breaks, which is what preserves a blank
                // line written as `<div><br></div>`.
                if name == "br" || !output.hasSuffix("\n") { output.append("\n") }
                if name == "li", !tagBody.hasPrefix("/") { output.append("• ") }
            }
            index = html.index(after: close)
        }
        return tidy(decodeEntities(output))
    }

    private static func tagName(_ body: String) -> String {
        let withoutSlash = body.hasPrefix("/") ? String(body.dropFirst()) : body
        let name = withoutSlash.prefix { $0.isLetter || $0.isNumber }
        return name.lowercased()
    }

    /// The entities that actually turn up in exported notes, plus the numeric forms.
    /// A missing entity shows as `&hellip;` in a clinical record — ugly, but it is only
    /// ever wrong in the direction of showing more than it should, never less.
    public static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
            "nbsp": "\u{00A0}", "hellip": "…", "mdash": "—", "ndash": "–",
            "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
            "pound": "£", "eacute": "é", "bull": "•", "deg": "°", "trade": "™", "copy": "©"
        ]
        var output = ""
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "&",
                  let semicolon = text[index...].prefix(12).firstIndex(of: ";") else {
                output.append(text[index])
                index = text.index(after: index)
                continue
            }
            let body = String(text[text.index(after: index)..<semicolon])
            if body.hasPrefix("#") {
                let digits = body.dropFirst()
                let value: UInt32?
                if digits.hasPrefix("x") || digits.hasPrefix("X") {
                    value = UInt32(digits.dropFirst(), radix: 16)
                } else {
                    value = UInt32(digits)
                }
                if let value, let scalar = Unicode.Scalar(value) {
                    output.append(Character(scalar))
                    index = text.index(after: semicolon)
                    continue
                }
            } else if let replacement = named[body.lowercased()] {
                output.append(replacement)
                index = text.index(after: semicolon)
                continue
            }
            output.append(text[index])
            index = text.index(after: index)
        }
        return output
    }

    /// Collapses the run of blank lines that block tags leave behind, without flattening a
    /// deliberate paragraph break.
    static func tidy(_ text: String) -> String {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        var output: [String] = []
        var blanks = 0
        for line in lines {
            if line.isEmpty {
                blanks += 1
                if blanks <= 1 && !output.isEmpty { output.append("") }
            } else {
                blanks = 0
                output.append(line)
            }
        }
        while output.last?.isEmpty == true { output.removeLast() }
        return output.joined(separator: "\n")
    }
}

/// RTF to plain text.
///
/// This is the format a note dragged out of Apple Notes or TextEdit arrives in, and the
/// one inside an `.rtfd` bundle. `NSAttributedString` would do it in one line — on macOS.
/// On iOS the RTF initialiser routes through UIKit's text system and has to be called on
/// the main thread, which is the wrong place to decode four hundred notes; and either way
/// it would put this parser in the app layer where none of it could be tested by
/// `swift test`. So: control words, groups, and the escapes that carry real text.
public enum RTFText {
    /// Destinations whose contents are formatting rather than the note. `\*\anything` is
    /// also skipped by the parser itself, which is the format's own "ignorable" marker.
    private static let ignoredDestinations: Set<String> = [
        "fonttbl", "colortbl", "stylesheet", "info", "pict", "object", "generator",
        "listtable", "listoverridetable", "themedata", "colorschememapping", "datastore",
        "latentstyles", "xmlnstbl", "filetbl", "header", "footer", "footnote"
    ]

    public static func plainText(from rtf: String) -> String {
        var output = ""
        var index = rtf.startIndex
        /// One entry per open brace: true when everything inside it is being discarded.
        var skipStack: [Bool] = [false]
        /// How many characters of the next literal text to drop, from `\ucN` — the ANSI
        /// fallback that follows a `\u` escape and would otherwise appear as mojibake.
        var unicodeSkip = 1
        var pendingSkip = 0

        func skipping() -> Bool { skipStack.last ?? false }

        while index < rtf.endIndex {
            let character = rtf[index]

            switch character {
            case "{":
                skipStack.append(skipping())
                index = rtf.index(after: index)

            case "}":
                if skipStack.count > 1 { skipStack.removeLast() }
                index = rtf.index(after: index)

            case "\\":
                let next = rtf.index(after: index)
                guard next < rtf.endIndex else { index = next; continue }
                let marker = rtf[next]

                if marker == "\\" || marker == "{" || marker == "}" {
                    if !skipping() { output.append(marker) }
                    index = rtf.index(after: next)
                    continue
                }
                if marker == "*" {
                    // `\*\destination` — ignorable by definition.
                    skipStack[skipStack.count - 1] = true
                    index = rtf.index(after: next)
                    continue
                }
                if marker == "'" {
                    let start = rtf.index(after: next)
                    let end = rtf.index(start, offsetBy: 2, limitedBy: rtf.endIndex) ?? rtf.endIndex
                    if let value = UInt8(rtf[start..<end], radix: 16) {
                        if pendingSkip > 0 {
                            pendingSkip -= 1
                        } else if !skipping() {
                            // Windows-1252, which is what \'hh means in practice.
                            output.append(Character(windows1252[value] ?? Unicode.Scalar(value)))
                        }
                    }
                    index = end
                    continue
                }
                if !marker.isLetter {
                    index = rtf.index(after: next)
                    continue
                }

                // A control word: letters, then an optional signed number, then one
                // optional space that belongs to the word rather than the text.
                var cursor = next
                var word = ""
                while cursor < rtf.endIndex, rtf[cursor].isLetter {
                    word.append(rtf[cursor])
                    cursor = rtf.index(after: cursor)
                }
                var digits = ""
                if cursor < rtf.endIndex, rtf[cursor] == "-" {
                    digits.append("-")
                    cursor = rtf.index(after: cursor)
                }
                while cursor < rtf.endIndex, rtf[cursor].isNumber {
                    digits.append(rtf[cursor])
                    cursor = rtf.index(after: cursor)
                }
                if cursor < rtf.endIndex, rtf[cursor] == " " {
                    cursor = rtf.index(after: cursor)
                }
                let parameter = Int(digits)

                if ignoredDestinations.contains(word) {
                    skipStack[skipStack.count - 1] = true
                } else if word == "uc" {
                    unicodeSkip = parameter ?? 1
                } else if word == "u", let value = parameter {
                    // Negative values are the 16-bit code point written as a signed short.
                    let scalarValue = value < 0 ? UInt32(65536 + value) : UInt32(value)
                    if !skipping(), let scalar = Unicode.Scalar(scalarValue) {
                        output.append(Character(scalar))
                    }
                    pendingSkip = unicodeSkip
                } else if !skipping() {
                    switch word {
                    case "par", "line", "sect", "row":
                        output.append("\n")
                    case "tab":
                        output.append("\t")
                    case "emdash": output.append("—")
                    case "endash": output.append("–")
                    case "lquote": output.append("\u{2018}")
                    case "rquote": output.append("\u{2019}")
                    case "ldblquote": output.append("\u{201C}")
                    case "rdblquote": output.append("\u{201D}")
                    case "bullet": output.append("•")
                    default: break
                    }
                }
                index = cursor

            case "\n", "\r":
                index = rtf.index(after: index)

            default:
                if pendingSkip > 0 {
                    pendingSkip -= 1
                } else if !skipping() {
                    output.append(character)
                }
                index = rtf.index(after: index)
            }
        }
        return HTMLText.tidy(output)
    }

    /// The 0x80–0x9F range, where Windows-1252 differs from Latin-1 — smart quotes, the
    /// dash and the ellipsis, which is to say most of the punctuation in a typed note.
    private static let windows1252: [UInt8: Unicode.Scalar] = [
        0x80: "€", 0x82: "‚", 0x83: "ƒ", 0x84: "„", 0x85: "…", 0x86: "†", 0x87: "‡",
        0x88: "ˆ", 0x89: "‰", 0x8A: "Š", 0x8B: "‹", 0x8C: "Œ", 0x8E: "Ž",
        0x91: "\u{2018}", 0x92: "\u{2019}", 0x93: "\u{201C}", 0x94: "\u{201D}",
        0x95: "•", 0x96: "–", 0x97: "—", 0x98: "˜", 0x99: "™", 0x9A: "š",
        0x9B: "›", 0x9C: "œ", 0x9E: "ž", 0x9F: "Ÿ"
    ]
}
