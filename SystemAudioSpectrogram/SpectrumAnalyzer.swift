//
//  SpectrumAnalyzer.swift
//  SystemAudioSpectrogram
//
//  Created by Codex on 2026/06/20.
//

import Foundation
import os

nonisolated final class SpectrumAnalyzer {
    private let analyzer: ObjectiveCSpectrumAnalyzer

    let binCount: Int

    var fftSize: Int {
        analyzer.fftSize
    }

    init?(windowSize: Int, binCount: Int) {
        guard let analyzer = ObjectiveCSpectrumAnalyzer(windowSize: windowSize, binCount: binCount) else {
            return nil
        }

        self.analyzer = analyzer
        self.binCount = binCount
    }

    func analyze(
        samples: [Float],
        sampleRate: Double,
        maximumFrequency: Double,
        usesLogarithmicFrequencyScale: Bool
    ) -> [Float] {
        var spectrum = Array(repeating: Float.zero, count: binCount)
        analyze(
            samples: samples,
            sampleRate: sampleRate,
            maximumFrequency: maximumFrequency,
            usesLogarithmicFrequencyScale: usesLogarithmicFrequencyScale,
            output: &spectrum
        )
        return spectrum
    }

    func analyze(
        samples: [Float],
        sampleRate: Double,
        maximumFrequency: Double,
        usesLogarithmicFrequencyScale: Bool,
        output spectrum: inout [Float]
    ) {
        if spectrum.count != binCount {
            spectrum = Array(repeating: 0, count: binCount)
        }

        let calculationSignpostID = OSSignpostID(log: SpectrumPerformanceInstrumentation.log)

        os_signpost(
            .begin,
            log: SpectrumPerformanceInstrumentation.log,
            name: "Spectrum Calculation",
            signpostID: calculationSignpostID,
            "backend=%{public}s samples=%{public}d fftSize=%{public}d sampleRate=%{public}.1f maxFrequency=%{public}.1f logScale=%{public}d",
            "objective-c++",
            samples.count,
            analyzer.fftSize,
            sampleRate,
            maximumFrequency,
            usesLogarithmicFrequencyScale ? 1 : 0
        )

        guard samples.count >= analyzer.fftSize, sampleRate > 0 else {
            resetSpectrum(&spectrum)
            os_signpost(
                .end,
                log: SpectrumPerformanceInstrumentation.log,
                name: "Spectrum Calculation",
                signpostID: calculationSignpostID,
                "backend=%{public}s status=%{public}s bins=%{public}d",
                "objective-c++",
                "reset",
                binCount
            )
            return
        }

        let analyzed = spectrum.withUnsafeMutableBufferPointer { outputPointer in
            samples.withUnsafeBufferPointer { samplePointer in
                guard let sampleBaseAddress = samplePointer.baseAddress,
                      let outputBaseAddress = outputPointer.baseAddress else {
                    return false
                }

                return analyzer.analyzeSamples(
                    sampleBaseAddress,
                    count: samples.count,
                    sampleRate: sampleRate,
                    maximumFrequency: maximumFrequency,
                    usesLogarithmicFrequencyScale: usesLogarithmicFrequencyScale,
                    output: outputBaseAddress,
                    outputCount: outputPointer.count
                )
            }
        }

        os_signpost(
            .end,
            log: SpectrumPerformanceInstrumentation.log,
            name: "Spectrum Calculation",
            signpostID: calculationSignpostID,
            "backend=%{public}s status=%{public}s bins=%{public}d",
            "objective-c++",
            analyzed ? "ok" : "reset",
            binCount
        )
    }

    private func resetSpectrum(_ spectrum: inout [Float]) {
        for index in spectrum.indices {
            spectrum[index] = 0
        }
    }
}
