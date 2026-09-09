import SwiftUI
import NotesVaultCore

#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The note body: the writing surface, and a bar of tools underneath it.
///
/// SwiftUI's own `TextEditor` did not expose its selection until well after the iOS 17 /
/// macOS 14 floor this app targets, and a formatting button that cannot see what is
/// selected is a formatting button that appends markers to the end of the note. So the text
/// view is wrapped by hand on both platforms. It is the only place in the app that reaches
/// below SwiftUI, and it does so for that one reason.
///
/// It deliberately has no frame of its own. The editor takes whatever height it is given and
/// scrolls inside it, so on a phone the writing area is everything between the session
/// details and the keyboard, rather than a fixed box that the keyboard then covers up. The
/// tool bar is the *last* thing in the stack for the same reason: when the keyboard pushes
/// the layout up, the bar rides on top of it and stays in reach.
///
/// What the buttons insert is Markdown — see `NoteMarkdown` for why that, and not rich text.
/// What the counsellor *sees* is the formatting itself: a subheading is drawn as one while
/// it is being typed, with its `##` faded back rather than hidden. Faded rather than hidden
/// because the characters are genuinely there — they are what makes a decrypted note open
/// as a formatted document in any Markdown-aware editor forever — and an editor that drew
/// text the file does not contain would be lying about the record.
struct NoteBodyEditor: View {
    @Binding var text: String
    /// True while the caret is in the note. The screen around this uses it to get out of the
    /// way — see `NoteEditorView`.
    @Binding var isWriting: Bool

    @State private var selection = NSRange(location: 0, length: 0)
    /// Reading the note as it will be read back, rather than as it is being written. The
    /// live styling is enough almost always; this is for the moment before saving when
    /// somebody wants to see the finished thing.
    @State private var previewing = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if previewing {
                    preview
                } else {
                    writingSurface
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            EditorBar(
                previewing: $previewing,
                wordCount: text.wordCount,
                isWriting: isWriting
            ) { style in
                let edit = NoteMarkdown.apply(
                    style,
                    to: text,
                    selectionStart: selection.location,
                    selectionLength: selection.length
                )
                text = edit.text
                selection = NSRange(location: edit.selectionStart, length: edit.selectionLength)
            }
        }
        .background(.background)
    }

    private var writingSurface: some View {
        SelectableTextView(text: $text, selection: $selection, isEditing: $isWriting)
            // A prompt rather than a heading: it disappears the moment there is a note, and
            // it sits exactly where the first character will, so nothing moves when it goes.
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Start writing…")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, EditorMetrics.textInset)
                        .padding(.top, EditorMetrics.textInset)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }

    private var preview: some View {
        ScrollView {
            Group {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Nothing written yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    NoteBodyText(body: text)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EditorMetrics.textInset)
        }
    }
}

/// The margins the writing surface uses, in one place, because the placeholder has to line
/// up with the first character of the note to the point.
enum EditorMetrics {
    static let textInset: CGFloat = 16
}

/// The bar under the note: formatting on the left, how the note is doing on the right.
///
/// It is part of the layout rather than floating over it, so when the keyboard comes up the
/// whole stack shortens and this ends up sitting directly on top of the keyboard — which is
/// where a formatting bar is actually useful.
private struct EditorBar: View {
    @Binding var previewing: Bool
    let wordCount: Int
    let isWriting: Bool
    let apply: (NoteMarkdownStyle) -> Void

    private var wordsLabel: String {
        wordCount == 1 ? "1 word" : "\(wordCount) words"
    }

    /// Only iOS has a keyboard to put away, and only while there is one up.
    private var showsKeyboardDismiss: Bool {
        #if os(iOS)
        return isWriting
        #else
        return false
        #endif
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(NoteMarkdownStyle.allCases, id: \.self) { style in
                Button {
                    apply(style)
                } label: {
                    Image(systemName: style.symbolName)
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 40, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(style.displayName)
                .accessibilityLabel(style.displayName)
                // Nothing to format while the preview is up, and a button that silently
                // did nothing would read as broken.
                .disabled(previewing)
            }

            Spacer(minLength: 8)

            Text(wordsLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.trailing, 4)
                .accessibilityLabel("\(wordCount) words written")

            Toggle(isOn: $previewing) {
                Image(systemName: previewing ? "eye.fill" : "eye")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 40, height: 34)
                    .contentShape(Rectangle())
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .help("Preview")
            .accessibilityLabel("Preview")

            if showsKeyboardDismiss {
                Button {
                    dismissKeyboard()
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 40, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Hide the keyboard")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.bar)
    }
}

/// Resigns whatever is first responder. There is no SwiftUI spelling of this that works for
/// a text view wrapped from UIKit, and the note editor needs one because Save is at the top
/// of the screen and the keyboard covers the bottom of it.
private func dismissKeyboard() {
    #if os(iOS)
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    #endif
}

// MARK: - Drawing the formatting

#if os(iOS)
private typealias PlatformFont = UIFont
private typealias PlatformColor = UIColor
#else
private typealias PlatformFont = NSFont
private typealias PlatformColor = NSColor
#endif

/// Paints a note's Markdown onto the text the counsellor is typing.
///
/// Attributes only. Not one character is added, removed or replaced — `NoteMarkdown.styleRuns`
/// says which stretches of the text are what, and this turns each of those into a font and a
/// colour. The note in the box, the note in the draft and the note on disk stay the same
/// string throughout, which is the whole reason the formatting is Markdown in the first
/// place.
private enum NoteTextStyling {

    /// The body font at the reader's current text size. Read fresh each time rather than
    /// held, because Dynamic Type can change under a screen that is already open.
    static var bodyFont: PlatformFont {
        #if os(iOS)
        return UIFont.preferredFont(forTextStyle: .body)
        #else
        return NSFont.preferredFont(forTextStyle: .body)
        #endif
    }

    /// Air between the lines and between the paragraphs. A clinical note is read back under
    /// time pressure, sometimes years later, and set solid it is much harder work than it
    /// needs to be.
    static var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.paragraphSpacing = 7
        return style
    }

    static func baseAttributes(_ base: PlatformFont) -> [NSAttributedString.Key: Any] {
        #if os(iOS)
        return [.font: base, .foregroundColor: PlatformColor.label, .paragraphStyle: paragraphStyle]
        #else
        return [.font: base, .foregroundColor: PlatformColor.labelColor, .paragraphStyle: paragraphStyle]
        #endif
    }

    /// Redraws the whole body. Notes are a few thousand characters at most and this runs on
    /// a keystroke, which is well within what the text system does anyway to lay one out.
    static func apply(to storage: NSTextStorage, base: PlatformFont) {
        let text = storage.string
        let full = NSRange(location: 0, length: (text as NSString).length)

        storage.beginEditing()
        storage.setAttributes(baseAttributes(base), range: full)
        for run in NoteMarkdown.styleRuns(in: text) {
            let range = NSRange(location: run.start, length: run.length)
            // Belt and braces: the runs are computed from this very string, but a range
            // past the end of the storage raises rather than misdraws.
            guard NSMaxRange(range) <= full.length else { continue }
            storage.addAttributes(attributes(for: run.appearance, base: base), range: range)
        }
        storage.endEditing()
    }

    private static func attributes(
        for appearance: NoteMarkdownAppearance,
        base: PlatformFont
    ) -> [NSAttributedString.Key: Any] {
        [.font: font(for: appearance, base: base), .foregroundColor: colour(for: appearance)]
    }

    private static func colour(for appearance: NoteMarkdownAppearance) -> PlatformColor {
        #if os(iOS)
        return appearance.contains(.marker) ? PlatformColor.tertiaryLabel : PlatformColor.label
        #else
        return appearance.contains(.marker) ? PlatformColor.tertiaryLabelColor : PlatformColor.labelColor
        #endif
    }

    /// Markers keep the body size even on a heading line, so `## ` shrinks back out of the
    /// way while the heading itself grows.
    private static func font(for appearance: NoteMarkdownAppearance, base: PlatformFont) -> PlatformFont {
        let isHeading = appearance.contains(.heading) && !appearance.contains(.marker)
        let size = isHeading ? base.pointSize * 1.22 : base.pointSize
        let wantsBold = isHeading || appearance.contains(.bold)
        let wantsItalic = appearance.contains(.italic)

        #if os(iOS)
        var traits: UIFontDescriptor.SymbolicTraits = []
        if wantsBold { traits.insert(.traitBold) }
        if wantsItalic { traits.insert(.traitItalic) }
        guard !traits.isEmpty else { return base.withSize(size) }
        guard let descriptor = base.fontDescriptor.withSymbolicTraits(traits) else { return base.withSize(size) }
        return UIFont(descriptor: descriptor, size: size)
        #else
        var traits: NSFontDescriptor.SymbolicTraits = []
        if wantsBold { traits.insert(.bold) }
        if wantsItalic { traits.insert(.italic) }
        guard !traits.isEmpty else { return NSFont(descriptor: base.fontDescriptor, size: size) ?? base }
        let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: size) ?? base
        #endif
    }
}

// MARK: - The platform text view

#if os(iOS)

private struct SelectableTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    @Binding var isEditing: Bool

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = UIFont.preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        // Generous, and symmetrical with the placeholder above. `lineFragmentPadding` is the
        // text system's own extra 5pt on the leading edge, zeroed so the inset here is the
        // whole story about where a line starts.
        view.textContainerInset = UIEdgeInsets(
            top: EditorMetrics.textInset,
            left: EditorMetrics.textInset,
            bottom: EditorMetrics.textInset * 2,
            right: EditorMetrics.textInset
        )
        view.textContainer.lineFragmentPadding = 0
        view.autocorrectionType = .yes
        view.keyboardDismissMode = .interactive
        view.alwaysBounceVertical = true
        // The SwiftUI layout above already sits inside the safe area and shortens for the
        // keyboard. Letting the scroll view add its own adjustment on top of that leaves a
        // band of dead space under the last line.
        view.contentInsetAdjustmentBehavior = .never
        return view
    }

    /// Fills whatever it is given. A `UITextView` asks for the height of its own content,
    /// which is how the editor used to end up as a small box with a long note scrolling
    /// inside it while most of the screen sat empty.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        proposedSize(proposal, fallback: CGSize(width: 320, height: 280))
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.applying = true
        defer { context.coordinator.applying = false }

        if view.text != text {
            view.text = text
        }
        // Every path that changes the text ends here — typing, a formatting button, a
        // restored draft — so this is the one place the styling has to be redrawn.
        let base = NoteTextStyling.bodyFont
        NoteTextStyling.apply(to: view.textStorage, base: base)
        // Otherwise the next character typed after a bold phrase inherits its attributes,
        // and the styling drifts away from what the markers actually say.
        view.typingAttributes = NoteTextStyling.baseAttributes(base)

        let bounded = clamp(selection, to: view.text as NSString)
        if view.selectedRange != bounded {
            view.selectedRange = bounded
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: SelectableTextView
        var applying = false

        init(_ parent: SelectableTextView) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            guard !applying else { return }
            parent.text = textView.text
            parent.selection = textView.selectedRange
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !applying else { return }
            parent.selection = textView.selectedRange
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.isEditing = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.isEditing = false
        }
    }
}

#else

private struct SelectableTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    @Binding var isEditing: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        guard let view = scrollView.documentView as? NSTextView else { return scrollView }
        view.delegate = context.coordinator
        view.font = NSFont.preferredFont(forTextStyle: .body)
        // Plain text: anything pasted in arrives as characters, and the only formatting in
        // the note is the markers themselves. What the styling below adds is appearance,
        // which is not the same thing and does not survive a copy out of here.
        view.isRichText = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: EditorMetrics.textInset, height: EditorMetrics.textInset)
        view.textContainer?.lineFragmentPadding = 0
        return scrollView
    }

    /// As on iOS: take the space, rather than asking for the height of the text.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        proposedSize(proposal, fallback: CGSize(width: 480, height: 280))
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let view = scrollView.documentView as? NSTextView else { return }
        context.coordinator.applying = true
        defer { context.coordinator.applying = false }

        if view.string != text {
            view.string = text
        }
        let base = NoteTextStyling.bodyFont
        if let storage = view.textStorage {
            NoteTextStyling.apply(to: storage, base: base)
        }
        view.typingAttributes = NoteTextStyling.baseAttributes(base)

        let bounded = clamp(selection, to: view.string as NSString)
        if view.selectedRange() != bounded {
            view.setSelectedRange(bounded)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SelectableTextView
        var applying = false

        init(_ parent: SelectableTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard !applying, let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            parent.selection = view.selectedRange()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !applying, let view = notification.object as? NSTextView else { return }
            parent.selection = view.selectedRange()
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.isEditing = true
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.isEditing = false
        }
    }
}

#endif

/// Whatever space the layout is offering, with something sensible when it is offering none
/// or offering infinity. SwiftUI asks a view for its size more than once and not always with
/// a real number in hand; handing back an infinite height would collapse the whole screen.
private func proposedSize(_ proposal: ProposedViewSize, fallback: CGSize) -> CGSize {
    let width = proposal.width ?? fallback.width
    let height = proposal.height ?? fallback.height
    return CGSize(
        width: width.isFinite ? width : fallback.width,
        height: height.isFinite ? height : fallback.height
    )
}

/// Keeps a selection inside the text it refers to. Setting a range past the end of an
/// `NSTextView` raises, and the text and the selection arrive from two different bindings,
/// so they are briefly out of step every time a formatting button fires.
private func clamp(_ range: NSRange, to text: NSString) -> NSRange {
    let location = max(0, min(range.location, text.length))
    let length = max(0, min(range.length, text.length - location))
    return NSRange(location: location, length: length)
}
