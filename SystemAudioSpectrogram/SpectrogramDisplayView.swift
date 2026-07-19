//
//  SpectrogramDisplayView.swift
//  SystemAudioSpectrogram
//
//  Created by Claude on 2026/07/02.
//

import AppKit
import SwiftUI
import os

/// AppKit-backed spectrogram display.
///
/// The 60 fps scroll runs on a `CADisplayLink` and mutates plain `CALayer`s
/// directly, so no SwiftUI view updates, Canvas re-renders, or per-frame
/// image resolution happen on the hot path. The previous
/// `TimelineView(.animation)` + `Canvas` pipeline degraded from 60 fps to
/// roughly 25 fps after a few minutes of sustained redraws; per-frame work
/// here is constant: one renderer snapshot and two layer frame assignments.
struct SpectrumDisplay: NSViewRepresentable {
    let renderer: SpectrogramRenderer
    let visibleDuration: TimeInterval
    let isPaused: Bool

    func makeNSView(context: Context) -> SpectrogramLayerView {
        let view = SpectrogramLayerView()
        view.renderer = renderer
        view.visibleDuration = visibleDuration
        view.isPaused = isPaused
        return view
    }

    func updateNSView(_ view: SpectrogramLayerView, context: Context) {
        view.renderer = renderer
        view.visibleDuration = visibleDuration
        view.isPaused = isPaused
    }
}

final class SpectrogramLayerView: NSView {
    var renderer: SpectrogramRenderer?
    var visibleDuration: TimeInterval = 6

    var isPaused = false {
        didSet { displayLink?.isPaused = isPaused }
    }

    private let imageLayer = CALayer()
    private let gapLayer = CALayer()
    private let fpsLayer = CATextLayer()
    private let fpsCounter = FPSCounter()
    private var displayLink: CADisplayLink?
    private var lastImage: CGImage?
    private var lastFPSText = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layerContentsRedrawPolicy = .never

        guard let layer else { return }

        layer.backgroundColor = CGColor(
            srgbRed: SpectrogramRenderer.backgroundComponents.red,
            green: SpectrogramRenderer.backgroundComponents.green,
            blue: SpectrogramRenderer.backgroundComponents.blue,
            alpha: 1
        )
        layer.masksToBounds = true

        let disabledActions: [String: CAAction] = [
            "contents": NSNull(),
            "bounds": NSNull(),
            "position": NSNull(),
            "hidden": NSNull()
        ]

        for contentLayer in [imageLayer, gapLayer] {
            contentLayer.contentsGravity = .resize
            contentLayer.magnificationFilter = .linear
            contentLayer.minificationFilter = .linear
            contentLayer.isHidden = true
            contentLayer.actions = disabledActions
            layer.addSublayer(contentLayer)
        }

        fpsLayer.font = CTFontCreateWithName("Menlo" as CFString, 10, nil)
        fpsLayer.fontSize = 10
        fpsLayer.foregroundColor = CGColor(gray: 1, alpha: 0.9)
        fpsLayer.backgroundColor = CGColor(gray: 0, alpha: 0.55)
        fpsLayer.cornerRadius = 4
        fpsLayer.alignmentMode = .center
        fpsLayer.isHidden = true
        fpsLayer.actions = disabledActions
        layer.addSublayer(fpsLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        displayLink?.invalidate()
        displayLink = nil

        guard window != nil else { return }

        updateLayerContentsScale()

        let link = displayLink(target: self, selector: #selector(step))
        link.isPaused = isPaused
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateLayerContentsScale()
    }

    private func updateLayerContentsScale() {
        fpsLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    @objc private func step(_ link: CADisplayLink) {
        updateSpectrogramLayers(at: Date().timeIntervalSinceReferenceDate)
    }

    private func updateSpectrogramLayers(at now: TimeInterval) {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        updateFPSLayer(at: now, size: size)

        guard let renderer else {
            imageLayer.isHidden = true
            gapLayer.isHidden = true
            return
        }

        let snapshot = renderer.snapshot()

        guard let image = snapshot.image, snapshot.capacity > 0 else {
            imageLayer.isHidden = true
            gapLayer.isHidden = true
            return
        }

        let age = max(0, now - snapshot.newestTimestamp)
        let pointsPerSecond = size.width / CGFloat(max(0.001, visibleDuration))
        let columnWidth = pointsPerSecond / CGFloat(max(1, snapshot.frameRate))
        let newestRightEdge = size.width - CGFloat(age) * pointsPerSecond
        let imageWidth = CGFloat(snapshot.capacity) * columnWidth

        guard newestRightEdge > 0 else {
            imageLayer.isHidden = true
            gapLayer.isHidden = true
            return
        }

        if image !== lastImage {
            lastImage = image
            imageLayer.contents = image
            gapLayer.contents = snapshot.newestColumn
        }

        imageLayer.isHidden = false
        imageLayer.frame = CGRect(
            x: newestRightEdge - imageWidth,
            y: 0,
            width: imageWidth,
            height: size.height
        )

        // The newest column keeps sliding left until the next analysis frame
        // lands, so stretch it into the gap at the right edge. Skip this when
        // frames stop arriving entirely so stale data scrolls away instead.
        let gapWidth = size.width - newestRightEdge
        if gapWidth > 0,
           age <= 2.0 / max(1, snapshot.frameRate),
           snapshot.newestColumn != nil {
            gapLayer.isHidden = false
            gapLayer.frame = CGRect(
                x: newestRightEdge - 0.5,
                y: 0,
                width: gapWidth + 0.5,
                height: size.height
            )
        } else {
            gapLayer.isHidden = true
        }
    }

    private func updateFPSLayer(at now: TimeInterval, size: CGSize) {
        let fps = fpsCounter.tick(at: now)

        guard fps > 0 else {
            fpsLayer.isHidden = true
            return
        }

        let text = "\(Int(fps.rounded())) fps"
        if text != lastFPSText {
            lastFPSText = text
            fpsLayer.string = text
        }

        let width = CGFloat(text.count) * 6.5 + 10
        let height: CGFloat = 15
        fpsLayer.isHidden = false
        fpsLayer.frame = CGRect(
            x: size.width - width - 5,
            y: size.height - height - 5,
            width: width,
            height: height
        )
    }
}

/// Measures the display-link cadence so the observed frame rate can be shown
/// in the spectrum and logged. Only touched from the display-link callback,
/// so no synchronization is needed.
private final class FPSCounter {
    private static let logger = Logger(subsystem: "SystemAudioSpectrogram", category: "FPS")

    private var lastTick: TimeInterval = 0
    private var windowStart: TimeInterval = 0
    private var frameCount = 0
    private var displayedFPS = 0.0
    private var lastLog: TimeInterval = 0

    func tick(at now: TimeInterval) -> Double {
        if lastTick == 0 || now - lastTick > 1.0 {
            windowStart = now
            frameCount = 0
        }

        lastTick = now
        frameCount += 1

        let elapsed = now - windowStart
        if elapsed >= 0.5, frameCount > 1 {
            displayedFPS = Double(frameCount - 1) / elapsed
            windowStart = now
            frameCount = 1

            if now - lastLog >= 5 {
                lastLog = now
                Self.logger.debug("fps=\(self.displayedFPS, format: .fixed(precision: 1))")
            }
        }

        return displayedFPS
    }
}
