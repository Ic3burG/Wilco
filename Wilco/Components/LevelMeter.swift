import SwiftUI

/// A horizontal meter. `level` is 0...1, linear in decibels from -60 dBFS.
struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(color)
                    .frame(width: geometry.size.width * CGFloat(level))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }

    /// Green to -12 dBFS, yellow to -3 dBFS, then red.
    private var color: Color {
        switch level {
        case ..<0.8: .green
        case ..<0.95: .yellow
        default: .red
        }
    }
}
