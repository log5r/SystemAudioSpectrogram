# Architecture

The app keeps capture, analysis, and display work separated by queue and responsibility:

1. `ProcessTapAudioCapture` creates the Core Audio process tap, private aggregate device, and I/O callback.
2. `AudioStreamOutput` copies the current stereo window into rolling sample buffers and schedules spectrum analysis off the main actor.
3. `SpectrumAnalyzer` delegates FFT work to the Objective-C++ Accelerate implementation.
4. `SpectrogramRenderer` appends each analyzed frame into a lock-protected bitmap.
5. `SpectrumDisplay` scrolls the latest bitmap with AppKit and Core Animation without invalidating the full SwiftUI hierarchy every frame.
6. `SystemAudioSpectrumMonitor` publishes only control/status state and coalesced level readouts to SwiftUI.

Captured audio remains in memory only long enough to calculate level values and FFT bins. Stopping capture destroys the I/O callback, aggregate device, and process tap.
