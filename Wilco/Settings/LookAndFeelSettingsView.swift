import SwiftUI
import WilcoCore

struct LookAndFeelSettingsView: View {
    @Environment(LookAndFeel.self) private var look

    var body: some View {
        @Bindable var look = look
        Form {
            Section {
                Picker("Appearance", selection: $look.theme) {
                    ForEach(AppTheme.allCases, id: \.self) { theme in
                        Label(theme.title, systemImage: theme.symbol).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                SettingsFooter("Choose Dark for a dark booth even when the rest of this Mac is in Light mode.", more: "Also in the View menu.")
            }

            Section {
                LabeledContent("Text Size") {
                    HStack {
                        Slider(value: $look.appearance.fontSize, in: TranscriptAppearance.fontSizeRange, step: 1) {
                            Text("Text Size")
                        } minimumValueLabel: {
                            Image(systemName: "textformat.size.smaller")
                        } maximumValueLabel: {
                            Image(systemName: "textformat.size.larger")
                        }
                        .labelsHidden()
                        Text("\(Int(look.appearance.fontSize)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Toggle("Show timecode", isOn: $look.appearance.showTimecode)
                Toggle("Auto-scroll to newest", isOn: $look.appearance.followLive)
                Toggle("Newest line first", isOn: $look.appearance.newestFirst)
                Preview(appearance: look.appearance)
            } header: {
                Text("Transcript")
            } footer: {
                SettingsFooter("With newest first, the most recent line sits at the top of the window and the log reads downward into the past.", more: "Auto-scroll applies everywhere, the matrix columns included.")
            }
        }
        .formStyle(.grouped)
    }
}

/// A few sample comms lines drawn with the current settings.
private struct Preview: View {
    let appearance: TranscriptAppearance

    private static let stageManager = ChannelConfig(name: "Stage Manager", tint: .blue)
    private static let lighting = ChannelConfig(name: "Lighting", tint: .orange)
    /// 7:30 PM today, so the sample clock times look like a show.
    private static let showStart = Calendar.current.date(bySettingHour: 19, minute: 30, second: 0, of: .now) ?? .now

    var body: some View {
        let lines: [(ChannelConfig, Double, String)] = [
            (Self.stageManager, 3_725, "Standby lighting cue 5"),
            (Self.lighting, 3_727, "Standing by"),
            (Self.stageManager, 3_731, "Lighting go"),
        ]
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(appearance.ordered(lines).enumerated()), id: \.offset) { index, line in
                if index > 0 { Divider() }
                TranscriptRow(
                    channel: line.0, date: Self.showStart.addingTimeInterval(line.1), offset: line.1, text: line.2,
                    highlights: line.2.hasPrefix("Standby") ? [SegmentHighlight(phrase: "Standby", tint: .yellow)] : [],
                    confidence: nil, showsChannel: true, showsTimecode: appearance.showTimecode,
                    isVolatile: false, fontSize: appearance.fontSize, compact: true
                )
            }
        }
        .padding(.vertical, 4)
        .background(.background, in: .rect(cornerRadius: 6))
        .accessibilityLabel("Preview of transcript lines")
    }
}
