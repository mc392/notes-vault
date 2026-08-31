import Foundation

/// One chunk of a longer document that looks like a single session.
public struct TextSection: Hashable, Sendable {
    /// The line the split happened on — usually the date line itself.
    public let heading: String?
    public let date: ParsedDate?
    public let text: String

    public init(heading: String?, date: ParsedDate?, text: String) {
        self.heading = heading
        self.date = date
        self.text = text
    }
}

/// Cutting a running document into sessions.
///
/// **Why this exists.** The most common way a counsellor's old notes are stored is not one
/// file per session — it is one Word document per client with five years of dated entries
/// in it. Importing that as a single note would technically work and would be useless: the
/// retention clock, the session list and the whole timeline all key off a session date.
///
/// The rule is deliberately narrow. A section starts at a line that *begins* with a date;
/// a date in the middle of a sentence ("we agreed to meet on 14/06/2026") is not a
/// boundary. Splitting too eagerly would tear a note in half, which is worse than not
/// splitting at all — so when fewer than two boundaries are found the document is left
/// whole and the counsellor is told why. Either way the review screen shows every proposed
/// note before anything is written.
public enum SessionSplitter {
    public static func split(
        _ text: String,
        dayFirst: Bool = true,
        timeZone: TimeZone = .current,
        now: Date = Date()
    ) -> [TextSection] {
        let normalised = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalised.components(separatedBy: "\n")

        var boundaries: [(index: Int, date: ParsedDate)] = []
        for (index, line) in lines.enumerated() {
            if let parsed = ImportDates.leading(in: line, dayFirst: dayFirst, timeZone: timeZone, now: now) {
                boundaries.append((index, parsed))
            }
        }

        guard boundaries.count >= 2 else {
            let whole = normalised.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !whole.isEmpty else { return [] }
            return [TextSection(
                heading: nil,
                date: ImportDates.first(in: normalised, dayFirst: dayFirst, timeZone: timeZone, now: now),
                text: whole
            )]
        }

        var sections: [TextSection] = []

        // Anything before the first date is usually a title block — the client's name, a
        // date of birth, a referral source. Short preambles ride along with the first
        // session so nothing is dropped; a long one becomes its own undated item, which
        // the review screen makes the counsellor deal with rather than guessing for them.
        let preamble = lines[0..<boundaries[0].index].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        var carried = ""
        if !preamble.isEmpty {
            if preamble.count <= 400 {
                carried = preamble + "\n\n"
            } else {
                sections.append(TextSection(heading: nil, date: nil, text: preamble))
            }
        }

        for (offset, boundary) in boundaries.enumerated() {
            let end = offset + 1 < boundaries.count ? boundaries[offset + 1].index : lines.count
            let body = lines[boundary.index..<end]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            sections.append(TextSection(
                heading: lines[boundary.index].trimmingCharacters(in: .whitespaces),
                date: boundary.date,
                text: carried + body
            ))
            carried = ""
        }
        return sections
    }
}

/// Evernote exports.
///
/// Worth handling because Evernote is where a lot of pre-2020 practice notes ended up, and
/// because its export is one self-contained `.enex` file — which is precisely the shape
/// that arrives by email and sits unencrypted in a Downloads folder for a year.
public enum EnexDocument {
    public struct Note: Hashable, Sendable {
        public let title: String?
        public let created: Date?
        public let body: String
    }

    public static func notes(from xml: String) -> [Note] {
        var notes: [Note] = []
        var title: String?
        var created: Date?
        var content = ""
        var capturing: String?
        var inNote = false

        XMLScanner.scan(xml) { tag in
            switch tag.name {
            case "note":
                if tag.isClosing {
                    let body = HTMLText.plainText(from: content)
                    if !body.isEmpty || title != nil {
                        notes.append(Note(title: title, created: created, body: body))
                    }
                    title = nil
                    created = nil
                    content = ""
                    inNote = false
                } else {
                    inNote = true
                    title = nil
                    created = nil
                    content = ""
                }
            case "title", "content", "created":
                capturing = tag.isClosing ? nil : tag.name
            default:
                break
            }
        } onText: { text in
            guard inNote, let capturing else { return }
            switch capturing {
            case "title":
                title = (title ?? "") + text
            case "content":
                content += text
            case "created":
                created = created ?? enexDate(text)
            default:
                break
            }
        }
        return notes
    }

    /// `20260614T083000Z`, which is Evernote's own stamp — always UTC.
    static func enexDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 16, trimmed.hasSuffix("Z") else { return nil }
        let digits = trimmed.dropLast().split(separator: "T")
        guard digits.count == 2, digits[0].count == 8, digits[1].count == 6 else { return nil }
        let day = digits[0], time = digits[1]
        guard let year = Int(day.prefix(4)),
              let month = Int(day.dropFirst(4).prefix(2)),
              let dayOfMonth = Int(day.dropFirst(6)),
              let hour = Int(time.prefix(2)),
              let minute = Int(time.dropFirst(2).prefix(2)) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = dayOfMonth
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)
    }
}
