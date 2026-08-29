import SwiftUI
import NotesVaultCore

/// The retention list: who is due, who is coming up, and who is still in contact.
///
/// It flags and it explains. It does not delete, and there is no button here that deletes
/// in one step — every row leads to the same typed-confirmation gauntlet everything else
/// does. The automation stops exactly where professional judgement starts.
struct RetentionReviewView: View {
    @EnvironmentObject private var model: AppModel
    @State private var destroying: ClientSummary?

    private var assessments: [RetentionAssessment] { model.retentionReview }
    private var needingAttention: [RetentionAssessment] { assessments.filter(\.needsAttention) }
    private var counting: [RetentionAssessment] { assessments.filter { $0.state == .counting } }
    private var notCounting: [RetentionAssessment] { assessments.filter { $0.state == .notCounting } }

    var body: some View {
        List {
            if assessments.isEmpty {
                EmptyStateView(
                    symbol: "clock",
                    title: "Nothing to review",
                    detail: "Clients appear here once their work has ended and the retention period is running."
                )
            }

            if !needingAttention.isEmpty {
                Section {
                    ForEach(needingAttention) { assessment in
                        RetentionRow(assessment: assessment) {
                            if let client = model.index.client(assessment.client) {
                                destroying = client
                            }
                        }
                    }
                } header: {
                    Text("Needs a decision")
                } footer: {
                    Text("Being past the retention period is not an instruction to destroy. Record-keeping obligations can outlast it — an ongoing complaint or claim is the usual reason.")
                }
            }

            if !counting.isEmpty {
                Section("Retention running") {
                    ForEach(counting) { assessment in
                        RetentionRow(assessment: assessment, onDestroy: nil)
                    }
                }
            }

            if !notCounting.isEmpty {
                Section("No clock running") {
                    ForEach(notCounting) { assessment in
                        RetentionRow(assessment: assessment, onDestroy: nil)
                    }
                }
            }
        }
        .navigationTitle("Retention")
        .refreshable { await model.refreshIndex(force: true) }
        .sheet(item: $destroying) { client in
            DestroyClientView(client: client) { destroying = nil }
        }
    }
}

struct RetentionRow: View {
    let assessment: RetentionAssessment
    let onDestroy: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(assessment.client.rawValue)
                    .font(.system(.headline, design: .monospaced))
                Spacer()
                RetentionChip(state: assessment.state)
            }
            Text(assessment.explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                if let last = assessment.lastContact {
                    Text("Last contact \(Formatted.date(last))")
                }
                if let due = assessment.dueOn, assessment.state != .notCounting {
                    Text("Due \(Formatted.date(due))")
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)

            if let onDestroy {
                Button("Review and destroy…", role: .destructive, action: onDestroy)
                    .font(.footnote)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 2)
    }
}
