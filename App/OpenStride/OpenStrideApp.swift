import CoachKit
import SwiftUI

@main
struct OpenStrideApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(.orange)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var tab = UserDefaults.standard.string(forKey: "tab") ?? "week"

    var body: some View {
        if model.goal == nil && UserDefaults.standard.string(forKey: "seedHealth") == nil {
            OnboardingView()
        } else {
            TabView(selection: $tab) {
                WeekView().tabItem { Label("Plan", systemImage: "calendar") }.tag("week")
                InsightsView().tabItem { Label("Insights", systemImage: "waveform.path.ecg") }.tag("insights")
                SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }.tag("settings")
            }
            .task {
                await model.seedIfRequested()
                await model.refresh()
            }
        }
    }
}

extension SessionType {
    var color: Color {
        switch self {
        case .easy: .green
        case .long: .blue
        case .tempo: .orange
        case .intervals: .red
        case .recovery: .teal
        case .rest: .gray
        case .race: .purple
        }
    }

    var label: String {
        switch self {
        case .easy: "Easy"
        case .long: "Long run"
        case .tempo: "Tempo"
        case .intervals: "Intervals"
        case .recovery: "Recovery"
        case .rest: "Rest"
        case .race: "Race"
        }
    }

    var symbol: String {
        switch self {
        case .easy: "figure.run"
        case .long: "road.lanes"
        case .tempo: "speedometer"
        case .intervals: "bolt.fill"
        case .recovery: "leaf.fill"
        case .rest: "bed.double.fill"
        case .race: "flag.checkered"
        }
    }
}

extension Int {
    var weekdayName: String { CoachAgent.dayNames[(self - 1) % 7] }
}
