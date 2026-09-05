import SwiftUI
import NotesVaultCore

extension View {
    /// A sheet that is big enough to hold a form, on whatever it is being shown on.
    ///
    /// On macOS a sheet takes its size from its content, and a `Form` reports a very modest
    /// ideal width — so every sheet in this app opened as a cramped box with the date picker
    /// and the longer labels running off the edge. On iPad the system picks a fixed card
    /// that ignores how much screen there is: see `SheetSizedToTheScreen` below. On iPhone
    /// there is nothing to decide and this does nothing.
    ///
    /// Sizing them here rather than at each call site means a new sheet cannot be added
    /// without one.
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
        self.modifier(SheetSizedToTheScreen(minWidth: minWidth, minHeight: minHeight))
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

#if os(iOS)
/// Sheets that grow with the screen they are on.
///
/// On iPhone a sheet fills the width it is given and there is nothing to decide. On iPad
/// there is: the system's own default sizes a sheet to a fixed card, and the note editor —
/// a form, a date picker and a text view that somebody is going to write six paragraphs
/// into — arrived as the same narrow column on a 13-inch iPad as on an 11-inch one, with
/// most of the screen unused around it.
///
/// So the sheet is proposed a size taken from the space it is actually being presented in:
/// four fifths of the width, capped so a very large screen does not produce a line of text
/// too long to read comfortably, and never smaller than the width the form needs. It is
/// applied only where a screen is big enough for the question to arise; on a compact width
/// the system's full-width sheet is already the right answer.
///
/// `presentationSizing` is iOS 18. On iOS 17 this does nothing and sheets look as they did.
private struct SheetSizedToTheScreen: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let minWidth: CGFloat
    let minHeight: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), horizontalSizeClass == .regular {
            content.presentationSizing(
                ScreenRelativeSizing(minWidth: minWidth, minHeight: minHeight)
            )
        } else {
            content
        }
    }
}

@available(iOS 18.0, *)
private struct ScreenRelativeSizing: PresentationSizing {
    /// Past about this, a form stops gaining anything from being wider and its labels and
    /// values just drift further apart.
    private static let comfortableWidth: CGFloat = 900

    let minWidth: CGFloat
    let minHeight: CGFloat

    func proposedSize(for root: PresentationSizingRoot, context: PresentationSizingContext) -> ProposedViewSize {
        let available = context.containerSize
        let width = min(max(minWidth, available.width * 0.8), Self.comfortableWidth, available.width)
        let height = min(max(minHeight, available.height * 0.9), available.height)
        return ProposedViewSize(width: width, height: height)
    }
}
#endif

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

/// The type-back gesture used everywhere a recovery key is shown, on creation and on
/// reissue alike. Everyone ticks a box saying they wrote something down; not everyone can
/// type back something they never actually copied, and finding that out now costs a
/// minute, where finding it out years later costs every note they have.
struct RecoveryKeyConfirmation: View {
    let key: RecoveryKey
    @Binding var typedBack: String
    @Binding var showingKey: Bool
    @Binding var matches: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if showingKey {
                Text(key.formatted)
                    .font(.system(.title3, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                Text("Hidden while you type it back.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            Button(showingKey ? "Hide it and type it back" : "Show it again") {
                showingKey.toggle()
            }
            .font(.footnote)

            VStack(alignment: .leading, spacing: 8) {
                Text("Type it back to confirm you have it")
                    .font(.headline)
                TextField("XXXX-XXXX-XXXX-…", text: $typedBack)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .keyEntryStyle()
                if !typedBack.isEmpty {
                    Label(
                        matches ? "That matches." : "Not a match yet.",
                        systemImage: matches ? "checkmark.circle" : "circle.dashed"
                    )
                    .font(.footnote)
                    .foregroundStyle(matches ? Color.green : Color.secondary)
                }
            }
        }
        .onChange(of: typedBack) { _, _ in updateMatch() }
        .onAppear(perform: updateMatch)
    }

    private func updateMatch() {
        guard let typed = try? RecoveryKey(typed: typedBack) else {
            matches = false
            return
        }
        matches = typed.entropy == key.entropy
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

    /// A predicted session: with its time when that time means something, and without when
    /// it does not. A client GroundWork holds no appointment time for, with no notes yet to
    /// take one from, has a date and nothing more — printing the midnight the arithmetic
    /// produced would state an appointment time nobody ever set.
    static func session(_ session: PredictedSession) -> String {
        session.timeIsKnown ? dateTime(session.date) : date(session.date)
    }
}
