import SwiftUI

/// A visible ⓘ button that shows a longer explanation in a popover, so a
/// settings section can keep its caption to one line.
struct InfoButton: View {
    let text: String
    @State private var isShowing = false

    var body: some View {
        Button {
            isShowing.toggle()
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .help("More about this")
        .accessibilityLabel("More information")
        .popover(isPresented: $isShowing, arrowEdge: .bottom) {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 320, alignment: .leading)
                .padding()
        }
    }
}

/// A one-line section footer, with the rest of the explanation behind ⓘ.
struct SettingsFooter: View {
    let caption: String
    let more: String?

    init(_ caption: String, more: String? = nil) {
        self.caption = caption
        self.more = more
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(caption)
            if let more { InfoButton(text: more) }
        }
    }
}
