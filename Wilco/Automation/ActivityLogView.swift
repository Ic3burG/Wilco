import SwiftUI
import WilcoCore

/// Everything automation did, newest first.
struct ActivityLogView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.activity.isEmpty {
                ContentUnavailableView("No Activity", systemImage: "list.bullet.rectangle",
                                       description: Text("Rules fire actions when a phrase is heard. What they do is logged here."))
            } else {
                Table(model.activity.reversed()) {
                    TableColumn("Time") { entry in
                        Text(entry.date, format: .dateTime.hour().minute().second())
                            .monospacedDigit()
                    }
                    .width(80)
                    TableColumn("") { entry in
                        Image(systemName: entry.kind.symbol).foregroundStyle(entry.kind.color)
                    }
                    .width(20)
                    TableColumn("Rule", value: \.ruleName)
                        .width(min: 100, ideal: 160)
                    TableColumn("Detail", value: \.detail)
                }
            }
        }
        .toolbar {
            Button("Clear Activity", systemImage: "trash", action: model.clearActivity)
                .disabled(model.activity.isEmpty)
        }
    }
}

extension ActivityEntry.Kind {
    var symbol: String {
        switch self {
        case .fired: "bolt.fill"
        case .error: "exclamationmark.triangle.fill"
        case .info: "info.circle"
        }
    }

    var color: Color {
        switch self {
        case .fired: .green
        case .error: .orange
        case .info: .secondary
        }
    }
}
