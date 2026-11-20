import SwiftUI

@main
struct Orbit8DApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("Orbit8D", systemImage: model.enabled ? "headphones.circle.fill" : "headphones.circle") {
            ControlPanel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct ControlPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("8D audio", isOn: $model.enabled)
                .toggleStyle(.switch)

            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if model.enabled {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Bars per orbit", selection: $model.bars) {
                Text("Auto").tag(0)
                Text("2").tag(2)
                Text("4").tag(4)
                Text("8").tag(8)
                Text("16").tag(16)
            }
            .pickerStyle(.segmented)

            LabeledContent("Width") {
                Slider(value: $model.width, in: 10...90)
            }
            LabeledContent("Room") {
                Slider(value: $model.reverb, in: 0...0.6)
            }

            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding()
        .frame(width: 280)
    }

    private var status: String {
        var period = String(format: "%.1f s orbit", model.orbitPeriod)
        if model.dropouts > 0 { period += " · \(model.dropouts) dropouts" }
        guard let bpm = model.bpm else { return "No beat found · \(period)" }
        return "\(Int(bpm.rounded())) BPM · \(period)"
    }
}
