import SwiftUI
import UniformTypeIdentifiers
import NotesVaultCore

/// The import flow, start to finish.
///
/// The shape of this screen is an argument, not just a wizard. A counsellor moving five
/// years of clinical records into an app they installed last week is being asked for a
/// great deal of trust, and the honest way to earn it is to show the work: what was found,
/// what will be written, what actually landed on disk, and what is still lying around
/// unencrypted afterwards. Every claim this screen makes is one the app can demonstrate.
struct ImportView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var importer = ImportModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch importer.stage {
                case .choose:   ImportStartView(importer: importer)
                case .reading:  ImportBusyView(message: "Reading your files…")
                case .mapping:  ImportMappingView(importer: importer)
                case .review:   ImportReviewView(importer: importer)
                case .running:  ImportProgressView(importer: importer)
                case .finished: ImportSummaryView(importer: importer)
                }
            }
            .navigationTitle("Import notes")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if importer.stage == .finished {
                        Button("Done") { dismiss() }
                    } else if importer.stage != .running {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
            .alert(
                "That didn't work",
                isPresented: Binding(
                    get: { importer.errorMessage != nil },
                    set: { if !$0 { importer.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { importer.errorMessage = nil }
            } message: {
                Text(importer.errorMessage ?? "")
            }
        }
        .vaultSheet(minWidth: 720, minHeight: 620)
        .environmentObject(model)
    }
}


struct BottomBar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack {
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}
