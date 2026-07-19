//
//  SystemAudioSpectrumMonitor.swift
//  SystemAudioSpectrogram
//
//  Created by Judau on 2026/06/19.
//

import Accelerate
import Combine
import CoreAudio
import Foundation
import OSLog

private struct SpectrumSnapshot: Sendable {
    let timestamp: TimeInterval
    let left: [Float]
    let right: [Float]
}

private struct SpectrumAnalysisRequest {
    let generation: Int
    let timestamp: TimeInterval
    let sampleRate: Double
    let maximumFrequency: Double
    let usesLogarithmicFrequencyScale: Bool
    let binCount: Int
    let analysisWindowSize: Int
    let leftSamples: [Float]
    let rightSamples: [Float]
}

nonisolated struct RollingSampleBuffer {
    private var storage: [Float]
    private var writeIndex = 0

    let capacity: Int

    init(capacity: Int) {
        self.capacity = Swift.max(0, capacity)
        self.storage = Array(repeating: 0, count: self.capacity)
    }

    mutating func reset() {
        guard capacity > 0 else { return }

        for index in storage.indices {
            storage[index] = 0
        }
        writeIndex = 0
    }

    mutating func appendPlanar(samples: UnsafePointer<Float>, sampleCount: Int) {
        guard capacity > 0, sampleCount > 0 else { return }

        if sampleCount >= capacity {
            let sourceStart = sampleCount - capacity
            for index in 0..<capacity {
                storage[index] = samples[sourceStart + index]
            }
            writeIndex = 0
            return
        }

        for index in 0..<sampleCount {
            storage[writeIndex] = samples[index]
            writeIndex = (writeIndex + 1) % capacity
        }
    }

    mutating func appendInterleaved(
        samples: UnsafePointer<Float>,
        frameCount: Int,
        channelCount: Int,
        channelIndex: Int
    ) {
        guard capacity > 0, frameCount > 0, channelCount > 0 else { return }

        if frameCount >= capacity {
            let sourceStart = frameCount - capacity
            for index in 0..<capacity {
                storage[index] = samples[(sourceStart + index) * channelCount + channelIndex]
            }
            writeIndex = 0
            return
        }

        for frame in 0..<frameCount {
            storage[writeIndex] = samples[frame * channelCount + channelIndex]
            writeIndex = (writeIndex + 1) % capacity
        }
    }

    func orderedSamples() -> [Float] {
        guard capacity > 0 else { return [] }

        var samples = Array(repeating: Float.zero, count: capacity)
        let tailCount = capacity - writeIndex

        for index in 0..<tailCount {
            samples[index] = storage[writeIndex + index]
        }

        guard writeIndex > 0 else { return samples }

        for index in 0..<writeIndex {
            samples[tailCount + index] = storage[index]
        }

        return samples
    }
}

/// Publishes the 30 Hz meter values separately from the monitor so only the
/// small views that actually display levels re-render on every audio frame.
/// Routing these through the monitor's own `objectWillChange` invalidated the
/// whole `ContentView` — including platform-backed buttons and segmented
/// pickers whose re-measurement cost grows over time inside AppKit's
/// observation registrar, which slowly dragged the app below 60 fps.
@MainActor
final class AudioLevelReadouts: ObservableObject {
    @Published private(set) var leftLevel = 0.0
    @Published private(set) var rightLevel = 0.0
    @Published private(set) var leftPeak = 0.0
    @Published private(set) var rightPeak = 0.0

    var leftDecibelsText: String {
        Self.decibelsText(for: leftLevel)
    }

    var rightDecibelsText: String {
        Self.decibelsText(for: rightLevel)
    }

    var peakDecibelsText: String {
        Self.decibelsText(for: max(leftPeak, rightPeak))
    }

    fileprivate func apply(_ levels: AudioLevels) {
        let left = Self.meterValue(forLinearAmplitude: levels.leftRMS)
        let right = Self.meterValue(forLinearAmplitude: levels.rightRMS)
        let leftTransient = Self.meterValue(forLinearAmplitude: levels.leftPeak)
        let rightTransient = Self.meterValue(forLinearAmplitude: levels.rightPeak)

        leftLevel = smooth(current: leftLevel, target: left)
        rightLevel = smooth(current: rightLevel, target: right)
        leftPeak = max(leftTransient, leftPeak * 0.975)
        rightPeak = max(rightTransient, rightPeak * 0.975)
    }

    fileprivate func reset() {
        leftLevel = 0
        rightLevel = 0
        leftPeak = 0
        rightPeak = 0
    }

    private func smooth(current: Double, target: Double) -> Double {
        current + (target - current) * (target > current ? 0.55 : 0.16)
    }

    private static func decibelsText(for level: Double) -> String {
        guard level > 0.01 else { return "-inf dB" }

        let decibels = level * 60 - 60
        return "\(Int(decibels.rounded())) dB"
    }

    private static func meterValue(forLinearAmplitude amplitude: Double) -> Double {
        let clamped = max(amplitude, 0.000_001)
        let decibels = 20 * log10(clamped)
        return min(1, max(0, (decibels + 60) / 60))
    }
}

@MainActor
final class SystemAudioSpectrumMonitor: ObservableObject {
    let levels = AudioLevelReadouts()
    nonisolated let leftSpectrogram = SpectrogramRenderer(
        capacity: 180,
        binCount: SystemAudioSpectrumMonitor.spectrumBinCount,
        frameRate: SystemAudioSpectrumMonitor.spectrumFrameRate
    )
    nonisolated let rightSpectrogram = SpectrogramRenderer(
        capacity: 180,
        binCount: SystemAudioSpectrumMonitor.spectrumBinCount,
        frameRate: SystemAudioSpectrumMonitor.spectrumFrameRate
    )
    @Published private(set) var isRunning = false
    @Published private(set) var isPreviewing = false
    @Published private(set) var statusText = "Starting system audio capture..."

    nonisolated static let spectrumBinCount = 96
    nonisolated static let spectrumFrameRate = 30.0
    nonisolated static let defaultSpectrumMaximumFrequency = 8_000.0
    nonisolated static let defaultSpectrumAnalysisWindowSize = 2_048

    private var spectrumHistoryLimit = 180
    private var spectrumMaximumFrequency = defaultSpectrumMaximumFrequency
    private var usesLogarithmicSpectrumScale = false
    private var spectrumDisplayBinCount = SystemAudioSpectrumMonitor.spectrumBinCount
    private var spectrumDisplayFrameRate = SystemAudioSpectrumMonitor.spectrumFrameRate
    private var spectrumAnalysisWindowSize = SystemAudioSpectrumMonitor.defaultSpectrumAnalysisWindowSize
    private var audioCapture: ProcessTapAudioCapture?
    private let output = AudioStreamOutput()
    private var levelDelivery: MainActorCoalescedDelivery<AudioLevels>!

    init() {
        levelDelivery = MainActorCoalescedDelivery { [weak self] levels in
            self?.levels.apply(levels)
        }

        let levelDelivery = levelDelivery!

        output.onLevels = { levels in
            levelDelivery.submit(levels)
        }

        output.onError = { [weak self] message in
            Task { @MainActor in
                self?.statusText = message
                self?.isRunning = false
                self?.levelDelivery.clear()
                self?.output.stopSpectrumAnalysis()
            }
        }

        // Runs on the audio queue: the spectrogram bitmap is updated off the
        // main actor, so the UI only ever reads finished images.
        output.onSpectrumFrame = { [leftSpectrogram, rightSpectrogram] snapshot in
            leftSpectrogram.append(values: snapshot.left, timestamp: snapshot.timestamp)
            rightSpectrogram.append(values: snapshot.right, timestamp: snapshot.timestamp)
        }
    }

    func start() async {
        guard !isRunning else { return }

        isPreviewing = false
        statusText = "Preparing system audio capture..."

        do {
            let audioCapture = ProcessTapAudioCapture(output: output)
            try audioCapture.start()

            self.audioCapture = audioCapture
            isRunning = true
            statusText = "Listening to system audio"
            output.startSpectrumAnalysis()
        } catch {
            statusText = userFacingMessage(for: error)
            isRunning = false
            self.audioCapture = nil
            output.stopSpectrumAnalysis()
        }
    }

    func stop() {
        output.stopSpectrumAnalysis()
        isPreviewing = false

        guard let audioCapture else {
            isRunning = false
            statusText = "Stopped"
            resetLevels()
            return
        }

        self.audioCapture = nil
        audioCapture.stop()
        isRunning = false
        statusText = "Stopped"
        resetLevels()
    }

    func updateSpectrumSettings(maximumFrequency: Double, historyLimit: Int) {
        updateSpectrumSettings(
            maximumFrequency: maximumFrequency,
            historyLimit: historyLimit,
            usesLogarithmicFrequencyScale: false
        )
    }

    func updateSpectrumSettings(
        maximumFrequency: Double,
        historyLimit: Int,
        usesLogarithmicFrequencyScale: Bool,
        binCount: Int = SystemAudioSpectrumMonitor.spectrumBinCount,
        frameRate: Double = SystemAudioSpectrumMonitor.spectrumFrameRate,
        analysisWindowSize: Int = SystemAudioSpectrumMonitor.defaultSpectrumAnalysisWindowSize
    ) {
        let sanitizedFrequency = max(1_000, maximumFrequency)
        let sanitizedHistoryLimit = max(30, historyLimit)
        let sanitizedBinCount = max(16, binCount)
        let sanitizedFrameRate = min(120, max(1, frameRate))
        let sanitizedWindowSize = min(AudioStreamOutput.maximumSpectrumWindowSize, max(256, analysisWindowSize))
        let shouldReset = self.spectrumMaximumFrequency != sanitizedFrequency
            || self.usesLogarithmicSpectrumScale != usesLogarithmicFrequencyScale
            || self.spectrumHistoryLimit != sanitizedHistoryLimit
            || self.spectrumDisplayBinCount != sanitizedBinCount
            || self.spectrumDisplayFrameRate != sanitizedFrameRate
            || self.spectrumAnalysisWindowSize != sanitizedWindowSize

        self.spectrumMaximumFrequency = sanitizedFrequency
        self.usesLogarithmicSpectrumScale = usesLogarithmicFrequencyScale
        self.spectrumHistoryLimit = sanitizedHistoryLimit
        self.spectrumDisplayBinCount = sanitizedBinCount
        self.spectrumDisplayFrameRate = sanitizedFrameRate
        self.spectrumAnalysisWindowSize = sanitizedWindowSize
        output.updateSpectrumSettings(
            maximumFrequency: sanitizedFrequency,
            usesLogarithmicFrequencyScale: usesLogarithmicFrequencyScale,
            binCount: sanitizedBinCount,
            frameRate: sanitizedFrameRate,
            analysisWindowSize: sanitizedWindowSize
        )

        if shouldReset {
            resetSpectrum()
        }
    }

#if DEBUG
    /// Supplies deterministic data for UI screenshots without requesting
    /// system-audio permission or recording any audio.
    func loadPreviewSpectrogram() {
        resetSpectrum()

        let frameCount = spectrumHistoryLimit
        let binCount = spectrumDisplayBinCount
        let frameRate = spectrumDisplayFrameRate
        let startTime = Date.timeIntervalSinceReferenceDate + 5 - Double(frameCount) / frameRate

        for frame in 0..<frameCount {
            let progress = Double(frame) / Double(max(1, frameCount - 1))
            let timestamp = startTime + Double(frame) / frameRate

            let left = Self.previewSpectrum(
                progress: progress,
                binCount: binCount,
                phaseOffset: 0
            )
            let right = Self.previewSpectrum(
                progress: progress,
                binCount: binCount,
                phaseOffset: 0.18
            )

            leftSpectrogram.append(values: left, timestamp: timestamp)
            rightSpectrogram.append(values: right, timestamp: timestamp)
        }

        levels.apply(AudioLevels(leftRMS: 0.28, rightRMS: 0.24, leftPeak: 0.62, rightPeak: 0.56))
        isPreviewing = true
        isRunning = true
        statusText = "Previewing sample spectrum"
    }

    private static func previewSpectrum(
        progress: Double,
        binCount: Int,
        phaseOffset: Double
    ) -> [Float] {
        let movingCenter = 0.16 + 0.56 * (0.5 + 0.5 * sin((progress + phaseOffset) * .pi * 2.2))

        return (0..<binCount).map { index in
            let position = Double(index) / Double(max(1, binCount - 1))
            let fundamental = exp(-pow((position - movingCenter) / 0.028, 2))
            let harmonic = 0.58 * exp(-pow((position - min(0.96, movingCenter * 1.72)) / 0.022, 2))
            let pulse = 0.34 * exp(-pow((progress - 0.66) / 0.055, 2))
                * exp(-pow((position - 0.42) / 0.15, 2))
            let texture = 0.045 * (1 + sin(position * 91 + progress * 37 + phaseOffset * 11))
            return Float(min(1, fundamental + harmonic + pulse + texture))
        }
    }
#endif

    private func resetLevels() {
        levels.reset()
        resetSpectrum()
    }

    private func resetSpectrum() {
        leftSpectrogram.reset(
            capacity: spectrumHistoryLimit,
            binCount: spectrumDisplayBinCount,
            frameRate: spectrumDisplayFrameRate
        )
        rightSpectrogram.reset(
            capacity: spectrumHistoryLimit,
            binCount: spectrumDisplayBinCount,
            frameRate: spectrumDisplayFrameRate
        )
        output.resetRollingSamples()
    }

    private func userFacingMessage(for error: Error) -> String {
        if let captureError = error as? ProcessTapAudioCapture.CaptureError {
            return captureError.localizedDescription
        }

        return error.localizedDescription
    }
}

private struct AudioLevels: Sendable {
    let leftRMS: Double
    let rightRMS: Double
    let leftPeak: Double
    let rightPeak: Double

    nonisolated func mergingPeaks(with other: AudioLevels) -> AudioLevels {
        AudioLevels(
            leftRMS: max(leftRMS, other.leftRMS),
            rightRMS: max(rightRMS, other.rightRMS),
            leftPeak: max(leftPeak, other.leftPeak),
            rightPeak: max(rightPeak, other.rightPeak)
        )
    }
}

nonisolated final class MainActorCoalescedDelivery<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingValue: Value?
    private var isScheduled = false
    private let deliver: @MainActor (Value) -> Void

    init(deliver: @escaping @MainActor (Value) -> Void) {
        self.deliver = deliver
    }

    nonisolated func submit(_ value: Value) {
        lock.lock()
        pendingValue = value

        guard !isScheduled else {
            lock.unlock()
            return
        }

        isScheduled = true
        lock.unlock()

        Task { @MainActor [weak self] in
            self?.drainPendingValues()
        }
    }

    nonisolated func clear() {
        lock.lock()
        pendingValue = nil
        lock.unlock()
    }

    @MainActor
    private func drainPendingValues() {
        while true {
            lock.lock()

            guard let value = pendingValue else {
                isScheduled = false
                lock.unlock()
                return
            }

            pendingValue = nil
            lock.unlock()

            deliver(value)
        }
    }
}

private struct CapturedAudioFrame: @unchecked Sendable {
    let streamDescription: AudioStreamBasicDescription
    let buffers: [[Float]]
    let channelCounts: [Int]
}

private final class ProcessTapAudioCapture {
    enum CaptureError: LocalizedError {
        case coreAudio(operation: String, status: OSStatus)
        case missingTapUID
        case unsupportedFormat

        var errorDescription: String? {
            switch self {
            case let .coreAudio(operation, status):
                return "\(operation) failed (\(Self.describe(status: status)))"
            case .missingTapUID:
                return "Could not read the system audio tap identifier"
            case .unsupportedFormat:
                return "System audio capture returned an unsupported audio format"
            }
        }

        private static func describe(status: OSStatus) -> String {
            let code = UInt32(bitPattern: status)
            let scalars = [
                UInt8((code >> 24) & 0xff),
                UInt8((code >> 16) & 0xff),
                UInt8((code >> 8) & 0xff),
                UInt8(code & 0xff)
            ]

            if scalars.allSatisfy({ $0 >= 32 && $0 < 127 }) {
                return "'\(String(bytes: scalars, encoding: .ascii) ?? "")', \(status)"
            }

            return "\(status)"
        }
    }

    private nonisolated(unsafe) var tapID = AudioObjectID(kAudioObjectUnknown)
    private nonisolated(unsafe) var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private nonisolated(unsafe) var ioProcID: AudioDeviceIOProcID?
    private nonisolated(unsafe) var streamDescription = AudioStreamBasicDescription()
    private let output: AudioStreamOutput

    init(output: AudioStreamOutput) {
        self.output = output
    }

    deinit {
        stop()
    }

    func start() throws {
        stop()

        let tapDescription = CATapDescription(
            stereoGlobalTapButExcludeProcesses: Self.currentProcessObjectID().map { [$0] } ?? []
        )
        tapDescription.name = "SystemAudioSpectrogram System Audio"
        tapDescription.uuid = UUID()
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = CATapMuteBehavior.unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        try Self.check(
            AudioHardwareCreateProcessTap(tapDescription, &newTapID),
            operation: "Create system audio tap"
        )
        tapID = newTapID

        do {
            streamDescription = try Self.tapFormat(for: tapID)
            guard streamDescription.mFormatID == kAudioFormatLinearPCM,
                  streamDescription.mBitsPerChannel == 32,
                  streamDescription.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
                throw CaptureError.unsupportedFormat
            }

            let tapUID = try Self.tapUID(for: tapID)
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "SystemAudioSpectrogram System Audio",
                kAudioAggregateDeviceUIDKey: "io.github.log5r.SystemAudioSpectrogram.tap.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true
                ]]
            ]

            var newAggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
            try Self.check(
                AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateDeviceID),
                operation: "Create system audio capture device"
            )
            aggregateDeviceID = newAggregateDeviceID

            var newIOProcID: AudioDeviceIOProcID?
            try Self.check(
                AudioDeviceCreateIOProcID(
                    aggregateDeviceID,
                    processTapIOProc,
                    Unmanaged.passUnretained(self).toOpaque(),
                    &newIOProcID
                ),
                operation: "Create system audio IO callback"
            )
            ioProcID = newIOProcID

            try Self.check(
                AudioDeviceStart(aggregateDeviceID, ioProcID),
                operation: "Start system audio capture"
            )
        } catch {
            stop()
            throw error
        }
    }

    nonisolated func stop() {
        if let ioProcID, aggregateDeviceID != kAudioObjectUnknown {
            _ = AudioDeviceStop(aggregateDeviceID, ioProcID)
            _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
        }

        ioProcID = nil

        if aggregateDeviceID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }

        if tapID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    nonisolated func captureAudioBuffers(_ bufferList: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        let frameBuffers = buffers.map { buffer -> [Float] in
            guard let data = buffer.mData else { return [] }

            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let samples = data.bindMemory(to: Float.self, capacity: sampleCount)
            return Array(UnsafeBufferPointer(start: samples, count: sampleCount))
        }

        let channelCounts = buffers.map { Int($0.mNumberChannels) }
        output.processCapturedAudioFrame(
            CapturedAudioFrame(
                streamDescription: streamDescription,
                buffers: frameBuffers,
                channelCounts: channelCounts
            )
        )
    }

    private static func currentProcessObjectID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = getpid()
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = withUnsafePointer(to: &pid) { pidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                pidPointer,
                &dataSize,
                &processObjectID
            )
        }

        guard status == noErr, processObjectID != kAudioObjectUnknown else {
            return nil
        }

        return processObjectID
    }

    private static func tapFormat(for tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &dataSize, &format),
            operation: "Read system audio tap format"
        )
        return format
    }

    private static func tapUID(for tapID: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanagedUID: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &dataSize, &unmanagedUID),
            operation: "Read system audio tap identifier"
        )

        guard let uid = unmanagedUID?.takeRetainedValue() else {
            throw CaptureError.missingTapUID
        }

        return uid as String
    }

    private static func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw CaptureError.coreAudio(operation: operation, status: status)
        }
    }
}

private let processTapIOProc: AudioDeviceIOProc = { _, _, inputData, _, _, _, clientData in
    guard let clientData else { return noErr }

    let capture = Unmanaged<ProcessTapAudioCapture>.fromOpaque(clientData).takeUnretainedValue()
    capture.captureAudioBuffers(inputData)
    return noErr
}

private final class AudioStreamOutput: NSObject {
    nonisolated static let spectrumWindowSize = SystemAudioSpectrumMonitor.defaultSpectrumAnalysisWindowSize
    /// Rolling sample buffers are sized for the largest supported analysis
    /// window so the window size can change without reallocating them.
    nonisolated static let maximumSpectrumWindowSize = 4_096
    private nonisolated static let levelFrameIntervalNanoseconds = UInt64(1_000_000_000 / SystemAudioSpectrumMonitor.spectrumFrameRate)
    private nonisolated static let transientSpectrumFrameIntervalNanoseconds: UInt64 = 80_000_000
    private nonisolated static let transientPeakThreshold = 0.02

    nonisolated let queue = DispatchQueue(label: "SystemAudioSpectrogram.audio")
    private let analysisQueue = DispatchQueue(label: "SystemAudioSpectrogram.spectrum-analysis")

    nonisolated(unsafe) var onLevels: ((AudioLevels) -> Void)?
    nonisolated(unsafe) var onError: ((String) -> Void)?
    nonisolated(unsafe) var onSpectrumFrame: ((SpectrumSnapshot) -> Void)?
    private nonisolated(unsafe) var spectrumMaximumFrequency = SystemAudioSpectrumMonitor.defaultSpectrumMaximumFrequency
    private nonisolated(unsafe) var usesLogarithmicSpectrumScale = false
    private nonisolated(unsafe) var spectrumBinCount = SystemAudioSpectrumMonitor.spectrumBinCount
    private nonisolated(unsafe) var spectrumAnalysisWindowSize = AudioStreamOutput.spectrumWindowSize
    private nonisolated(unsafe) var spectrumFrameIntervalNanoseconds = UInt64(1_000_000_000 / SystemAudioSpectrumMonitor.spectrumFrameRate)

    // Rolling sample history per channel + cached sample rate.
    // All only accessed inside `queue` (serial), so safe.
    private nonisolated(unsafe) var leftRollingSamples: RollingSampleBuffer
    private nonisolated(unsafe) var rightRollingSamples: RollingSampleBuffer
    private nonisolated(unsafe) var leftSpectrumOutput: [Float]
    private nonisolated(unsafe) var rightSpectrumOutput: [Float]
    private nonisolated(unsafe) var cachedSampleRate: Double = 48_000
    private nonisolated(unsafe) var spectrumAnalyzer: SpectrumAnalyzer?
    private nonisolated(unsafe) var isSpectrumAnalysisEnabled = false
    private nonisolated(unsafe) var isSpectrumAnalysisScheduled = false
    private nonisolated(unsafe) var pendingLevels: AudioLevels?
    private nonisolated(unsafe) var nextLevelDeliveryNanoseconds: UInt64 = 0
    private nonisolated(unsafe) var nextSpectrumAnalysisNanoseconds: UInt64 = 0
    private nonisolated(unsafe) var nextTransientSpectrumAnalysisNanoseconds: UInt64 = 0
    private nonisolated(unsafe) var spectrumGeneration = 0

    override init() {
        let spectrumZeros = [Float](repeating: 0, count: SystemAudioSpectrumMonitor.spectrumBinCount)
        self.leftRollingSamples = RollingSampleBuffer(capacity: AudioStreamOutput.maximumSpectrumWindowSize)
        self.rightRollingSamples = RollingSampleBuffer(capacity: AudioStreamOutput.maximumSpectrumWindowSize)
        self.leftSpectrumOutput = spectrumZeros
        self.rightSpectrumOutput = spectrumZeros
        self.spectrumAnalyzer = SpectrumAnalyzer(
            windowSize: AudioStreamOutput.spectrumWindowSize,
            binCount: SystemAudioSpectrumMonitor.spectrumBinCount
        )
        super.init()
    }

    nonisolated func processCapturedAudioFrame(_ frame: CapturedAudioFrame) {
        queue.async { [weak self] in
            self?.handleCapturedAudioFrame(frame)
        }
    }

    private nonisolated func handleCapturedAudioFrame(_ frame: CapturedAudioFrame) {
        let signpostID = OSSignpostID(log: SpectrumPerformanceInstrumentation.log)

        os_signpost(
            .begin,
            log: SpectrumPerformanceInstrumentation.log,
            name: "Audio Callback Handling",
            signpostID: signpostID
        )
        defer {
            os_signpost(
                .end,
                log: SpectrumPerformanceInstrumentation.log,
                name: "Audio Callback Handling",
                signpostID: signpostID
            )
        }

        guard let levels = calculateLevels(from: frame) else { return }

        let now = DispatchTime.now().uptimeNanoseconds
        deliverLevelsIfNeeded(levels, now: now)
        scheduleSpectrumAnalysisIfNeeded(
            now: now,
            force: shouldForceSpectrumAnalysis(for: levels, now: now)
        )
    }

    func startSpectrumAnalysis() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isSpectrumAnalysisEnabled = true
            self.isSpectrumAnalysisScheduled = false
            self.pendingLevels = nil
            self.nextLevelDeliveryNanoseconds = 0
            self.nextSpectrumAnalysisNanoseconds = 0
            self.nextTransientSpectrumAnalysisNanoseconds = 0
            self.spectrumGeneration &+= 1
        }
    }

    func stopSpectrumAnalysis() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isSpectrumAnalysisEnabled = false
            self.isSpectrumAnalysisScheduled = false
            self.pendingLevels = nil
            self.nextLevelDeliveryNanoseconds = 0
            self.nextSpectrumAnalysisNanoseconds = 0
            self.nextTransientSpectrumAnalysisNanoseconds = 0
            self.spectrumGeneration &+= 1
        }
    }

    func updateSpectrumSettings(
        maximumFrequency: Double,
        usesLogarithmicFrequencyScale: Bool,
        binCount: Int = SystemAudioSpectrumMonitor.spectrumBinCount,
        frameRate: Double = SystemAudioSpectrumMonitor.spectrumFrameRate,
        analysisWindowSize: Int = AudioStreamOutput.spectrumWindowSize
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.spectrumMaximumFrequency = maximumFrequency
            self.usesLogarithmicSpectrumScale = usesLogarithmicFrequencyScale
            self.spectrumBinCount = max(1, binCount)
            self.spectrumAnalysisWindowSize = min(Self.maximumSpectrumWindowSize, max(64, analysisWindowSize))
            self.spectrumFrameIntervalNanoseconds = UInt64(1_000_000_000 / min(120, max(1, frameRate)))
            self.nextSpectrumAnalysisNanoseconds = 0
            self.spectrumGeneration &+= 1
        }
    }

    func resetRollingSamples() {
        queue.async { [weak self] in
            guard let self else { return }
            self.leftRollingSamples.reset()
            self.rightRollingSamples.reset()
            self.pendingLevels = nil
            self.nextLevelDeliveryNanoseconds = 0
            self.nextSpectrumAnalysisNanoseconds = 0
            self.nextTransientSpectrumAnalysisNanoseconds = 0
            self.spectrumGeneration &+= 1
        }
    }

    private nonisolated func deliverLevelsIfNeeded(_ levels: AudioLevels, now: UInt64) {
        pendingLevels = pendingLevels?.mergingPeaks(with: levels) ?? levels
        guard now >= nextLevelDeliveryNanoseconds else { return }

        nextLevelDeliveryNanoseconds = now + Self.levelFrameIntervalNanoseconds
        onLevels?(pendingLevels ?? levels)
        pendingLevels = nil
    }

    private nonisolated func shouldForceSpectrumAnalysis(for levels: AudioLevels, now: UInt64) -> Bool {
        guard now >= nextTransientSpectrumAnalysisNanoseconds else { return false }

        let peak = max(levels.leftPeak, levels.rightPeak)
        guard peak >= Self.transientPeakThreshold else { return false }

        nextTransientSpectrumAnalysisNanoseconds = now + Self.transientSpectrumFrameIntervalNanoseconds
        return true
    }

    private nonisolated func scheduleSpectrumAnalysisIfNeeded(now: UInt64, force: Bool) {
        guard isSpectrumAnalysisEnabled else { return }
        guard !isSpectrumAnalysisScheduled else { return }

        let isDue = now >= nextSpectrumAnalysisNanoseconds
        guard force || isDue else { return }

        isSpectrumAnalysisScheduled = true

        if isDue {
            // Advance the deadline on its own frame-rate grid instead of
            // anchoring it to `now`. Audio callbacks arrive on a coarser
            // cadence than the analysis interval, so `now + interval` would
            // quantize the effective rate below the display's column grid,
            // leaving unwritten background columns between frames.
            let interval = spectrumFrameIntervalNanoseconds
            if nextSpectrumAnalysisNanoseconds == 0 {
                nextSpectrumAnalysisNanoseconds = now + interval
            } else {
                let missedIntervals = (now - nextSpectrumAnalysisNanoseconds) / interval
                nextSpectrumAnalysisNanoseconds += (missedIntervals + 1) * interval
            }
        }

        let request = SpectrumAnalysisRequest(
            generation: spectrumGeneration,
            timestamp: Date().timeIntervalSinceReferenceDate,
            sampleRate: cachedSampleRate,
            maximumFrequency: spectrumMaximumFrequency,
            usesLogarithmicFrequencyScale: usesLogarithmicSpectrumScale,
            binCount: spectrumBinCount,
            analysisWindowSize: spectrumAnalysisWindowSize,
            leftSamples: leftRollingSamples.orderedSamples(),
            rightSamples: rightRollingSamples.orderedSamples()
        )

        analysisQueue.async { [weak self] in
            self?.finishSpectrumAnalysis(request)
        }
    }

    private nonisolated func finishSpectrumAnalysis(_ request: SpectrumAnalysisRequest) {
        let signpostID = OSSignpostID(log: SpectrumPerformanceInstrumentation.log)

        os_signpost(
            .begin,
            log: SpectrumPerformanceInstrumentation.log,
            name: "Spectrum Snapshot",
            signpostID: signpostID
        )

        // The analyzer lives on the analysis queue; rebuild it when the
        // requested resolution no longer matches its FFT size or bin count.
        if spectrumAnalyzer == nil
            || spectrumAnalyzer?.binCount != request.binCount
            || spectrumAnalyzer?.fftSize != request.analysisWindowSize {
            spectrumAnalyzer = SpectrumAnalyzer(
                windowSize: request.analysisWindowSize,
                binCount: request.binCount
            )
        }

        guard let analyzer = spectrumAnalyzer else {
            os_signpost(
                .end,
                log: SpectrumPerformanceInstrumentation.log,
                name: "Spectrum Snapshot",
                signpostID: signpostID,
                "status=%{public}s",
                "analyzer-unavailable"
            )
            finishSpectrumAnalysisRequest(request, snapshot: nil)
            return
        }

        analyzer.analyze(
            samples: request.leftSamples,
            sampleRate: request.sampleRate,
            maximumFrequency: request.maximumFrequency,
            usesLogarithmicFrequencyScale: request.usesLogarithmicFrequencyScale,
            output: &leftSpectrumOutput
        )
        analyzer.analyze(
            samples: request.rightSamples,
            sampleRate: request.sampleRate,
            maximumFrequency: request.maximumFrequency,
            usesLogarithmicFrequencyScale: request.usesLogarithmicFrequencyScale,
            output: &rightSpectrumOutput
        )

        os_signpost(
            .end,
            log: SpectrumPerformanceInstrumentation.log,
            name: "Spectrum Snapshot",
            signpostID: signpostID,
            "sampleRate=%{public}.1f maxFrequency=%{public}.1f logScale=%{public}d leftBins=%{public}d rightBins=%{public}d",
            request.sampleRate,
            request.maximumFrequency,
            request.usesLogarithmicFrequencyScale ? 1 : 0,
            leftSpectrumOutput.count,
            rightSpectrumOutput.count
        )

        finishSpectrumAnalysisRequest(
            request,
            snapshot: SpectrumSnapshot(
                timestamp: request.timestamp,
                left: leftSpectrumOutput,
                right: rightSpectrumOutput
            )
        )
    }

    private nonisolated func finishSpectrumAnalysisRequest(
        _ request: SpectrumAnalysisRequest,
        snapshot: SpectrumSnapshot?
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.isSpectrumAnalysisScheduled = false

            guard self.isSpectrumAnalysisEnabled,
                  request.generation == self.spectrumGeneration,
                  let snapshot else {
                return
            }

            self.onSpectrumFrame?(snapshot)
        }
    }

    private nonisolated func calculateLevels(from frame: CapturedAudioFrame) -> AudioLevels? {
        let streamDescription = frame.streamDescription
        guard streamDescription.mFormatID == kAudioFormatLinearPCM else { return nil }
        guard streamDescription.mBitsPerChannel == 32 else { return nil }

        let isFloat = streamDescription.mFormatFlags & kAudioFormatFlagIsFloat != 0
        guard isFloat else { return nil }

        cachedSampleRate = streamDescription.mSampleRate

        let firstBufferChannelCount = frame.channelCounts.first ?? Int(streamDescription.mChannelsPerFrame)
        if frame.buffers.count == 1 || firstBufferChannelCount > 1 {
            return calculateInterleavedLevels(
                from: frame.buffers.first ?? [],
                channelCount: max(1, firstBufferChannelCount)
            )
        }

        return calculatePlanarLevels(from: frame.buffers)
    }

    private nonisolated func calculateInterleavedLevels(
        from samples: [Float],
        channelCount: Int
    ) -> AudioLevels? {
        guard channelCount > 0 else { return nil }

        let frameCount = samples.count / channelCount
        guard frameCount > 0 else { return nil }

        var leftSum = 0.0
        var rightSum = 0.0
        var leftPeak = 0.0
        var rightPeak = 0.0

        for frame in 0..<frameCount {
            let leftSample = Double(samples[frame * channelCount])
            let rightSample = channelCount > 1 ? Double(samples[frame * channelCount + 1]) : leftSample

            leftSum += leftSample * leftSample
            rightSum += rightSample * rightSample
            leftPeak = max(leftPeak, abs(leftSample))
            rightPeak = max(rightPeak, abs(rightSample))
        }

        samples.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }

            appendInterleavedRollingSamples(
                &leftRollingSamples,
                samples: baseAddress,
                frameCount: frameCount,
                channelCount: channelCount,
                channelIndex: 0
            )
            appendInterleavedRollingSamples(
                &rightRollingSamples,
                samples: baseAddress,
                frameCount: frameCount,
                channelCount: channelCount,
                channelIndex: channelCount > 1 ? 1 : 0
            )
        }

        return AudioLevels(
            leftRMS: sqrt(leftSum / Double(frameCount)),
            rightRMS: sqrt(rightSum / Double(frameCount)),
            leftPeak: leftPeak,
            rightPeak: rightPeak
        )
    }

    private nonisolated func calculatePlanarLevels(
        from buffers: [[Float]]
    ) -> AudioLevels? {
        guard !buffers.isEmpty else { return nil }

        guard let left = calculatePlanarChannelLevels(
            from: buffers[0],
            rollingSamples: &leftRollingSamples
        ) else {
            return nil
        }
        let right = buffers.count > 1
            ? calculatePlanarChannelLevels(from: buffers[1], rollingSamples: &rightRollingSamples)
            : calculatePlanarChannelLevels(from: buffers[0], rollingSamples: &rightRollingSamples)

        guard let right else { return nil }

        return AudioLevels(
            leftRMS: left.rms,
            rightRMS: right.rms,
            leftPeak: left.peak,
            rightPeak: right.peak
        )
    }

    private nonisolated func calculatePlanarChannelLevels(
        from samples: [Float],
        rollingSamples: inout RollingSampleBuffer
    ) -> (rms: Double, peak: Double)? {
        let sampleCount = samples.count
        guard sampleCount > 0 else { return nil }

        var sum = 0.0
        var peak = 0.0

        for index in 0..<sampleCount {
            let sample = Double(samples[index])
            let magnitude = abs(sample)
            sum += sample * sample
            peak = max(peak, magnitude)
        }

        samples.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            rollingSamples.appendPlanar(samples: baseAddress, sampleCount: sampleCount)
        }

        return (sqrt(sum / Double(sampleCount)), peak)
    }

    private nonisolated func appendInterleavedRollingSamples(
        _ buffer: inout RollingSampleBuffer,
        samples: UnsafePointer<Float>,
        frameCount: Int,
        channelCount: Int,
        channelIndex: Int
    ) {
        buffer.appendInterleaved(
            samples: samples,
            frameCount: frameCount,
            channelCount: channelCount,
            channelIndex: channelIndex
        )
    }

}
