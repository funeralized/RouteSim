import SwiftUI

struct RootView: View {
    @StateObject private var tunnelManager = TunnelManager.shared
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        if hasCompletedOnboarding {
            mainTabs
        } else {
            OnboardingView {
                hasCompletedOnboarding = true
            }
        }
    }

    private var mainTabs: some View {
        TabView {
            SpooferView()
                .tabItem {
                    Label("Spoof", systemImage: "location.fill")
                }

            NavigationStack {
                SimulateView()
            }
            .tabItem {
                Label("Routes", systemImage: "figure.walk")
            }

            NavigationStack {
                LibraryView()
            }
            .tabItem {
                Label("Library", systemImage: "map")
            }

            NavigationStack {
                RouteSimSettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape.fill")
            }
        }
    }
}
