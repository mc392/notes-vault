import SwiftUI
import NotesVaultCore

#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The note body, with a formatting bar.
///
/// SwiftUI's own `TextEditor` did not expose its selection until well after the iOS 17 /
/// macOS 14 floor this app targets, and a formatting button that cannot see what is
/// selected is a formatting button that appends markers to the end of the note. So the text
/// view is wrapped by hand on both platforms. It is the only place in the app that reaches
/// below SwiftUI, and it does so for that one reason.
///
/// What the buttons insert is Markdown — see `NoteMarkdown` for why that, and not rich text.
/// What the counsellor *sees* is the formatting itself: a subheading is drawn as one while
/// it is being typed, with its `##` faded back rather than hidden. Faded rather than hidden
/// because the characters are genuinely there — they are what makes a decrypted note open
/// as a formatted document in any Markdown-aware editor forever — and an editor that drew
/// text the file does not contain would be lying about the record.
struct NoteBodyEditor: View {
    @Binding var text: String
    @State private var selection = NSRange(location: 0, length: 0)
    /// Reading the note as it will be read back, rather than as it is being written. The
    /// live styling is enough almost always; this is for the moment before saving when
    /// somebody wants to see the finished thing.
    @State private var previewing = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FormattingBar(previewing: $previewing) { style in
                let edit = NoteMarkdown.apply(
                    style,
                    to: text,
                    selectionStart: selection.location,
                    selectionLength: selection.length
                )
                text = edit.text
                selection = NSRange(location: edit.selectionStart, length: edit.selectionLength)
            }

            Divider()

            if previewing {
                preview
            } else {
                SelectableTextView(text: $text, selection: $selection)
                    .frame(minHeight: 260)
            }
        }
        .background(.background)
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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
            .padding(12)
        }
        .frame(minHeight: 260)
    }
}

private struct FormattingBar: View {
    @Binding var previewing: Bool
    let apply: (NoteMarkdownStyle) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(NoteMarkdownStyle.allCases, id: \.self) { style in
                Button {
                    apply(style)
                } label: {
                    Image(systemName: style.symbolName)
                        .frame(width: 30, height: 26)
                }
                .buttonStyle(.borderless)
                .help(style.displayName)
                .accessibilityLabel(style.displayName)
                // Nothing to format while the preview is up, and a button that silently
                // did nothing would read as broken.
                .disabled(previewing)
            }

            Spacer()

            Toggle(isOn: $previewing) {
                Image(systemName: previewing ? "eye.fill" : "eye")
                    .frame(width: 30, height: 26)
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .help("Preview")
            .accessibilityLabel("Preview")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        #if os(macOS)
        .background(.quaternary.opacity(0.35))
        #endif
    }
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

    static func baseAttributes(_ base: PlatformFont) -> [NSAttributedString.Key: Any] {
        #if os(iOS)
        return [.font: base, .foregroundColor: PlatformColor.label]
        #else
        return [.font: base, .foregroundColor: PlatformColor.labelColor]
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

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = UIFont.preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        view.autocorrectionType = .yes
        view.keyboardDismissMode = .interactive
        return view
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
    }
}

#else

private struct SelectableTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange

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
        view.textContainerInset = NSSize(width: 6, height: 8)
        return scrollView
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
    }
}

#endif

/// Keeps a selection inside the text it refers to. Setting a range past the end of an
/// `NSTextView` raises, and the text and the selection arrive from two different bindings,
/// so they are briefly out of step every time a formatting button fires.
private func clamp(_ range: NSRange, to text: NSString) -> NSRange {
    let location = max(0, min(range.location, text.length))
    let length = max(0, min(range.length, text.length - location))
    return NSRange(location: location, length: length)
}
