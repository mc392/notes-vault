import Foundation

/// Formatting for note bodies, as Markdown.
///
/// The obvious way to add bold and subheadings is rich text — and it would break the
/// promise the whole product rests on. Principle 05 says a decrypted note is "a file the
/// counsellor can open in any text editor on any machine forever", which rules out an
/// attributed-string blob or an RTF container.
///
/// Markdown keeps that promise exactly. `**bold**` and `## Subheading` *are* plain text:
/// they open in TextEdit, they read sensibly to a human who has never heard of Markdown,
/// and a note written before this feature existed is already valid Markdown. So nothing in
/// the note format changes, no migration is needed, and the export stays as honest as it
/// was.
///
/// The logic lives here rather than in the editor view because it is the part worth
/// testing: which characters go where, and what happens when a counsellor presses bold
/// twice.
public enum NoteMarkdownStyle: String, CaseIterable, Sendable {
    case bold
    case italic
    case heading
    case bullet

    public var displayName: String {
        switch self {
        case .bold: return "Bold"
        case .italic: return "Italic"
        case .heading: return "Subheading"
        case .bullet: return "Bullet"
        }
    }

    /// SF Symbol used on the formatting bar.
    public var symbolName: String {
        switch self {
        case .bold: return "bold"
        case .italic: return "italic"
        case .heading: return "textformat.size"
        case .bullet: return "list.bullet"
        }
    }

    var isBlockStyle: Bool {
        switch self {
        case .bold, .italic: return false
        case .heading, .bullet: return true
        }
    }

    var inlineMarker: String {
        switch self {
        case .bold: return "**"
        case .italic: return "*"
        case .heading, .bullet: return ""
        }
    }

    var blockPrefix: String {
        switch self {
        case .heading: return "## "
        case .bullet: return "- "
        case .bold, .italic: return ""
        }
    }
}

/// The result of pressing a formatting button: the new text, and where the cursor or
/// selection should end up. Returning the selection matters — an editor that formats the
/// word and then dumps the caret at the end is worse than no button at all.
public struct MarkdownEdit: Equatable, Sendable {
    public let text: String
    /// UTF-16 offsets, to match `NSRange` on both platforms' text views.
    public let selectionStart: Int
    public let selectionLength: Int

    public init(text: String, selectionStart: Int, selectionLength: Int) {
        self.text = text
        self.selectionStart = selectionStart
        self.selectionLength = selectionLength
    }
}

public enum NoteMarkdown {

    /// Applies — or removes — a style over the selected range.
    ///
    /// Every style toggles. Pressing bold on text that is already bold takes the markers
    /// off, which is what the button appearing "on" has to mean.
    public static func apply(
        _ style: NoteMarkdownStyle,
        to text: String,
        selectionStart: Int,
        selectionLength: Int
    ) -> MarkdownEdit {
        let utf16Count = text.utf16.count
        let start = max(0, min(selectionStart, utf16Count))
        let length = max(0, min(selectionLength, utf16Count - start))

        if style.isBlockStyle {
            return applyBlock(style, to: text, start: start, length: length)
        }
        return applyInline(style, to: text, start: start, length: length)
    }

    // MARK: - Inline: bold and italic

    private static func applyInline(
        _ style: NoteMarkdownStyle,
        to text: String,
        start: Int,
        length: Int
    ) -> MarkdownEdit {
        let marker = style.inlineMarker
        let markerCount = marker.utf16.count

        guard let range = utf16Range(in: text, start: start, length: length) else {
            return MarkdownEdit(text: text, selectionStart: start, selectionLength: length)
        }
        let selected = String(text[range])

        // Already wrapped, markers inside the selection: **word** → word
        if length > 2 * markerCount,
           selected.hasPrefix(marker),
           selected.hasSuffix(marker),
           !isRepeatedMarkerOnly(selected, marker: marker) {
            let inner = String(selected.dropFirst(marker.count).dropLast(marker.count))
            var updated = text
            updated.replaceSubrange(range, with: inner)
            return MarkdownEdit(text: updated, selectionStart: start, selectionLength: inner.utf16.count)
        }

        // Already wrapped, markers just outside the selection: **|word|** → word
        if start >= markerCount,
           start + length + markerCount <= text.utf16.count,
           let outer = utf16Range(in: text, start: start - markerCount, length: length + 2 * markerCount) {
            let surrounding = String(text[outer])
            if surrounding.hasPrefix(marker), surrounding.hasSuffix(marker) {
                var updated = text
                updated.replaceSubrange(outer, with: selected)
                return MarkdownEdit(
                    text: updated,
                    selectionStart: start - markerCount,
                    selectionLength: selected.utf16.count
                )
            }
        }

        // Not wrapped yet. An empty selection drops the markers in and puts the caret
        // between them, so the counsellor can just start typing in bold.
        var updated = text
        updated.replaceSubrange(range, with: marker + selected + marker)
        if length == 0 {
            return MarkdownEdit(text: updated, selectionStart: start + markerCount, selectionLength: 0)
        }
        return MarkdownEdit(text: updated, selectionStart: start + markerCount, selectionLength: length)
    }

    /// Guards against treating `**` itself as a wrapped empty string.
    private static func isRepeatedMarkerOnly(_ selected: String, marker: String) -> Bool {
        selected == marker + marker
    }

    // MARK: - Block: subheading and bullets

    private static func applyBlock(
        _ style: NoteMarkdownStyle,
        to text: String,
        start: Int,
        length: Int
    ) -> MarkdownEdit {
        let prefix = style.blockPrefix
        let lines = splitKeepingEnds(text)

        // Which lines does the selection touch? A zero-length selection touches the line
        // the caret sits on.
        var offset = 0
        var touched: [Int] = []
        for (index, line) in lines.enumerated() {
            let lineLength = line.utf16.count
            let lineStart = offset
            let lineEnd = offset + lineLength
            let intersects = length == 0
                ? (start >= lineStart && start <= lineEnd)
                : (start < lineEnd && start + length > lineStart)
            if intersects { touched.append(index) }
            offset = lineEnd
        }
        if touched.isEmpty { touched = [max(0, lines.count - 1)] }

        // Toggle off only when every touched line already carries the prefix.
        let allPrefixed = touched.allSatisfy { index in
            contentOf(lines[index]).hasPrefix(prefix)
        }

        var updatedLines = lines
        var addedBefore = 0
        var addedWithin = 0

        for index in touched {
            let line = lines[index]
            let content = contentOf(line)
            let ending = String(line.dropFirst(content.count))
            let newContent: String
            let delta: Int

            if allPrefixed {
                newContent = String(content.dropFirst(prefix.count))
                delta = -prefix.utf16.count
            } else if content.hasPrefix(prefix) {
                newContent = content
                delta = 0
            } else {
                newContent = prefix + content
                delta = prefix.utf16.count
            }

            updatedLines[index] = newContent + ending

            // Track how the selection has to move: prefixes on earlier lines push it along,
            // prefixes on the lines it covers make it longer.
            let lineStart = offsetOfLine(index, in: lines)
            if lineStart < start {
                addedBefore += delta
            } else {
                addedWithin += delta
            }
        }

        let updated = updatedLines.joined()
        let newStart = max(0, start + addedBefore)
        let newLength = max(0, length + addedWithin)
        return MarkdownEdit(
            text: updated,
            selectionStart: min(newStart, updated.utf16.count),
            selectionLength: min(newLength, updated.utf16.count - min(newStart, updated.utf16.count))
        )
    }

    // MARK: - Helpers

    private static func offsetOfLine(_ index: Int, in lines: [String]) -> Int {
        lines.prefix(index).reduce(0) { $0 + $1.utf16.count }
    }

    /// The line without its trailing newline.
    private static func contentOf(_ line: String) -> String {
        line.hasSuffix("\n") ? String(line.dropLast()) : line
    }

    /// Splits into lines but keeps the newline on the end of each, so joining them back
    /// reproduces the original exactly.
    private static func splitKeepingEnds(_ text: String) -> [String] {
        guard !text.isEmpty else { return [""] }
        var lines: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "\n" {
                lines.append(current)
                current = ""
            }
        }
        if !current.isEmpty || text.hasSuffix("\n") == false {
            lines.append(current)
        }
        return lines.isEmpty ? [""] : lines
    }

    private static func utf16Range(in text: String, start: Int, length: Int) -> Range<String.Index>? {
        guard start >= 0, length >= 0, start + length <= text.utf16.count else { return nil }
        guard let lower = String.Index(utf16Offset: start, in: text) as String.Index?,
              let upper = String.Index(utf16Offset: start + length, in: text) as String.Index?,
              lower <= upper else { return nil }
        return lower..<upper
    }
}

// MARK: - Reading a note back

/// One piece of a note, ready to be drawn. Deliberately a small, closed set: this is a
/// clinical record with subheadings and emphasis, not a publishing system.
public enum NoteBlock: Equatable, Sendable, Identifiable {
    case heading(String)
    case bullet(String)
    case paragraph(String)
    case blank

    public var id: String {
        switch self {
        case let .heading(text): return "h:\(text)"
        case let .bullet(text): return "b:\(text)"
        case let .paragraph(text): return "p:\(text)"
        case .blank: return "blank:\(UUID().uuidString)"
        }
    }

    /// The text with its block marker removed. Inline markers are left alone, because the
    /// view renders those with `AttributedString`.
    public var content: String {
        switch self {
        case let .heading(text), let .bullet(text), let .paragraph(text): return text
        case .blank: return ""
        }
    }
}

public extension NoteMarkdown {
    /// Splits a note body into blocks for display. Anything it does not recognise stays a
    /// paragraph, so a note written entirely in plain prose renders exactly as typed.
    static func blocks(in body: String) -> [NoteBlock] {
        body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { return .blank }
                if trimmed.hasPrefix("### ") { return .heading(String(trimmed.dropFirst(4))) }
                if trimmed.hasPrefix("## ") { return .heading(String(trimmed.dropFirst(3))) }
                if trimmed.hasPrefix("# ") { return .heading(String(trimmed.dropFirst(2))) }
                if trimmed.hasPrefix("- ") { return .bullet(String(trimmed.dropFirst(2))) }
                if trimmed.hasPrefix("* ") { return .bullet(String(trimmed.dropFirst(2))) }
                return .paragraph(line)
            }
    }
}
