//
//  ContentView.swift
//  SystemAudioSpectrogram
//
//  Created by Judau on 2026/06/19.
//

import Foundation
import SwiftUI

struct ContentView: View {
    @Environment(\.colorScheme) private var colorScheme

    @StateObject private var monitor = SystemAudioSpectrumMonitor()
    @AppStorage("spectrumMaximumFrequency") private var spectrumMaximumFrequency = SystemAudioSpectrumMonitor.defaultSpectrumMaximumFrequency
    @AppStorage("spectrumScrollSpeed") private var spectrumScrollSpeedRawValue = SpectrumScrollSpeed.normal.rawValue
    @AppStorage("spectrumFrequencyScale") private var spectrumFrequencyScaleRawValue = SpectrumFrequencyScale.linear.rawValue
    @AppStorage("spectrumResolution") private var spectrumResolutionRawValue = SpectrumResolution.high.rawValue

    var body: some View {
        VStack(spacing: 24) {
            header

            visualizer

            footer
        }
        .padding(28)
        .padding(.top, 18)
        .frame(minWidth: 820, idealWidth: 1_040, minHeight: 660, idealHeight: 700)
        .background {
            LinearGradient(
                colors: backgroundColors,
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .task {
            applySpectrumSettings()
#if DEBUG
            if ProcessInfo.processInfo.environment["SYSTEM_AUDIO_SPECTROGRAM_PREVIEW"] == "1" {
                monitor.loadPreviewSpectrogram()
                return
            }
#endif
            await monitor.start()
        }
        .onChange(of: spectrumMaximumFrequency) {
            applySpectrumSettings()
        }
        .onChange(of: spectrumScrollSpeedRawValue) {
            applySpectrumSettings()
        }
        .onChange(of: spectrumFrequencyScaleRawValue) {
            applySpectrumSettings()
        }
        .onChange(of: spectrumResolutionRawValue) {
            applySpectrumSettings()
        }
        .onDisappear {
            monitor.stop()
        }
    }

    private var backgroundColors: [Color] {
        switch colorScheme {
        case .dark:
            return [
                Color(red: 0.13, green: 0.14, blue: 0.14),
                Color(red: 0.04, green: 0.05, blue: 0.05)
            ]
        default:
            return [
                Color(red: 0.96, green: 0.97, blue: 0.98),
                Color(red: 0.87, green: 0.90, blue: 0.93)
            ]
        }
    }

    private var header: some View {
        spectrumControls
    }

    private var captureButton: some View {
        Button {
            guard !monitor.isPreviewing else { return }

            if monitor.isRunning {
                monitor.stop()
            } else {
                Task { await monitor.start() }
            }
        } label: {
            Label(
                monitor.isPreviewing ? "Preview" : (monitor.isRunning ? "Stop" : "Start"),
                systemImage: monitor.isPreviewing ? "waveform" : (monitor.isRunning ? "stop.fill" : "play.fill")
            )
        }
        .disabled(monitor.isPreviewing)
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .fixedSize()
    }

    private var spectrumControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                Label("Range", systemImage: "arrow.up.and.down")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.secondary)

                Picker("Range", selection: $spectrumMaximumFrequency) {
                    ForEach(SpectrumMaximumFrequencyOption.allCases) { option in
                        Text(option.title).tag(option.frequency)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 360)

                Label("Scale", systemImage: "point.3.filled.connected.trianglepath.dotted")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.secondary)

                Picker("Scale", selection: frequencyScale) {
                    ForEach(SpectrumFrequencyScale.allCases) { scale in
                        Text(scale.title).tag(scale)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 230)

                Spacer()
            }

            HStack(spacing: 14) {
                Label("Speed", systemImage: "speedometer")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.secondary)

                Picker("Speed", selection: scrollSpeed) {
                    ForEach(SpectrumScrollSpeed.allCases) { speed in
                        Text(speed.title).tag(speed)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 270)

                Label("Detail", systemImage: "square.grid.3x3")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.secondary)

                Picker("Detail", selection: resolution) {
                    ForEach(SpectrumResolution.allCases) { resolution in
                        Text(resolution.title).tag(resolution)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 270)

                Spacer()

                captureButton
            }
        }
    }

    private var visualizer: some View {
        StereoSpectrumView(
            leftRenderer: monitor.leftSpectrogram,
            rightRenderer: monitor.rightSpectrogram,
            maximumFrequency: spectrumMaximumFrequency,
            visibleDuration: currentScrollSpeed.visibleDuration,
            usesLogarithmicFrequencyScale: currentFrequencyScale == .logarithmic,
            isPaused: !monitor.isRunning
        )
    }

    private var currentScrollSpeed: SpectrumScrollSpeed {
        SpectrumScrollSpeed(rawValue: spectrumScrollSpeedRawValue) ?? .normal
    }

    private var scrollSpeed: Binding<SpectrumScrollSpeed> {
        Binding {
            currentScrollSpeed
        } set: { speed in
            spectrumScrollSpeedRawValue = speed.rawValue
        }
    }

    private var currentFrequencyScale: SpectrumFrequencyScale {
        SpectrumFrequencyScale(rawValue: spectrumFrequencyScaleRawValue) ?? .linear
    }

    private var currentResolution: SpectrumResolution {
        SpectrumResolution(rawValue: spectrumResolutionRawValue) ?? .high
    }

    private var resolution: Binding<SpectrumResolution> {
        Binding {
            currentResolution
        } set: { resolution in
            spectrumResolutionRawValue = resolution.rawValue
        }
    }

    private var frequencyScale: Binding<SpectrumFrequencyScale> {
        Binding {
            currentFrequencyScale
        } set: { scale in
            spectrumFrequencyScaleRawValue = scale.rawValue
        }
    }

    private func applySpectrumSettings() {
        let resolution = currentResolution

        monitor.updateSpectrumSettings(
            maximumFrequency: spectrumMaximumFrequency,
            historyLimit: currentScrollSpeed.historyLimit(frameRate: resolution.frameRate),
            usesLogarithmicFrequencyScale: currentFrequencyScale == .logarithmic,
            binCount: resolution.binCount,
            frameRate: resolution.frameRate,
            analysisWindowSize: resolution.analysisWindowSize
        )
    }

    private var footer: some View {
        FooterReadouts(levels: monitor.levels)
    }
}

// Keep the 30 Hz level stream isolated to the footer so audio updates do not
// invalidate and re-layout the full spectrogram interface.

private struct FooterReadouts: View {
    @ObservedObject var levels: AudioLevelReadouts

    var body: some View {
        HStack {
            Text("L \(levels.leftDecibelsText)")
                .monospacedDigit()

            Spacer()

            Text("Peak \(levels.peakDecibelsText)")
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Spacer()

            Text("R \(levels.rightDecibelsText)")
                .monospacedDigit()
        }
        .font(.system(.headline, design: .rounded))
        .padding(.horizontal, 6)
    }
}

private enum SpectrumFrequencyScale: String, CaseIterable, Identifiable {
    case linear
    case logarithmic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .linear:
            return "Linear"
        case .logarithmic:
            return "Log"
        }
    }
}

private enum SpectrumScrollSpeed: String, CaseIterable, Identifiable {
    case slow
    case normal
    case fast

    var id: String { rawValue }

    var title: String {
        switch self {
        case .slow:
            return "Slow"
        case .normal:
            return "Normal"
        case .fast:
            return "Fast"
        }
    }

    func historyLimit(frameRate: Double) -> Int {
        Int((visibleDuration * frameRate).rounded())
    }

    var visibleDuration: TimeInterval {
        switch self {
        case .slow:
            return 5.0
        case .normal:
            return 3.0
        case .fast:
            return 1.5
        }
    }
}

private enum SpectrumMaximumFrequencyOption: Double, CaseIterable, Identifiable {
    case eight = 8_000
    case twelve = 12_000
    case sixteen = 16_000
    case twenty = 20_000
    case twentyFour = 24_000

    var id: Double { rawValue }
    var frequency: Double { rawValue }

    var title: String {
        "\(Int(rawValue / 1_000)) kHz"
    }
}

/// Spectrogram resolution presets. Vertical detail comes from the display
/// bin count, horizontal detail from the analysis frame rate, and the FFT
/// window size bounds how much real frequency detail the bins can carry.
private enum SpectrumResolution: String, CaseIterable, Identifiable {
    case standard
    case high
    case ultra

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard:
            return "Standard"
        case .high:
            return "High"
        case .ultra:
            return "Ultra"
        }
    }

    var binCount: Int {
        switch self {
        case .standard:
            return 96
        case .high:
            return 192
        case .ultra:
            return 384
        }
    }

    var frameRate: Double {
        switch self {
        case .standard:
            return 30
        case .high, .ultra:
            return 60
        }
    }

    var analysisWindowSize: Int {
        switch self {
        case .standard, .high:
            return 2_048
        case .ultra:
            return 4_096
        }
    }
}
