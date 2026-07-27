import Foundation

public enum WaveformMeter {
    public static func bars(
        rmsLevel: Float,
        count: Int,
        phase: Double
    ) -> [Double] {
        guard count > 0 else { return [] }

        let level = min(1, max(0, Double(rmsLevel)))
        guard level > 0 else {
            return Array(repeating: 0.08, count: count)
        }

        return (0..<count).map { index in
            let position = Double(index) / Double(count)
            let wave = (sin(position * .pi * 4 + phase) + 1) / 2
            return min(1, max(0.08, level * (0.45 + wave * 0.55)))
        }
    }
}
