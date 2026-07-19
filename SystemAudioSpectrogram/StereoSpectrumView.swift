//
//  StereoSpectrumView.swift
//  SystemAudioSpectrogram
//
//  Created by Codex on 2026/06/20.
//

import SwiftUI

struct StereoSpectrumView: View {
    let leftRenderer: SpectrogramRenderer
    let rightRenderer: SpectrogramRenderer
    let maximumFrequency: Double
    let visibleDuration: TimeInterval
    let usesLogarithmicFrequencyScale: Bool
    let isPaused: Bool

    var body: some View {
        HStack(spacing: 18) {
            SpectrumChannelView(
                title: "LEFT OUTPUT",
                renderer: leftRenderer,
                maximumFrequency: maximumFrequency,
                visibleDuration: visibleDuration,
                usesLogarithmicFrequencyScale: usesLogarithmicFrequencyScale,
                isPaused: isPaused
            )

            SpectrumChannelView(
                title: "RIGHT OUTPUT",
                renderer: rightRenderer,
                maximumFrequency: maximumFrequency,
                visibleDuration: visibleDuration,
                usesLogarithmicFrequencyScale: usesLogarithmicFrequencyScale,
                isPaused: isPaused
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SpectrumChannelView: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let renderer: SpectrogramRenderer
    let maximumFrequency: Double
    let visibleDuration: TimeInterval
    let usesLogarithmicFrequencyScale: Bool
    let isPaused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .tracking(1.8)
                    .foregroundStyle(titleColor)

                Spacer()

                Text("\(usesLogarithmicFrequencyScale ? "Log " : "")0-\(Self.frequencyText(maximumFrequency))")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(detailColor)
            }

            HStack(spacing: 7) {
                FrequencyScale(
                    maximumFrequency: maximumFrequency,
                    usesLogarithmicFrequencyScale: usesLogarithmicFrequencyScale
                )

                SpectrumCanvas(
                    renderer: renderer,
                    maximumFrequency: maximumFrequency,
                    visibleDuration: visibleDuration,
                    usesLogarithmicFrequencyScale: usesLogarithmicFrequencyScale,
                    isPaused: isPaused
                )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                    }

                ColorScale()
            }
        }
        .padding(14)
        .background(panelFill, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(panelStroke, lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) spectrum")
    }

    private var panelFill: Color {
        colorScheme == .dark ? .black.opacity(0.34) : .white.opacity(0.78)
    }

    private var panelStroke: Color {
        colorScheme == .dark ? .white.opacity(0.12) : .black.opacity(0.14)
    }

    private var titleColor: Color {
        colorScheme == .dark ? .white.opacity(0.72) : .black.opacity(0.72)
    }

    private var detailColor: Color {
        colorScheme == .dark ? .white.opacity(0.42) : .black.opacity(0.48)
    }

    private static func frequencyText(_ frequency: Double) -> String {
        "\(Int(frequency / 1_000)) kHz"
    }
}

private struct SpectrumCanvas: View {
    let renderer: SpectrogramRenderer
    let maximumFrequency: Double
    let visibleDuration: TimeInterval
    let usesLogarithmicFrequencyScale: Bool
    let isPaused: Bool

    var body: some View {
        SpectrumDisplay(
            renderer: renderer,
            visibleDuration: visibleDuration,
            isPaused: isPaused
        )
        .overlay {
            // Static overlay: this Canvas redraws only when the size or the
            // scale settings change, never per animation frame. The 60 fps
            // scroll itself runs in SpectrumDisplay's AppKit layer tree.
            Canvas { context, size in
                drawGrid(in: &context, size: size)
            }
            .allowsHitTesting(false)
        }
        .frame(minWidth: 260, minHeight: 350)
    }

    private func drawGrid(in context: inout GraphicsContext, size: CGSize) {
        let gridColor = Color.white.opacity(0.25)

        for index in 0...4 {
            let x = size.width * CGFloat(index) / 4
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(path, with: .color(gridColor), lineWidth: 0.55)
        }

        for position in Self.horizontalGridPositions(
            maximumFrequency: maximumFrequency,
            usesLogarithmicFrequencyScale: usesLogarithmicFrequencyScale
        ) {
            let y = size.height * position
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(path, with: .color(gridColor), lineWidth: 0.55)
        }
    }

    private static func horizontalGridPositions(
        maximumFrequency: Double,
        usesLogarithmicFrequencyScale: Bool
    ) -> [CGFloat] {
        guard usesLogarithmicFrequencyScale else {
            return (0...8).map { CGFloat($0) / 8 }
        }

        return FrequencyScale.markers(
            maximumFrequency: maximumFrequency,
            usesLogarithmicFrequencyScale: true
        )
        .map(\.topPosition)
    }

}

private struct FrequencyScale: View {
    @Environment(\.colorScheme) private var colorScheme

    let maximumFrequency: Double
    let usesLogarithmicFrequencyScale: Bool

    private var markers: [FrequencyMarker] {
        Self.markers(
            maximumFrequency: maximumFrequency,
            usesLogarithmicFrequencyScale: usesLogarithmicFrequencyScale
        )
    }

    private var linearLabels: [String] {
        let maxKilohertz = Int(maximumFrequency / 1_000)
        return [
            "\(maxKilohertz)k",
            "\(maxKilohertz * 3 / 4)k",
            "\(maxKilohertz / 2)k",
            "\(maxKilohertz / 4)k",
            "0"
        ]
    }

    var body: some View {
        GeometryReader { proxy in
            if usesLogarithmicFrequencyScale {
                ZStack {
                    ForEach(markers) { marker in
                        Text(marker.label)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(labelColor)
                            .position(
                                x: proxy.size.width * 0.5,
                                y: max(5, min(proxy.size.height - 5, proxy.size.height * marker.topPosition))
                            )
                    }
                }
            } else {
                VStack {
                    ForEach(linearLabels, id: \.self) { label in
                        Text(label)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(labelColor)

                        if label != linearLabels.last {
                            Spacer()
                        }
                    }
                }
            }
        }
        .frame(width: 24)
    }

    private var labelColor: Color {
        colorScheme == .dark ? .white.opacity(0.48) : .black.opacity(0.56)
    }

    static func markers(
        maximumFrequency: Double,
        usesLogarithmicFrequencyScale: Bool
    ) -> [FrequencyMarker] {
        guard usesLogarithmicFrequencyScale else {
            return (0...8).map { index in
                FrequencyMarker(
                    label: "",
                    topPosition: CGFloat(index) / 8
                )
            }
        }

        let candidates = [24_000.0, 20_000.0, 16_000.0, 12_000.0, 8_000.0, 4_000.0, 2_000.0, 1_000.0, 500.0, 100.0, 40.0]
        var frequencies = candidates.filter { $0 <= maximumFrequency }

        if !frequencies.contains(maximumFrequency) {
            frequencies.insert(maximumFrequency, at: 0)
        }

        return frequencies.map { frequency in
            FrequencyMarker(
                label: label(for: frequency),
                topPosition: topPosition(for: frequency, maximumFrequency: maximumFrequency)
            )
        }
    }

    private static func label(for frequency: Double) -> String {
        if frequency >= 1_000 {
            return "\(Int(frequency / 1_000))k"
        }

        return "\(Int(frequency))"
    }

    private static func topPosition(for frequency: Double, maximumFrequency: Double) -> CGFloat {
        let minimumFrequency = 40.0
        let clampedFrequency = min(max(frequency, minimumFrequency), maximumFrequency)
        let ratio = maximumFrequency / minimumFrequency
        guard ratio > 1 else { return 1 }

        let bottomPosition = log(clampedFrequency / minimumFrequency) / log(ratio)
        return CGFloat(1 - bottomPosition)
    }
}

private struct FrequencyMarker: Identifiable {
    let label: String
    let topPosition: CGFloat

    var id: String {
        "\(label)-\(topPosition)"
    }
}

private struct ColorScale: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 1.0, green: 0.08, blue: 0.03),
                        Color(red: 1.0, green: 0.86, blue: 0.03),
                        Color(red: 0.08, green: 0.95, blue: 0.75),
                        Color(red: 0.02, green: 0.24, blue: 0.94),
                        Color(red: 0.01, green: 0.02, blue: 0.25)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(.white.opacity(0.22), lineWidth: 1)
            }
            .frame(width: 10)
    }
}
