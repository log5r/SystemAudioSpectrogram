//
//  SpectrogramRenderer.swift
//  SystemAudioSpectrogram
//
//  Created by Claude on 2026/07/02.
//

import CoreGraphics
import Foundation
import os

/// Maintains a scrolling spectrogram bitmap with one pixel column per analysis frame.
///
/// Appending a spectrum frame writes a single column into a persistent
/// `CGBitmapContext`, so display code only has to draw one `CGImage` per
/// screen refresh. Display cost is independent of history length, which is
/// what allows a stable 60 fps scroll regardless of how long the app runs.
///
/// Thread safety: appends run on the audio queue while snapshots are taken
/// from the render loop, so all state is guarded by a lock.
nonisolated final class SpectrogramRenderer: @unchecked Sendable {
    struct Snapshot {
        let image: CGImage?
        /// 1-pixel-wide crop of the newest column, prepared once per append
        /// so the display doesn't have to crop on every screen refresh.
        let newestColumn: CGImage?
        let newestTimestamp: TimeInterval
        let capacity: Int
        /// Analysis frames (columns) per second; the display derives column
        /// width and scroll speed from this so resolution changes don't need
        /// separate plumbing through the view tree.
        let frameRate: Double
    }

    /// Matches the Canvas background so image edges blend seamlessly.
    static let backgroundComponents: (red: Double, green: Double, blue: Double) = (0.01, 0.02, 0.12)

    private static let minimumVisibleValue: Float = 0.035

    /// Largest column gap that is bridged by interpolating between the
    /// previous and newest spectrum. Longer stalls scroll in as background,
    /// which is the truthful rendering for genuinely missing data.
    private static let maximumInterpolatedColumnGap = 6

    /// 256-entry RGB lookup table for normalized spectrum values.
    private static let palette: [(red: UInt8, green: UInt8, blue: UInt8)] = (0..<256).map { index in
        rgb(forNormalizedValue: Float(index) / 255)
    }

    private static let backgroundRGB = (
        red: UInt8((backgroundComponents.red * 255).rounded()),
        green: UInt8((backgroundComponents.green * 255).rounded()),
        blue: UInt8((backgroundComponents.blue * 255).rounded())
    )

    private let lock = NSLock()
    private var binCount: Int
    private var frameRate: Double
    private var capacity: Int
    private var context: CGContext?
    private var image: CGImage?
    private var newestColumn: CGImage?
    private var newestTimestamp: TimeInterval = 0
    private var anchorTimestamp: TimeInterval?
    private var appendedColumnCount = 0
    private var previousValues: [Float]?

    init(capacity: Int, binCount: Int, frameRate: Double) {
        self.capacity = Swift.max(1, capacity)
        self.binCount = Swift.max(1, binCount)
        self.frameRate = Swift.max(1, frameRate)
        self.context = Self.makeContext(width: self.capacity, height: self.binCount)
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }

        return Snapshot(
            image: image,
            newestColumn: newestColumn,
            newestTimestamp: newestTimestamp,
            capacity: capacity,
            frameRate: frameRate
        )
    }

    func reset(capacity: Int) {
        lock.lock()
        defer { lock.unlock() }

        resetLocked(capacity: capacity, binCount: binCount, frameRate: frameRate)
    }

    func reset(capacity: Int, binCount: Int, frameRate: Double) {
        lock.lock()
        defer { lock.unlock() }

        resetLocked(capacity: capacity, binCount: binCount, frameRate: frameRate)
    }

    private func resetLocked(capacity: Int, binCount: Int, frameRate: Double) {
        let sanitizedCapacity = Swift.max(1, capacity)
        let sanitizedBinCount = Swift.max(1, binCount)
        self.frameRate = Swift.max(1, frameRate)

        if sanitizedCapacity != self.capacity || sanitizedBinCount != self.binCount || context == nil {
            self.capacity = sanitizedCapacity
            self.binCount = sanitizedBinCount
            context = Self.makeContext(width: sanitizedCapacity, height: sanitizedBinCount)
        } else {
            fillBackground()
        }

        image = nil
        newestColumn = nil
        newestTimestamp = 0
        anchorTimestamp = nil
        appendedColumnCount = 0
        previousValues = nil
    }

    func append(values: [Float], timestamp: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }

        guard let context, !values.isEmpty else { return }

        let signpostID = OSSignpostID(log: SpectrumPerformanceInstrumentation.log)
        os_signpost(
            .begin,
            log: SpectrumPerformanceInstrumentation.log,
            name: "Spectrogram Append",
            signpostID: signpostID,
            "capacity=%{public}d bins=%{public}d",
            capacity,
            binCount
        )

        let advance = columnAdvance(for: timestamp)
        shiftColumns(by: advance)
        writeColumns(values, advance: advance)
        previousValues = values

        // Publish the timestamp snapped to the column grid rather than the
        // raw analysis timestamp. The display derives its scroll offset from
        // this value, so grid-aligned timestamps keep the scroll velocity
        // uniform instead of rubber-banding with analysis scheduling jitter.
        newestTimestamp = (anchorTimestamp ?? timestamp) + Double(appendedColumnCount) / frameRate
        image = context.makeImage()
        newestColumn = image?.cropping(
            to: CGRect(x: capacity - 1, y: 0, width: 1, height: binCount)
        )

        os_signpost(
            .end,
            log: SpectrumPerformanceInstrumentation.log,
            name: "Spectrogram Append",
            signpostID: signpostID
        )
    }

    /// Number of columns to scroll for this frame, derived from the elapsed
    /// time since the first frame so rounding never accumulates drift.
    private func columnAdvance(for timestamp: TimeInterval) -> Int {
        guard let anchorTimestamp else {
            self.anchorTimestamp = timestamp
            appendedColumnCount = 0
            return 0
        }

        let expectedColumnCount = Int(((timestamp - anchorTimestamp) * frameRate).rounded())
        let advance = expectedColumnCount - appendedColumnCount

        guard advance >= 0 else { return 0 }

        guard advance <= capacity else {
            self.anchorTimestamp = timestamp
            appendedColumnCount = 0
            return capacity
        }

        appendedColumnCount = expectedColumnCount
        return advance
    }

    private func shiftColumns(by advance: Int) {
        guard advance > 0, let context, let data = context.data else { return }

        let shift = Swift.min(advance, capacity)
        let bytesPerRow = context.bytesPerRow
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let remainingColumns = capacity - shift

        for row in 0..<binCount {
            let rowStart = bytes + row * bytesPerRow

            if remainingColumns > 0 {
                memmove(rowStart, rowStart + shift * 4, remainingColumns * 4)
            }

            for column in remainingColumns..<capacity {
                let pixel = rowStart + column * 4
                pixel[0] = Self.backgroundRGB.red
                pixel[1] = Self.backgroundRGB.green
                pixel[2] = Self.backgroundRGB.blue
                pixel[3] = 255
            }
        }
    }

    /// Writes the newest analysis frame. Frames arrive on the audio callback
    /// cadence rather than exactly on the column grid, so a shift can reveal
    /// more than one column; those are filled by interpolating between the
    /// previous and newest spectrum so no background stripes are left behind.
    private func writeColumns(_ values: [Float], advance: Int) {
        guard let context, let data = context.data else { return }

        let interpolationBase = previousValues
        let columnCount = interpolationBase != nil
            && advance > 1
            && advance <= Self.maximumInterpolatedColumnGap
            ? advance
            : 1

        let bytesPerRow = context.bytesPerRow
        let bytes = data.assumingMemoryBound(to: UInt8.self)

        for step in 0..<columnCount {
            let isNewest = step == columnCount - 1
            let fraction = Float(step + 1) / Float(columnCount)
            let columnOffset = (capacity - columnCount + step) * 4

            for bin in 0..<binCount {
                let target = bin < values.count ? values[bin] : 0
                let value: Float

                if isNewest {
                    value = target
                } else if let interpolationBase {
                    let start = bin < interpolationBase.count ? interpolationBase[bin] : 0
                    value = start + (target - start) * fraction
                } else {
                    value = target
                }

                let rgb = Self.rgb(forValue: value)

                // Bin 0 (lowest frequency) belongs at the bottom, which is
                // the last scanline of the bitmap.
                let pixel = bytes + (binCount - 1 - bin) * bytesPerRow + columnOffset
                pixel[0] = rgb.red
                pixel[1] = rgb.green
                pixel[2] = rgb.blue
                pixel[3] = 255
            }
        }
    }

    private func fillBackground() {
        guard let context, let data = context.data else { return }

        let bytesPerRow = context.bytesPerRow
        let bytes = data.assumingMemoryBound(to: UInt8.self)

        for row in 0..<binCount {
            let rowStart = bytes + row * bytesPerRow

            for column in 0..<capacity {
                let pixel = rowStart + column * 4
                pixel[0] = Self.backgroundRGB.red
                pixel[1] = Self.backgroundRGB.green
                pixel[2] = Self.backgroundRGB.blue
                pixel[3] = 255
            }
        }
    }

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        context.setFillColor(CGColor(
            srgbRed: backgroundComponents.red,
            green: backgroundComponents.green,
            blue: backgroundComponents.blue,
            alpha: 1
        ))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }

    private static func rgb(forValue value: Float) -> (red: UInt8, green: UInt8, blue: UInt8) {
        guard value > minimumVisibleValue else { return backgroundRGB }

        let clamped = Swift.min(1, Swift.max(0, value))
        return palette[Int(clamped * 255)]
    }

    /// Same color ramp the Canvas previously used for its rectangle palette.
    private static func rgb(forNormalizedValue value: Float) -> (red: UInt8, green: UInt8, blue: UInt8) {
        let clamped = Double(Swift.min(1, Swift.max(0, value)))
        let red: Double
        let green: Double
        let blue: Double

        switch clamped {
        case 0..<0.18:
            red = 0.01
            green = 0.02 + clamped * 0.22
            blue = 0.25 + clamped * 1.45
        case 0..<0.42:
            let progress = (clamped - 0.18) / 0.24
            red = 0.02
            green = 0.10 + progress * 0.70
            blue = 0.70 + progress * 0.28
        case 0..<0.66:
            let progress = (clamped - 0.42) / 0.24
            red = 0.04 + progress * 0.58
            green = 0.82 + progress * 0.15
            blue = 0.94 - progress * 0.70
        case 0..<0.86:
            let progress = (clamped - 0.66) / 0.20
            red = 0.62 + progress * 0.38
            green = 0.97 - progress * 0.10
            blue = 0.22 - progress * 0.18
        default:
            let progress = (clamped - 0.86) / 0.14
            red = 1.0
            green = 0.86 - progress * 0.78
            blue = 0.03
        }

        return (
            red: UInt8((Swift.min(1, Swift.max(0, red)) * 255).rounded()),
            green: UInt8((Swift.min(1, Swift.max(0, green)) * 255).rounded()),
            blue: UInt8((Swift.min(1, Swift.max(0, blue)) * 255).rounded())
        )
    }
}
