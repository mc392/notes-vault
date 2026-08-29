import SwiftUI
import NotesVaultCore

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            switch model.phase {
            case .starting:
                LoadingView(message: "Looking for your vault…")
            case .chooseFolder:
                ChooseFolderView()
            case .createVault:
                CreateVaultView()
            case .locked:
                UnlockView()
            case .revealRecoveryKey:
                RecoveryKeyView()
            case .unlocked:
                MainView()
            }
        }
        .overlay {
            if let message = model.busyMessage {
                BusyOverlay(message: message)
            }
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct MainView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            NavigationStack {
                ClientListView()
            }
            .tabItem { Label("Clients", systemImage: "person.text.rectangle") }

            NavigationStack {
                RetentionReviewView()
            }
            .tabItem { Label("Retention", systemImage: "clock.arrow.circlepath") }
            .badge(model.retentionNeedingAttention.count)

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

struct LoadingView: View {
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(message)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct BusyOverlay: View {
    let message: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text(message).font(.callout)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .transition(.opacity)
    }
}
