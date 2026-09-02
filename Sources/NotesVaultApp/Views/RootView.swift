import SwiftUI
import NotesVaultCore

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            switch model.phase {
            case .starting:
                // The splash, not a spinner: until the vault has been found and unlocked
                // there is nothing anyone is entitled to see, and a screen that shows
                // nothing should still look like the app.
                SplashView(status: "Looking for your vault…")
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
        // Raised the instant the app leaves the foreground and while a resume check is on
        // screen. On iOS a second copy goes up in its own window (`PrivacyShieldWindow`),
        // which is what covers any sheet presented above this view; this one covers the app
        // itself, and is the whole shield on the Mac.
        .overlay {
            if model.isShielded {
                SplashView()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.isShielded)
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
