import SwiftUI
import NotesVaultCore

extension View {
    /// A sheet that is big enough to hold a form.
    ///
    /// On iOS a sheet fills the screen and this does nothing. On macOS a sheet takes its
    /// size from its content, and a `Form` reports a very modest ideal width — so every
    /// sheet in this app opened as a cramped box with the date picker and the longer
    /// labels running off the edge. Sizing them here rather than at each call site means a
    /// new sheet cannot be added without one.
    @ViewBuilder
    func vaultSheet(minWidth: CGFloat = 560, minHeight: CGFloat = 520) -> some View {
        #if os(macOS)
        self.frame(
            minWidth: minWidth,
            idealWidth: minWidth,
            maxWidth: .infinity,
            minHeight: minHeight,
            idealHeight: minHeight,
            maxHeight: .infinity
        )
        #else
        self
        #endif
    }

    /// Entry fields for keys and client codes: upper case, no autocorrect.
    ///
    /// iOS will happily "correct" a client code into a word and capitalise the first letter
    /// of a recovery key group. Both produce a value that looks right and is wrong, which is
    /// the worst kind of input bug in an app where a wrong key reads as lost data.
    @ViewBuilder
    func keyEntryStyle() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }
}

/// The typed-confirmation gesture, used for every destructive action.
///
/// Compliance mapping row 6: destruction must be deliberate, not silent. The phrase to type
/// is the client's own code, so muscle memory from the last one does not carry over.
struct TypedConfirmation: View {
    let phrase: String
    let prompt: String
    @Binding var typed: String

    var isConfirmed: Bool { typed.trimmingCharacters(in: .whitespaces).uppercased() == phrase.uppercased() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(prompt).font(.subheadline)
            Text(phrase)
                .font(.system(.headline, design: .monospaced))
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            TextField("Type it here", text: $typed)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .keyEntryStyle()
        }
    }
}

struct StatusChip: View {
    let status: ClientStatus

    private var colour: Color {
        switch status {
        case .active: return .green
        case .paused: return .orange
        case .ended: return .secondary
        }
    }

    var body: some View {
        Text(status.displayName)
            .font(.caption2.weight(.medium))
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .background(colour.opacity(0.15), in: Capsule())
            .foregroundStyle(colour)
    }
}

struct RetentionChip: View {
    let state: RetentionAssessment.State

    private var label: String {
        switch state {
        case .notCounting: return "No clock"
        case .counting: return "In retention"
        case .dueSoon: return "Review soon"
        case .due: return "Review due"
        }
    }

    private var colour: Color {
        switch state {
        case .notCounting: return .secondary
        case .counting: return .blue
        case .dueSoon: return .orange
        case .due: return .red
        }
    }

    var body: some View {
        Text(label)
            .font(.caption2.weight(.medium))
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .background(colour.opacity(0.15), in: Capsule())
            .foregroundStyle(colour)
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

enum Formatted {
    static func date(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }

    static func dateTime(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateFormat = "d MMM yyyy, HH:mm"
        return formatter.string(from: date)
    }
}
