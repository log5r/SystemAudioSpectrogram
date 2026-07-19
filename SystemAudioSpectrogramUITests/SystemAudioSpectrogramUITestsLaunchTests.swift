//
//  SystemAudioSpectrogramUITestsLaunchTests.swift
//  SystemAudioSpectrogramUITests
//
//  Created by Judau on 2026/06/19.
//

import XCTest

final class SystemAudioSpectrogramUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launchEnvironment["SYSTEM_AUDIO_SPECTROGRAM_PREVIEW"] = "1"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "System Audio Spectrogram"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
