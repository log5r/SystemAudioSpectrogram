//
//  SystemAudioSpectrogramTests.swift
//  SystemAudioSpectrogramTests
//
//  Created by Judau on 2026/06/19.
//

import CoreGraphics
import Foundation
import Testing
@testable import SystemAudioSpectrogram

struct SystemAudioSpectrogramTests {

    @Test func spectrumAnalyzerReturnsConfiguredBinCount() throws {
        let analyzer = try #require(SpectrumAnalyzer(windowSize: 2_048, binCount: 96))
        let spectrum = analyzer.analyze(
            samples: Array(repeating: 0, count: 2_048),
            sampleRate: 48_000,
            maximumFrequency: 8_000,
            usesLogarithmicFrequencyScale: false
        )

        #expect(spectrum.count == 96)
        #expect(spectrum.allSatisfy { $0 == 0 })
    }

    @Test func spectrumAnalyzerDetectsToneEnergy() throws {
        let analyzer = try #require(SpectrumAnalyzer(windowSize: 2_048, binCount: 96))
        let sampleRate: Double = 48_000
        let frequency: Double = 1_000
        let samples = (0..<2_048).map { index in
            Float(sin(2 * Double.pi * frequency * Double(index) / sampleRate))
        }

        let spectrum = analyzer.analyze(
            samples: samples,
            sampleRate: sampleRate,
            maximumFrequency: 8_000,
            usesLogarithmicFrequencyScale: false
        )

        #expect((spectrum.max() ?? 0) > 0.5)
        #expect(spectrum.contains { $0 > 0 })
    }

    @Test func spectrogramRendererProducesImageMatchingCapacityAndBins() {
        let renderer = SpectrogramRenderer(capacity: 8, binCount: 4, frameRate: 30)

        renderer.append(values: [1, 1, 1, 1], timestamp: 10)
        let snapshot = renderer.snapshot()

        #expect(snapshot.capacity == 8)
        #expect(snapshot.newestTimestamp == 10)
        #expect(snapshot.image?.width == 8)
        #expect(snapshot.image?.height == 4)
        #expect(snapshot.newestColumn?.width == 1)
        #expect(snapshot.newestColumn?.height == 4)
    }

    @Test func spectrogramRendererScrollsColumnsByElapsedFrames() throws {
        let renderer = SpectrogramRenderer(capacity: 8, binCount: 2, frameRate: 30)

        renderer.append(values: [1, 1], timestamp: 10)
        renderer.append(values: [0, 0], timestamp: 10 + 2.0 / 30.0)

        let image = try #require(renderer.snapshot().image)

        // First column moved two steps left of the newest column; the column
        // between them is bridged with an interpolated value instead of being
        // left as a background stripe.
        #expect(redComponent(of: image, x: image.width - 3, y: 0) > 200)
        #expect(redComponent(of: image, x: image.width - 2, y: 0) > 20)
        #expect(redComponent(of: image, x: image.width - 2, y: 0) < 200)
        #expect(redComponent(of: image, x: image.width - 1, y: 0) < 20)
    }

    @Test func spectrogramRendererScrollsInBackgroundAfterLongStall() throws {
        let renderer = SpectrogramRenderer(capacity: 30, binCount: 2, frameRate: 30)

        renderer.append(values: [1, 1], timestamp: 10)
        renderer.append(values: [1, 1], timestamp: 10 + 10.0 / 30.0)

        let image = try #require(renderer.snapshot().image)

        // A stall beyond the interpolation window means the data really is
        // missing, so the revealed columns stay background.
        #expect(redComponent(of: image, x: image.width - 1, y: 0) > 200)
        #expect(redComponent(of: image, x: image.width - 2, y: 0) < 20)
    }

    @Test func spectrogramRendererSnapsNewestTimestampToColumnGrid() {
        let renderer = SpectrogramRenderer(capacity: 8, binCount: 2, frameRate: 30)

        renderer.append(values: [1, 1], timestamp: 10)
        renderer.append(values: [1, 1], timestamp: 10 + 0.042)

        let snapshot = renderer.snapshot()

        #expect(abs(snapshot.newestTimestamp - (10 + 1.0 / 30.0)) < 1e-9)
    }

    @Test func spectrogramRendererResetClearsImageAndResizes() {
        let renderer = SpectrogramRenderer(capacity: 8, binCount: 4, frameRate: 30)

        renderer.append(values: [1, 1, 1, 1], timestamp: 10)
        renderer.reset(capacity: 16)
        let snapshot = renderer.snapshot()

        #expect(snapshot.image == nil)
        #expect(snapshot.newestColumn == nil)
        #expect(snapshot.capacity == 16)
        #expect(snapshot.newestTimestamp == 0)
        #expect(snapshot.frameRate == 30)
    }

    @Test func spectrogramRendererResetAppliesNewResolution() throws {
        let renderer = SpectrogramRenderer(capacity: 8, binCount: 2, frameRate: 30)

        renderer.reset(capacity: 10, binCount: 4, frameRate: 60)
        renderer.append(values: [1, 1, 1, 1], timestamp: 10)
        renderer.append(values: [1, 1, 1, 1], timestamp: 10 + 1.0 / 60.0)

        let snapshot = renderer.snapshot()

        #expect(snapshot.capacity == 10)
        #expect(snapshot.frameRate == 60)
        #expect(snapshot.image?.width == 10)
        #expect(snapshot.image?.height == 4)
        #expect(snapshot.newestColumn?.height == 4)

        // One 60 Hz frame elapsed, so the timestamp snaps to the finer grid.
        #expect(abs(snapshot.newestTimestamp - (10 + 1.0 / 60.0)) < 1e-9)
    }

    private func redComponent(of image: CGImage, x: Int, y: Int) -> Int {
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else {
            return -1
        }

        return Int(bytes[y * image.bytesPerRow + x * 4])
    }

    @Test func rollingSampleBufferKeepsLatestPlanarSamplesInOrder() {
        var buffer = RollingSampleBuffer(capacity: 5)

        [Float(1), 2].withUnsafeBufferPointer { pointer in
            buffer.appendPlanar(samples: pointer.baseAddress!, sampleCount: pointer.count)
        }
        #expect(buffer.orderedSamples() == [0, 0, 0, 1, 2])

        [Float(3), 4, 5, 6].withUnsafeBufferPointer { pointer in
            buffer.appendPlanar(samples: pointer.baseAddress!, sampleCount: pointer.count)
        }
        #expect(buffer.orderedSamples() == [2, 3, 4, 5, 6])
    }

    @Test func rollingSampleBufferExtractsInterleavedChannelSamples() {
        var buffer = RollingSampleBuffer(capacity: 4)
        let interleaved: [Float] = [
            1, 10,
            2, 20,
            3, 30
        ]

        interleaved.withUnsafeBufferPointer { pointer in
            buffer.appendInterleaved(
                samples: pointer.baseAddress!,
                frameCount: 3,
                channelCount: 2,
                channelIndex: 1
            )
        }

        #expect(buffer.orderedSamples() == [0, 10, 20, 30])
    }

}
