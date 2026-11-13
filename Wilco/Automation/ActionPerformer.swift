import Foundation
import UserNotifications
import WilcoControl
import WilcoCore

/// A labelled marker dropped into the transcript by a rule.
struct CueMarker: Identifiable, Equatable {
    var id = UUID()
    var label: String
    var date: Date
    var sessionOffset: Double
    var channelID: ChannelConfig.ID?
    var ruleName: String
}

/// Carries out a fired rule's actions and reports each outcome.
@MainActor
final class ActionPerformer {
    private let osc = OSCSender()
    private let midi = MIDIOutput()
    private var askedForNotifications = false

    /// Called for every action with what happened.
    var log: (ActivityEntry) -> Void = { _ in }
    /// Called for "Mark Cue Point" actions.
    var mark: (CueMarker) -> Void = { _ in }

    func perform(_ rule: AutomationRule, context: TemplateContext, show: ShowDocument, channelID: ChannelConfig.ID?) {
        for action in rule.actions {
            switch action {
            case .osc(let destinationID, let address, let arguments):
                guard let destination = show.destinations.first(where: { $0.id == destinationID }) else {
                    log(.init(kind: .error, ruleName: rule.name, detail: "OSC destination no longer exists"))
                    continue
                }
                guard destination.isEnabled else {
                    log(.init(kind: .info, ruleName: rule.name, detail: "Skipped: \(destination.name) is turned off"))
                    continue
                }
                let message = OSCMessage(address: address, arguments: arguments).expanded(with: context)
                let osc = osc
                Task {
                    do {
                        try await osc.send(message, to: destination)
                        log(.init(kind: .fired, ruleName: rule.name, detail: "OSC \(message.address) → \(destination.name)"))
                    } catch {
                        log(.init(kind: .error, ruleName: rule.name, detail: "OSC to \(destination.name): \(error.localizedDescription)"))
                    }
                }

            case .midi(let endpointID, let message):
                do {
                    try midi.send(message, to: endpointID)
                    log(.init(kind: .fired, ruleName: rule.name, detail: message.summary))
                } catch {
                    log(.init(kind: .error, ruleName: rule.name, detail: "MIDI: \(error.localizedDescription)"))
                }

            case .webhook(let urlTemplate, let method, let bodyTemplate):
                guard let request = WebhookRequest.make(urlTemplate: urlTemplate, method: method, bodyTemplate: bodyTemplate, context: context) else {
                    log(.init(kind: .error, ruleName: rule.name, detail: "Webhook URL is not a valid http(s) address"))
                    continue
                }
                Task {
                    do {
                        let (_, response) = try await URLSession.shared.data(for: request)
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        let host = request.url?.host() ?? ""
                        if (200..<300).contains(status) {
                            log(.init(kind: .fired, ruleName: rule.name, detail: "Webhook \(request.httpMethod ?? "") \(host) → \(status)"))
                        } else {
                            log(.init(kind: .error, ruleName: rule.name, detail: "Webhook \(host) answered \(status)"))
                        }
                    } catch {
                        log(.init(kind: .error, ruleName: rule.name, detail: "Webhook: \(error.localizedDescription)"))
                    }
                }

            case .notify(let title, let bodyTemplate):
                notify(title: context.expand(title), body: context.expand(bodyTemplate), ruleName: rule.name)

            case .markCuePoint(let label):
                let text = context.expand(label)
                mark(CueMarker(label: text, date: context.date, sessionOffset: context.offset, channelID: channelID, ruleName: rule.name))
                log(.init(kind: .fired, ruleName: rule.name, detail: "Marked “\(text)”"))
            }
        }
    }

    func forgetDestinations(except destinations: [OSCDestination]) {
        let osc = osc
        Task { await osc.keepOnly(destinations) }
    }

    private func notify(title: String, body: String, ruleName: String) {
        let center = UNUserNotificationCenter.current()
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: {
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                return content
            }(),
            trigger: nil
        )
        let firstTime = !askedForNotifications
        askedForNotifications = true
        Task {
            if firstTime {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
            do {
                try await center.add(request)
                log(.init(kind: .fired, ruleName: ruleName, detail: "Notification “\(title)”"))
            } catch {
                log(.init(kind: .error, ruleName: ruleName, detail: "Notification: \(error.localizedDescription)"))
            }
        }
    }
}
