//
//  SpectrumPerformanceInstrumentation.swift
//  SystemAudioSpectrogram
//
//  Created by Codex on 2026/06/20.
//

import os

enum SpectrumPerformanceInstrumentation {
    nonisolated static let log = OSLog(subsystem: "SystemAudioSpectrogram", category: "SpectrumPerformance")
}
