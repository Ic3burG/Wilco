import WilcoTranscription

extension TranscriberStatus {
    var title: String {
        switch self {
        case .preparing: "Preparing…"
        case .downloading(let progress): "Downloading speech model… \(Int(progress * 100))%"
        case .listening: "Listening"
        case .failed(let message): message
        }
    }
}
