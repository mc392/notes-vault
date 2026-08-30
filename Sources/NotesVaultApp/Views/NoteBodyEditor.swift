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
struct NoteBodyEditor: View {
    @Binding var text: String
    @State private var selection = NSRange(location: 0, length: 0)
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FormattingBar { style in
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

            SelectableTextView(text: $text, selection: $selection)
                .frame(minHeight: 260)
        }
        .background(.background)
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct FormattingBar: View {
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
            }
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        #if os(macOS)
        .background(.quaternary.opacity(0.35))
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
