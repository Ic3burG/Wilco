import Foundation

/// Fills `{text}`, `{channel}`, `{keyword}`, `{time}` and `{offset}` in
/// action templates with what was heard.
public struct TemplateContext: Sendable {
    public enum Escaping: Sendable {
        case none
        /// For values inside a JSON string literal.
        case json
        /// For values inside a URL: everything but unreserved characters is percent-encoded.
        case url
        /// For values inside an OSC address. OSC reads `* ? [ ] { } ,` as
        /// wildcards and `/` as a separator, so anything spoken that reaches
        /// an address could otherwise address many console commands at once.
        /// Those, `#`, whitespace and control characters become `_`.
        case oscAddress
    }

    public var text: String
    public var channel: String
    /// The first phrase that matched.
    public var keyword: String
    public var date: Date
    /// Seconds since the capture session started.
    public var offset: Double

    public init(text: String, channel: String, keyword: String, date: Date, offset: Double) {
        self.text = text
        self.channel = channel
        self.keyword = keyword
        self.date = date
        self.offset = offset
    }

    public func expand(_ template: String, escaping: Escaping = .none, timeZone: TimeZone = .current) -> String {
        let values: [(String, String)] = [
            ("{text}", text),
            ("{channel}", channel),
            ("{keyword}", keyword),
            ("{time}", time(in: timeZone)),
            ("{offset}", Self.offsetText(offset)),
        ]
        return values.reduce(template) { result, pair in
            result.replacingOccurrences(of: pair.0, with: Self.escape(pair.1, escaping))
        }
    }

    /// Local wall-clock time, `HH:mm:ss`.
    private func time(in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    /// Session time, `H:MM:SS`.
    static func offsetText(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    private static func escape(_ value: String, _ escaping: Escaping) -> String {
        switch escaping {
        case .none:
            return value
        case .url:
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        case .oscAddress:
            let reserved = Set("/*?[]{},#".unicodeScalars)
            return String(String.UnicodeScalarView(value.unicodeScalars.map { scalar in
                reserved.contains(scalar) || CharacterSet.whitespacesAndNewlines.contains(scalar)
                    || CharacterSet.controlCharacters.contains(scalar) ? "_" : scalar
            }))
        case .json:
            var escaped = ""
            for scalar in value.unicodeScalars {
                switch scalar {
                case "\"": escaped += "\\\""
                case "\\": escaped += "\\\\"
                case "\n": escaped += "\\n"
                case "\r": escaped += "\\r"
                case "\t": escaped += "\\t"
                case _ where scalar.value < 0x20: escaped += String(format: "\\u%04x", scalar.value)
                default: escaped.unicodeScalars.append(scalar)
                }
            }
            return escaped
        }
    }
}

/// Builds the HTTP request for a webhook action.
public enum WebhookRequest {
    /// `nil` when the expanded URL is not a valid `http` or `https` URL.
    public static func make(urlTemplate: String, method: String, bodyTemplate: String, context: TemplateContext) -> URLRequest? {
        guard let url = URL(string: context.expand(urlTemplate, escaping: .url)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil
        else { return nil }

        var request = URLRequest(url: url, timeoutInterval: 5)
        let method = method.uppercased()
        request.httpMethod = method.isEmpty ? "POST" : method
        let trimmed = bodyTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, request.httpMethod != "GET" {
            let isJSON = trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
            request.httpBody = Data(context.expand(bodyTemplate, escaping: isJSON ? .json : .none).utf8)
            request.setValue(isJSON ? "application/json" : "text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        return request
    }
}
