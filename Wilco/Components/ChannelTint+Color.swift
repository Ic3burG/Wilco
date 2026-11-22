import SwiftUI
import WilcoCore

extension ChannelTint {
    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .teal: .teal
        case .cyan: .cyan
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .gray: .gray
        }
    }
}

extension ChannelTint {
    /// A filled dot in this tint for picker rows. Menu-style pickers become an
    /// `NSMenu`, which draws symbol images as templates and ignores
    /// `foregroundStyle`, so the dot is a non-template image instead.
    var swatch: Image {
        let nsColor = NSColor(color)
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            nsColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return Image(nsImage: image)
    }

    /// Picker row: the tint's name with its coloured dot.
    var pickerLabel: some View {
        Label { Text(rawValue.capitalized) } icon: { swatch }
    }
}
