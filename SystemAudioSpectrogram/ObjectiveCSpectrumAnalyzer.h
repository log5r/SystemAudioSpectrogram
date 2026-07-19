//
//  ObjectiveCSpectrumAnalyzer.h
//  SystemAudioSpectrogram
//
//  Created by Codex on 2026/06/21.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ObjectiveCSpectrumAnalyzer : NSObject

- (nullable instancetype)initWithWindowSize:(NSInteger)windowSize
                                   binCount:(NSInteger)binCount NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) NSInteger fftSize;
@property (nonatomic, readonly) NSInteger binCount;

- (BOOL)analyzeSamples:(const float *)samples
                 count:(NSInteger)sampleCount
            sampleRate:(double)sampleRate
      maximumFrequency:(double)maximumFrequency
usesLogarithmicFrequencyScale:(BOOL)usesLogarithmicFrequencyScale
                output:(float *)output
           outputCount:(NSInteger)outputCount;

@end

NS_ASSUME_NONNULL_END
