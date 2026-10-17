import CoachKit
import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var race: RaceDistance = .tenK
    @State private var raceDate = Calendar.current.date(byAdding: .weekOfYear, value: 10, to: .now)!
    @State private var days = 4
    @State private var longDay = 7
    @State private var useSample = false
    @State private var persona: Persona = .steady

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("A coach that reads your body.")
                            .font(.title2.bold())
                        Text("OpenStride reads your runs and heart rate from Apple Health, works out your zones and training load, and plans each week for you. The coach is Gemma, an open model running on this iPhone, so your health data stays here.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("Your goal") {
                    Picker("Race", selection: $race) {
                        ForEach(RaceDistance.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    DatePicker("Race day", selection: $raceDate, in: Calendar.current.date(byAdding: .weekOfYear, value: 3, to: .now)!..., displayedComponents: .date)
                    Stepper("\(days) runs per week", value: $days, in: 3...6)
                    Picker("Long run day", selection: $longDay) {
                        ForEach(1...7, id: \.self) { Text($0.weekdayName).tag($0) }
                    }
                }

                Section {
                    Toggle("Use a sample runner instead", isOn: $useSample)
                    if useSample {
                        Picker("Sample", selection: $persona) {
                            ForEach(Persona.allCases, id: \.self) { p in
                                Text(p.summary).tag(p)
                            }
                        }
                    }
                } header: {
                    Text("Data")
                } footer: {
                    Text(useSample ? "Try the coach with made-up history." : "We will ask for read access to workouts, heart rate, resting heart rate and VO2 max.")
                }

                Section {
                    Button {
                        Task {
                            model.saved.source = useSample ? .sample(persona) : .health
                            await model.start(goal: Goal(race: race, raceDate: raceDate, daysPerWeek: days, longRunWeekday: longDay))
                        }
                    } label: {
                        Text("Build my plan").frame(maxWidth: .infinity).bold()
                    }
                }
            }
            .navigationTitle("OpenStride")
        }
    }
}
