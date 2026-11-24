import Foundation

/// The speech libraries read environment variables that move model
/// downloads to another server or attach an account token to them. Wilco
/// downloads public models from their published home only, so the app
/// clears these at launch: nothing inherited from the environment can
/// redirect a download or leak a token.
public enum DownloadEnvironment {
    public static let variables = [
        "HF_ENDPOINT", "REGISTRY_URL", "MODEL_REGISTRY_URL",
        "HF_TOKEN", "HUGGING_FACE_HUB_TOKEN", "HUGGINGFACEHUB_API_TOKEN",
    ]

    /// Call once at launch, before any model work starts.
    public static func lockDown() {
        for name in variables { unsetenv(name) }
    }
}
