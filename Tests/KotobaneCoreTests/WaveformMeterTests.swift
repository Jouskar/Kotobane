import Testing
@testable import KotobaneCore

@Test func waveformBarsAreStableAndBounded() {
    let bars = WaveformMeter.bars(rmsLevel: 0.6, count: 16, phase: 0.25)

    #expect(bars == WaveformMeter.bars(rmsLevel: 0.6, count: 16, phase: 0.25))
    #expect(bars.count == 16)
    #expect(bars.allSatisfy { (0.08...1.0).contains($0) })
}

@Test func silentInputUsesMinimumBars() {
    #expect(WaveformMeter.bars(rmsLevel: 0, count: 4, phase: 0) == [0.08, 0.08, 0.08, 0.08])
}

@Test func normalSpeechLevelProducesVisibleBarVariation() {
    let bars = WaveformMeter.bars(rmsLevel: 0.01, count: 16, phase: 0)

    #expect((bars.max() ?? 0) - (bars.min() ?? 0) >= 0.1)
}
