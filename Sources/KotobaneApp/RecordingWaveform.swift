import SwiftUI
import KotobaneCore

struct RecordingWaveform: View {
    let rmsLevel: Float

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1.0 / 20)) { context in
            let phase = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate * 5
            let bars = WaveformMeter.bars(rmsLevel: rmsLevel, count: 16, phase: phase)

            HStack(alignment: .center, spacing: 3) {
                ForEach(Array(bars.enumerated()), id: \.offset) { _, height in
                    Capsule()
                        .fill(.red.gradient)
                        .frame(width: 4, height: 8 + height * 32)
                }
            }
            .frame(height: 42)
            .accessibilityLabel("Microphone level")
            .accessibilityValue("\(Int(rmsLevel * 100)) percent")
        }
    }
}
