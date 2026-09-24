import SwiftUI
import UniformTypeIdentifiers
import NotesVaultCore

// MARK: - Mapping a spreadsheet

struct ImportMappingView: View {
    @ObservedObject var importer: ImportModel

    var body: some View {
        List {
            Section {
                Text("A spreadsheet can hold anything, so nothing is assumed. Check that each column below is what this app thinks it is — a column matched wrongly would file one client's session in another client's record.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach($importer.tables) { $pending in
                Section(pending.file) {
                    ColumnPicker(title: "Client", columns: pending.table.columns, selection: $pending.mapping.client)
                    ColumnPicker(title: "Session date", columns: pending.table.columns, selection: $pending.mapping.date)
                    ColumnPicker(title: "Time (optional)", columns: pending.table.columns, selection: $pending.mapping.time)
                    ColumnPicker(title: "Title (optional)", columns: pending.table.columns, selection: $pending.mapping.title)

                    ForEach(pending.table.columns.indices, id: \.self) { index in
                        Toggle(isOn: Binding(
                            get: { pending.mapping.body.contains(index) },
                            set: { include in
                                if include {
                                    pending.mapping.body = (pending.mapping.body + [index]).sorted()
                                } else {
                                    pending.mapping.body.removeAll { $0 == index }
                                }
                            }
                        )) {
                            Text("Use “\(pending.table.columns[index])” as the note")
                        }
                    }

                    if let first = pending.table.rows.first {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("First row reads as").font(.caption).foregroundStyle(.secondary)
                            Text(preview(pending, row: first))
                                .font(.system(.footnote, design: .monospaced))
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            BottomBar {
                Button("Continue") {
                    Task { await importer.applyMappings() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(importer.tables.contains { !$0.mapping.isUsable })
            }
        }
    }

    private func preview(_ pending: PendingTable, row: [String]) -> String {
        let client = pending.mapping.client.map { pending.table.cell(row, at: $0) } ?? "—"
        let date = pending.mapping.date.map { pending.table.cell(row, at: $0) } ?? "—"
        let body = pending.mapping.body
            .map { pending.table.cell(row, at: $0) }
            .joined(separator: " / ")
        return "\(client) · \(date)\n\(body.prefix(120))"
    }
}

struct ColumnPicker: View {
    let title: String
    let columns: [String]
    @Binding var selection: Int?

    var body: some View {
        Picker(title, selection: $selection) {
            Text("None").tag(Int?.none)
            ForEach(columns.indices, id: \.self) { index in
                Text(columns[index]).tag(Int?.some(index))
            }
        }
    }
}
