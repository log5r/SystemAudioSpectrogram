//
//  ObjectiveCSpectrumAnalyzer.mm
//  SystemAudioSpectrogram
//
//  Created by Codex on 2026/06/21.
//

#import "ObjectiveCSpectrumAnalyzer.h"

#import <Accelerate/Accelerate.h>
#import <dispatch/dispatch.h>
#import <os/log.h>
#import <os/signpost.h>
#import <algorithm>
#import <cmath>
#import <vector>

namespace {

struct AnalyzerConfiguration {
    double sampleRate = 0;
    double maximumFrequency = 0;
    bool usesLogarithmicFrequencyScale = false;
};

struct BinIndexRange {
    int lower = 1;
    int upper = 1;
};

static int LargestPowerOfTwoAtMost(NSInteger value) {
    if (value <= 0) {
        return 0;
    }

    int power = 1;
    while (power * 2 <= value) {
        power *= 2;
    }

    return power;
}

static std::vector<float> MakeHannWindow(int size) {
    std::vector<float> window(size, 0);
    const float denominator = static_cast<float>(std::max(1, size - 1));

    for (int index = 0; index < size; ++index) {
        const float phase = 2.0f * static_cast<float>(M_PI) * static_cast<float>(index) / denominator;
        window[index] = 0.5f - 0.5f * std::cos(phase);
    }

    return window;
}

static std::pair<double, double> FrequencyRange(
    int displayBin,
    int binCount,
    double maximumFrequency,
    bool usesLogarithmicFrequencyScale
) {
    if (!usesLogarithmicFrequencyScale) {
        const double low = maximumFrequency * static_cast<double>(displayBin) / static_cast<double>(binCount);
        const double high = maximumFrequency * static_cast<double>(displayBin + 1) / static_cast<double>(binCount);
        return {low, high};
    }

    const double minimumFrequency = std::min(40.0, maximumFrequency * 0.5);
    if (maximumFrequency <= minimumFrequency) {
        const double low = maximumFrequency * static_cast<double>(displayBin) / static_cast<double>(binCount);
        const double high = maximumFrequency * static_cast<double>(displayBin + 1) / static_cast<double>(binCount);
        return {low, high};
    }

    const double lowProgress = static_cast<double>(displayBin) / static_cast<double>(binCount);
    const double highProgress = static_cast<double>(displayBin + 1) / static_cast<double>(binCount);
    const double ratio = maximumFrequency / minimumFrequency;
    const double low = displayBin == 0 ? 0 : minimumFrequency * std::pow(ratio, lowProgress);
    const double high = minimumFrequency * std::pow(ratio, highProgress);

    return {low, high};
}

static bool SameConfiguration(
    const AnalyzerConfiguration &lhs,
    const AnalyzerConfiguration &rhs
) {
    return lhs.sampleRate == rhs.sampleRate
        && lhs.maximumFrequency == rhs.maximumFrequency
        && lhs.usesLogarithmicFrequencyScale == rhs.usesLogarithmicFrequencyScale;
}

static float ClampedSpectrumValue(float power, int fftSize) {
    const float amplitude = std::sqrt(power) * 2.0f / static_cast<float>(fftSize);
    const float decibels = 20.0f * std::log10(std::max(amplitude, 0.00000001f));
    return std::min(1.0f, std::max(0.0f, (decibels + 92.0f) / 74.0f));
}

static os_log_t SpectrumPerformanceLog() {
    static os_log_t log;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        log = os_log_create("SystemAudioSpectrogram", "SpectrumPerformance");
    });

    return log;
}

} // namespace

@implementation ObjectiveCSpectrumAnalyzer {
    NSInteger _fftSize;
    NSInteger _halfSize;
    NSInteger _binCount;
    vDSP_Length _log2Size;
    FFTSetup _fftSetup;
    std::vector<float> _hannWindow;
    std::vector<float> _windowedSamples;
    std::vector<float> _real;
    std::vector<float> _imaginary;
    std::vector<float> _power;
    std::vector<BinIndexRange> _binIndexRanges;
    AnalyzerConfiguration _configuration;
    bool _hasConfiguration;
}

- (nullable instancetype)initWithWindowSize:(NSInteger)windowSize
                                   binCount:(NSInteger)binCount {
    const int fftSize = LargestPowerOfTwoAtMost(windowSize);
    if (fftSize < 64 || binCount <= 0) {
        return nil;
    }

    const vDSP_Length log2Size = static_cast<vDSP_Length>(std::log2(static_cast<double>(fftSize)));
    FFTSetup fftSetup = vDSP_create_fftsetup(log2Size, kFFTRadix2);
    if (fftSetup == nullptr) {
        return nil;
    }

    self = [super init];
    if (self == nil) {
        vDSP_destroy_fftsetup(fftSetup);
        return nil;
    }

    _fftSize = fftSize;
    _halfSize = fftSize / 2;
    _binCount = binCount;
    _log2Size = log2Size;
    _fftSetup = fftSetup;
    _hannWindow = MakeHannWindow(fftSize);
    _windowedSamples.assign(fftSize, 0);
    _real.assign(fftSize / 2, 0);
    _imaginary.assign(fftSize / 2, 0);
    _power.assign(fftSize / 2, 0);
    _binIndexRanges.assign(binCount, BinIndexRange());
    _hasConfiguration = false;

    return self;
}

- (void)dealloc {
    if (_fftSetup != nullptr) {
        vDSP_destroy_fftsetup(_fftSetup);
    }
}

- (NSInteger)fftSize {
    return _fftSize;
}

- (NSInteger)binCount {
    return _binCount;
}

- (BOOL)analyzeSamples:(const float *)samples
                 count:(NSInteger)sampleCount
            sampleRate:(double)sampleRate
      maximumFrequency:(double)maximumFrequency
usesLogarithmicFrequencyScale:(BOOL)usesLogarithmicFrequencyScale
                output:(float *)output
           outputCount:(NSInteger)outputCount {
    if (output == nullptr || outputCount <= 0) {
        return NO;
    }

    if (outputCount < _binCount || samples == nullptr || sampleCount < _fftSize || sampleRate <= 0) {
        vDSP_vclr(output, 1, static_cast<vDSP_Length>(outputCount));
        return NO;
    }

    [self configureIfNeededWithSampleRate:sampleRate
                         maximumFrequency:maximumFrequency
             usesLogarithmicFrequencyScale:usesLogarithmicFrequencyScale];
    [self applyWindowToSamples:samples count:sampleCount];
    [self runFFT];
    [self fillSpectrumOutput:output];

    return YES;
}

- (void)configureIfNeededWithSampleRate:(double)sampleRate
                       maximumFrequency:(double)maximumFrequency
           usesLogarithmicFrequencyScale:(BOOL)usesLogarithmicFrequencyScale {
    const double maxFrequency = std::min(maximumFrequency, sampleRate / 2.0);
    AnalyzerConfiguration nextConfiguration = {
        sampleRate,
        maxFrequency,
        usesLogarithmicFrequencyScale
    };

    if (_hasConfiguration && SameConfiguration(_configuration, nextConfiguration)) {
        return;
    }

    _configuration = nextConfiguration;
    _hasConfiguration = true;
    [self precomputeBinIndexRangesWithSampleRate:sampleRate
                                maximumFrequency:maxFrequency
                    usesLogarithmicFrequencyScale:usesLogarithmicFrequencyScale];
}

- (void)precomputeBinIndexRangesWithSampleRate:(double)sampleRate
                              maximumFrequency:(double)maximumFrequency
                  usesLogarithmicFrequencyScale:(BOOL)usesLogarithmicFrequencyScale {
    const double frequencyPerBin = sampleRate / static_cast<double>(_fftSize);

    for (int displayBin = 0; displayBin < _binCount; ++displayBin) {
        const auto frequencyRange = FrequencyRange(
            displayBin,
            static_cast<int>(_binCount),
            maximumFrequency,
            usesLogarithmicFrequencyScale
        );
        const int lowIndex = std::max(1, std::min(static_cast<int>(_halfSize - 1), static_cast<int>(frequencyRange.first / frequencyPerBin)));
        const int highIndex = std::max(lowIndex, std::min(static_cast<int>(_halfSize - 1), static_cast<int>(std::ceil(frequencyRange.second / frequencyPerBin))));
        _binIndexRanges[displayBin] = {lowIndex, highIndex};
    }
}

- (void)applyWindowToSamples:(const float *)samples count:(NSInteger)sampleCount {
    const float *start = samples + sampleCount - _fftSize;
    vDSP_vmul(
        start,
        1,
        _hannWindow.data(),
        1,
        _windowedSamples.data(),
        1,
        static_cast<vDSP_Length>(_fftSize)
    );
}

- (void)runFFT {
    os_log_t log = SpectrumPerformanceLog();
    os_signpost_id_t signpostID = os_signpost_id_generate(log);

    os_signpost_interval_begin(
        log,
        signpostID,
        "FFT",
        "backend=%{public}s fftSize=%{public}ld",
        "objective-c++",
        static_cast<long>(_fftSize)
    );

    DSPSplitComplex splitComplex = {
        _real.data(),
        _imaginary.data()
    };

    const DSPComplex *complexSamples = reinterpret_cast<const DSPComplex *>(_windowedSamples.data());
    vDSP_ctoz(
        complexSamples,
        2,
        &splitComplex,
        1,
        static_cast<vDSP_Length>(_halfSize)
    );

    vDSP_fft_zrip(_fftSetup, &splitComplex, 1, _log2Size, FFT_FORWARD);
    vDSP_zvmags(&splitComplex, 1, _power.data(), 1, static_cast<vDSP_Length>(_halfSize));

    os_signpost_interval_end(
        log,
        signpostID,
        "FFT",
        "backend=%{public}s reusedSetup=%{public}d",
        "objective-c++",
        1
    );
}

- (void)fillSpectrumOutput:(float *)output {
    for (int displayBin = 0; displayBin < _binCount; ++displayBin) {
        const BinIndexRange indexRange = _binIndexRanges[displayBin];
        float strongestPower = 0;

        for (int spectrumIndex = indexRange.lower; spectrumIndex <= indexRange.upper; ++spectrumIndex) {
            strongestPower = std::max(strongestPower, _power[spectrumIndex]);
        }

        output[displayBin] = ClampedSpectrumValue(strongestPower, static_cast<int>(_fftSize));
    }
}

@end
