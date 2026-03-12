import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    var body: some View {
        TabView {
            PlayerView()
                .tabItem {
                    Label("Player", systemImage: "play.circle")
                }

            GeneratorView()
                .tabItem {
                    Label("Generator", systemImage: "waveform.path.ecg")
                }

            ActivitiesView()
                .tabItem {
                    Label("Activities", systemImage: "sparkles")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
    }
}

private struct PlayerView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showImporter = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.sourceName)
                            .font(.title2.weight(.semibold))
                        Text(model.statusMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Output: \(model.outputMode.rawValue)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.tertiary)
                    }

                    if let duration = model.duration {
                        VStack(alignment: .leading, spacing: 8) {
                            Slider(
                                value: Binding(
                                    get: { model.position },
                                    set: { model.seek(to: $0) }
                                ),
                                in: 0...max(duration, 0.01)
                            )
                            HStack {
                                Text(timeString(model.position))
                                Spacer()
                                Text(timeString(duration))
                            }
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 12) {
                        Button("Import File") {
                            showImporter = true
                        }
                        .buttonStyle(.borderedProminent)

                        Button(model.isPlaying ? "Stop" : "Play") {
                            model.togglePlayback()
                        }
                        .buttonStyle(.bordered)

                        Button("Use Generator") {
                            model.loadGenerator(playImmediately: true)
                        }
                        .buttonStyle(.bordered)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Live Pulse")
                            .font(.headline)
                        PulseMetricsView(pulse: model.currentPulse)
                        PulseHistoryView(pulses: model.recentPulses)
                            .frame(height: 120)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Power")
                            .font(.headline)
                        LabeledSlider(
                            title: "Channel A",
                            value: Binding(
                                get: { Double(model.powerA) },
                                set: { model.powerA = Int($0.rounded()) }
                            ),
                            range: 0...200,
                            format: "%.0f"
                        )
                        LabeledSlider(
                            title: "Channel B",
                            value: Binding(
                                get: { Double(model.powerB) },
                                set: { model.powerB = Int($0.rounded()) }
                            ),
                            range: 0...200,
                            format: "%.0f"
                        )
                    }

                    if let error = model.lastError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Howl")
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.data, .json, UTType(filenameExtension: "hwl") ?? .data, UTType(filenameExtension: "funscript") ?? .json]
            ) { result in
                switch result {
                case .success(let url):
                    model.importFile(from: url)
                case .failure(let error):
                    model.lastError = error.localizedDescription
                }
            }
        }
    }
}

private struct GeneratorView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Global") {
                    LabeledSlider(
                        title: "Speed",
                        value: Binding(
                            get: { model.generatorConfig.speed },
                            set: { model.updateGeneratorSpeed($0) }
                        ),
                        range: 0.1...2.0,
                        format: "%.2f"
                    )

                    Button("Load Generator") {
                        model.loadGenerator(playImmediately: false)
                    }

                    Button("Play Generator") {
                        model.loadGenerator(playImmediately: true)
                    }
                }

                ForEach(GeneratorChannelID.allCases) { channelID in
                    Section(channelID.label) {
                        Picker("Amplitude Shape", selection: stringBinding(channelID, \.amplitudeShape)) {
                            ForEach(model.shapeNames, id: \.self) { shapeName in
                                Text(shapeName).tag(shapeName)
                            }
                        }

                        Picker("Frequency Shape", selection: stringBinding(channelID, \.frequencyShape)) {
                            ForEach(model.shapeNames, id: \.self) { shapeName in
                                Text(shapeName).tag(shapeName)
                            }
                        }

                        LabeledSlider(
                            title: "Min Power",
                            value: doubleBinding(channelID, \.minAmplitude),
                            range: 0...1,
                            format: "%.2f"
                        )
                        LabeledSlider(
                            title: "Max Power",
                            value: doubleBinding(channelID, \.maxAmplitude),
                            range: 0...1,
                            format: "%.2f"
                        )
                        LabeledSlider(
                            title: "Min Frequency",
                            value: doubleBinding(channelID, \.minFrequencyNormalized),
                            range: 0...1,
                            format: "%.2f"
                        )
                        LabeledSlider(
                            title: "Max Frequency",
                            value: doubleBinding(channelID, \.maxFrequencyNormalized),
                            range: 0...1,
                            format: "%.2f"
                        )
                    }
                }
            }
            .navigationTitle("Generator")
        }
    }

    private func stringBinding(
        _ channelID: GeneratorChannelID,
        _ keyPath: WritableKeyPath<GeneratorChannelConfig, String>
    ) -> Binding<String> {
        Binding(
            get: { channelConfig(for: channelID)[keyPath: keyPath] },
            set: { newValue in
                model.updateGeneratorChannel(channelID) { channel in
                    channel[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func doubleBinding(
        _ channelID: GeneratorChannelID,
        _ keyPath: WritableKeyPath<GeneratorChannelConfig, Double>
    ) -> Binding<Double> {
        Binding(
            get: { channelConfig(for: channelID)[keyPath: keyPath] },
            set: { newValue in
                model.updateGeneratorChannel(channelID) { channel in
                    channel[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func channelConfig(for channelID: GeneratorChannelID) -> GeneratorChannelConfig {
        switch channelID {
        case .a: return model.generatorConfig.channelA
        case .b: return model.generatorConfig.channelB
        }
    }
}

private struct ActivitiesView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                Section("Prototype Presets") {
                    ForEach(DemoActivity.allCases) { activity in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(activity.rawValue)
                                .font(.headline)
                            Button("Load and Play") {
                                model.loadActivity(activity, playImmediately: true)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(.vertical, 6)
                    }
                }

                Section("Why this is scoped down") {
                    Text("This iPhone MVP keeps the safe, portable parts first: file playback, pulse timing, generator logic, and one clean Coyote 3 path. Full parity with Android should wait until real hardware validation.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Activities")
        }
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var bleManager: CoyoteBluetoothManager

    var body: some View {
        NavigationStack {
            Form {
                Section("Output") {
                    Picker("Mode", selection: $model.outputMode) {
                        ForEach(OutputMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                }

                Section("HWL Playback") {
                    Picker("Profile", selection: $model.hwlPlaybackProfile) {
                        ForEach(HWLPlaybackProfile.allCases) { profile in
                            Text(profile.rawValue).tag(profile)
                        }
                    }

                    Text(model.hwlPlaybackProfile.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("BLE") {
                    LabeledContent("State", value: bleManager.state.rawValue)
                    LabeledContent("Last Seen", value: bleManager.lastSeenDeviceName)
                    LabeledContent("Battery", value: bleManager.batteryLevel.map { "\($0)%" } ?? "Unknown")
                    LabeledContent(
                        "Device Echo",
                        value: bleManager.devicePowerA.flatMap { powerA in
                            bleManager.devicePowerB.map { powerB in "A \(powerA) / B \(powerB)" }
                        } ?? "No echo yet"
                    )

                    if bleManager.state == .disconnected || bleManager.state == .unavailable {
                        Button("Scan for Coyote 3") {
                            bleManager.connectOrScan()
                        }
                    } else {
                        Button("Disconnect") {
                            bleManager.disconnect()
                        }
                    }

                    if !bleManager.stagedPacketHex.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Current Packet Preview")
                                .font(.caption.weight(.semibold))
                            Text(bleManager.stagedPacketHex)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }

                    if !bleManager.lastWriteHex.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Last Sent Packet")
                                .font(.caption.weight(.semibold))
                            Text(bleManager.lastWriteHex)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }

                    if !bleManager.lastNotifyHex.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Last Notify Frame")
                                .font(.caption.weight(.semibold))
                            Text(bleManager.lastNotifyHex)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }

                    if let error = bleManager.lastError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section("Diagnostics") {
                    LabeledContent("Last Write", value: bleManager.lastWriteSummary)
                    LabeledContent("Last Notify", value: bleManager.lastNotifySummary)
                    LabeledContent("Pulse Batches", value: "\(bleManager.sentPulsePacketCount)")
                    LabeledContent("Backpressure Hits", value: "\(bleManager.queuedPulsePacketCount)")
                    LabeledContent("Notify Frames", value: "\(bleManager.notifyFrameCount)")
                }

                Section("Frequency Range") {
                    LabeledSlider(
                        title: "Minimum",
                        value: $model.minFrequency,
                        range: 1...180,
                        format: "%.0f Hz"
                    )
                    LabeledSlider(
                        title: "Maximum",
                        value: $model.maxFrequency,
                        range: 10...200,
                        format: "%.0f Hz"
                    )
                }

                Section("Notes") {
                    Text("This build now matches the Android Coyote 3 packet shape, sends 4-pulse batches, and exposes transport diagnostics for first-pass hardware testing. Coyote 2, recorder mode, and real device validation still need a separate pass.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}

private struct PulseMetricsView: View {
    let pulse: Pulse

    var body: some View {
        HStack(spacing: 12) {
            MetricChip(title: "A Amp", value: pulse.ampA)
            MetricChip(title: "B Amp", value: pulse.ampB)
            MetricChip(title: "A Freq", value: pulse.freqA)
            MetricChip(title: "B Freq", value: pulse.freqB)
        }
    }
}

private struct PulseHistoryView: View {
    let pulses: [Pulse]

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(pulses.enumerated()), id: \.offset) { _, pulse in
                    VStack(spacing: 4) {
                        Capsule()
                            .fill(.orange)
                            .frame(height: max(4, geometry.size.height * CGFloat(pulse.ampA) * 0.5))
                        Capsule()
                            .fill(.mint)
                            .frame(height: max(4, geometry.size.height * CGFloat(pulse.ampB) * 0.5))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct MetricChip: View {
    let title: String
    let value: Float

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(String(format: "%.2f", value))
                .font(.body.monospacedDigit())
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value))
                    .foregroundStyle(.secondary)
                    .font(.caption.monospacedDigit())
            }
            Slider(value: $value, in: range)
        }
    }
}

private func timeString(_ time: TimeInterval) -> String {
    let minutes = Int(time / 60)
    let seconds = time.truncatingRemainder(dividingBy: 60)
    return String(format: "%02d:%04.1f", minutes, seconds)
}
