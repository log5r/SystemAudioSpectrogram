//
//  SpectrogramImageExport.swift
//  SystemAudioSpectrogram
//

import AppKit
import Combine
import SwiftUI

/// Keeps a weak reference to the on-screen spectrogram region and captures it
/// synchronously. Capturing through AppKit includes the live Core Animation
/// layer contents as well as the SwiftUI labels, scales, and grid overlays.
@MainActor
final class SpectrogramViewSnapshotter: ObservableObject {
    weak var regionView: NSView?

    func capturePNG() throws -> Data {
        guard let regionView,
              let contentView = regionView.window?.contentView else {
            throw SpectrogramImageExportError.viewUnavailable
        }

        let captureRect = regionView
            .convert(regionView.bounds, to: contentView)
            .intersection(contentView.bounds)
            .integral

        guard captureRect.width > 0,
              captureRect.height > 0,
              let bitmap = contentView.bitmapImageRepForCachingDisplay(in: captureRect) else {
            throw SpectrogramImageExportError.viewUnavailable
        }

        contentView.cacheDisplay(in: captureRect, to: bitmap)

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw SpectrogramImageExportError.pngEncodingFailed
        }

        return data
    }
}

/// A transparent background view that defines the exact rectangle exported by
/// `SpectrogramViewSnapshotter`.
struct SpectrogramSnapshotRegion: NSViewRepresentable {
    let snapshotter: SpectrogramViewSnapshotter

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        snapshotter.regionView = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        snapshotter.regionView = view
    }
}

@MainActor
enum SpectrogramOutputDirectoryStore {
    private static let bookmarkKey = "spectrogramOutputDirectoryBookmark"

    static func save(_ directory: URL) throws {
        let bookmark = try directory.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: [.isDirectoryKey],
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
    }

    static func restore() -> URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else {
            return nil
        }

        do {
            var isStale = false
            let directory = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                try save(directory)
            }

            return directory
        } catch {
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            return nil
        }
    }
}

enum SpectrogramImageWriter {
    nonisolated static func writePNG(
        _ data: Data,
        to directory: URL,
        date: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> URL {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            throw SpectrogramImageExportError.outputDirectoryUnavailable
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"

        let baseName = "spectrogram-\(formatter.string(from: date))"
        var destination = directory.appendingPathComponent("\(baseName).png")
        var suffix = 2

        while fileManager.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(baseName)-\(suffix).png")
            suffix += 1
        }

        try data.write(to: destination, options: .atomic)
        return destination
    }
}

enum SpectrogramImageExportError: LocalizedError {
    case viewUnavailable
    case pngEncodingFailed
    case outputDirectoryUnavailable

    var errorDescription: String? {
        switch self {
        case .viewUnavailable:
            return "The spectrogram is not ready to capture."
        case .pngEncodingFailed:
            return "The spectrogram could not be encoded as a PNG image."
        case .outputDirectoryUnavailable:
            return "The selected output directory is no longer available."
        }
    }
}
