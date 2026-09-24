import SwiftUI
import UniformTypeIdentifiers
import NotesVaultCore

// MARK: - Start

struct ImportStartView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var importer: ImportModel

    @State private var pickingFiles = false
    @State private var pickingFolder = false

    var body: some View {
        List {
            Section {
                Button {
                    pickingFolder = true
                } label: {
                    Label("Choose a folder of notes", systemImage: "folder")
                }
                Button {
                    pickingFiles = true
                } label: {
                    Label("Choose files", systemImage: "doc")
                }
            } footer: {
                Text("A folder with one subfolder per client is the easiest shape to bring in — but a single spreadsheet, or a pile of documents, works too.")
            }

            Section("What happens to your files") {
                PromiseRow(
                    symbol: "lock.laptopcomputer",
                    title: "Everything is read on this device",
                    detail: "Your files are opened here, in this app, and never sent anywhere. This app has no permission to use the network at all — if a future version of it tried, macOS would refuse the connection."
                )
                PromiseRow(
                    symbol: "wifi.slash",
                    title: "You can do this with the internet off",
                    detail: "Nothing about importing needs a connection. If you would rather prove that than take it on trust, turn Wi‑Fi off first — the import will work exactly the same."
                )
                PromiseRow(
                    symbol: "lock.doc",
                    title: "Encrypted before it is stored, not after",
                    detail: "Each note is encrypted in memory and only then written into your vault folder. Your sync folder never holds a readable copy, so there is no window in which iCloud could pick one up."
                )
                PromiseRow(
                    symbol: "eye.slash",
                    title: "You will see what was written",
                    detail: "As each note goes in, this screen shows the scrambled filename it was stored under and confirms the file holds none of the note's own words. Nothing here asks to be believed."
                )
                PromiseRow(
                    symbol: "doc.on.doc",
                    title: "Your originals are left exactly where they are",
                    detail: "Nothing is moved, renamed or deleted. When the import is done and you have checked it, deleting the originals is your decision to make — and this screen will remind you that they are still unencrypted until you do."
                )
            }

            Section {
                DisclosureGroup("What can be read") {
                    FormatList()
                }
                DisclosureGroup("Getting notes out of Apple Notes") {
                    AppleNotesGuide()
                }
            }
        }
        .fileImporter(
            isPresented: $pickingFiles,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            handle(result)
        }
        .fileImporter(
            isPresented: $pickingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { result in
            handle(result)
        }
    }

    private func handle(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            Task {
                await importer.load(
                    urls: urls,
                    existingClients: model.existingClientCodes,
                    existingNotes: model.index.notes,
                    noteFields: model.noteFields
                )
            }
        case let .failure(error):
            importer.errorMessage = error.localizedDescription
        }
    }
}

struct PromiseRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct FormatList: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Word documents, Excel workbooks, CSV files, plain text, Markdown, rich text (including notes dragged out of Notes or TextEdit), web pages and HTML exports, Evernote exports, and PDFs that hold real text.")
                .font(.footnote)
            Text("Not readable: older .doc files, Pages and Numbers documents, and PDFs that are scans or photographs of handwriting. This app has no camera permission and does not read handwriting — open those in the app that made them and save a copy as Word, text or CSV.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct AppleNotesGuide: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("On a Mac, in Notes:")
                .font(.footnote)
            Label("Make a folder in Finder for one client.", systemImage: "1.circle")
                .font(.footnote)
            Label("Select that client's notes in Notes, then export them as Markdown into that folder — one .md file per note.", systemImage: "2.circle")
                .font(.footnote)
            Label("Repeat for each client, then choose the folder holding all of them here.", systemImage: "3.circle")
                .font(.footnote)
            Text("Dragging notes out of Notes into Finder does not work — it does not leave files behind that can be read. Export as Markdown is the route.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("Afterwards, remember Notes keeps deleted notes in Recently Deleted for 30 days. Empty it once you are satisfied the import is right.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct ImportBusyView: View {
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text(message).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
