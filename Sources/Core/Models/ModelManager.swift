import FluidAudio
import Foundation

/// Owns the local models, all managed from inside the app (#6): no bash, Python, or Homebrew.
///
/// - Speech-to-text: Parakeet v2 Core ML models (~480 MB), downloaded from Hugging Face into
///   Application Support with live progress, then loaded in-process by `SpeechEngine`. An
///   existing FluidAudio cache is reused instead of downloading again.
/// - Text cleanup: Nemotron through Ollama, which is optional. Fn-flow never installs Ollama;
///   when it's present, the model is pulled through Ollama's API with live progress. Without
///   it, dictation still works with rule-based cleanup.
@MainActor
final class ModelManager: ObservableObject {
    static let shared = ModelManager()

    enum Status: Equatable {
        case checking
        /// Speech model not downloaded yet, or the Nemotron model not pulled yet.
        case notInstalled
        /// Ollama itself isn't installed or running (only for the cleanup model).
        case unavailable(String)
        case downloading(progress: Double, detail: String)
        /// Loading, or compiling for the Neural Engine on first use.
        case loading
        case ready
        case failed(String)

        var label: String {
            switch self {
            case .checking: "Checking…"
            case .notInstalled: "Not downloaded"
            case .unavailable(let why): why
            case .downloading(let progress, let detail): "\(detail) \(Int(progress * 100))%"
            case .loading: "Preparing…"
            case .ready: "Ready"
            case .failed(let why): why
            }
        }

        var isBusy: Bool {
            switch self {
            case .checking, .downloading, .loading: true
            default: false
            }
        }
    }

    @Published private(set) var speechStatus: Status = .checking
    @Published private(set) var cleanupStatus: Status = .checking
    /// Size of the pre-#6 Python runtime folder, if it's still on disk (nil when gone).
    @Published private(set) var legacyRuntimeSize: Int64?

    var isReady: Bool { speechStatus == .ready }
    var isSpeechModelInstalled: Bool { installedSpeechModelDirectory != nil }

    /// Where Fn-flow downloads the speech model. FluidAudio treats this folder's *parent* as
    /// the models directory and uses its own folder name inside it, so this must match that
    /// name (`parakeet-tdt-0.6b-v2`) to describe what's actually on disk.
    let speechModelDirectory = AppSettings.supportDirectory
        .appendingPathComponent("models/parakeet-tdt-0.6b-v2", isDirectory: true)
    let legacyRuntimeDirectory = AppSettings.supportDirectory.appendingPathComponent("runtime", isDirectory: true)
    static let speechModelSize = "~480 MB"

    private var pullTask: Task<Void, Never>?

    /// Our download, or a copy FluidAudio already cached for another app (like Handy
    /// reusing the shared Hugging Face cache).
    private var installedSpeechModelDirectory: URL? {
        [speechModelDirectory, AsrModels.defaultCacheDirectory(for: SpeechEngine.version)]
            .first { AsrModels.modelsExist(at: $0, version: SpeechEngine.version) }
    }

    // MARK: Startup

    func bootstrap() async {
        measureLegacyRuntime()
        async let speech: Void = loadSpeechModel()
        async let cleanup: Void = refreshCleanupModel()
        _ = await (speech, cleanup)
    }

    // MARK: Speech-to-text model

    func loadSpeechModel() async {
        guard let directory = installedSpeechModelDirectory else {
            speechStatus = .notInstalled
            return
        }
        guard !SpeechEngine.shared.isLoaded else {
            speechStatus = .ready
            return
        }
        speechStatus = .loading
        do {
            try await SpeechEngine.shared.load(from: directory)
            speechStatus = .ready
        } catch {
            speechStatus = .failed("Couldn't load the speech model: \(error.localizedDescription)")
        }
    }

    func downloadSpeechModel() {
        guard !speechStatus.isBusy else { return }
        speechStatus = .downloading(progress: 0, detail: "Starting…")
        Task {
            do {
                try FileManager.default.createDirectory(
                    at: speechModelDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await AsrModels.download(to: speechModelDirectory, version: SpeechEngine.version) { progress in
                    let detail: String
                    switch progress.phase {
                    case .listing: detail = "Preparing download…"
                    case .downloading(let done, let total): detail = "Downloading file \(min(done + 1, total)) of \(total)…"
                    case .compiling: detail = "Optimizing for this Mac…"
                    }
                    Task { @MainActor in
                        ModelManager.shared.speechStatus = .downloading(progress: progress.fractionCompleted, detail: detail)
                    }
                }
                await loadSpeechModel()
            } catch {
                speechStatus = .failed("Download failed: \(error.localizedDescription). Check your connection and try again.")
            }
        }
    }

    // MARK: Cleanup model (Nemotron via Ollama, optional)

    func refreshCleanupModel() async {
        let model = AppSettings.shared.llmModel
        var tags = await ollamaModels()
        if tags == nil, Self.ollamaInstalled {
            launchOllama()
            for _ in 0..<20 where tags == nil {
                try? await Task.sleep(for: .seconds(1))
                tags = await ollamaModels()
            }
        }
        guard let tags else {
            cleanupStatus = .unavailable(Self.ollamaInstalled ? "Ollama isn't responding" : "Ollama not installed (optional)")
            return
        }
        let installed = tags.contains { $0 == model || $0 == "\(model):latest" }
        cleanupStatus = installed ? .ready : .notInstalled
        if installed { await AIBridge.shared.warmUpLLM(model: model) }
    }

    /// Pulls the cleanup model through Ollama's API, streaming its progress.
    func downloadCleanupModel() {
        guard !cleanupStatus.isBusy else { return }
        let model = AppSettings.shared.llmModel
        cleanupStatus = .downloading(progress: 0, detail: "Starting…")
        pullTask = Task {
            do {
                var request = URLRequest(url: AIBridge.ollamaURL.appendingPathComponent("api/pull"))
                request.httpMethod = "POST"
                request.httpBody = try JSONEncoder().encode(["model": model])
                let (lines, response) = try await URLSession.shared.bytes(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw FlowError.runtimeNotReady }
                for try await line in lines.lines {
                    guard let update = try? JSONDecoder().decode(PullUpdate.self, from: Data(line.utf8)) else { continue }
                    if let error = update.error { throw PullError(message: error) }
                    if let total = update.total, total > 0, let completed = update.completed {
                        cleanupStatus = .downloading(progress: Double(completed) / Double(total), detail: "Downloading \(model)…")
                    }
                }
                await refreshCleanupModel()
            } catch is CancellationError {
                cleanupStatus = .notInstalled
            } catch {
                cleanupStatus = .failed("Download failed: \(error.localizedDescription)")
            }
        }
    }

    func cancelCleanupDownload() {
        pullTask?.cancel()
    }

    static let ollamaDownloadURL = URL(string: "https://ollama.com/download")!

    private static var ollamaInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Applications/Ollama.app")
            || ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"].contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func ollamaModels() async -> [String]? {
        let url = AIBridge.ollamaURL.appendingPathComponent("api/tags")
        guard let (data, _) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 2)),
              let tags = try? JSONDecoder().decode(OllamaTags.self, from: data) else { return nil }
        return tags.models.map(\.name)
    }

    /// Starts an Ollama the user already installed (never installs it).
    private func launchOllama() {
        let process = Process()
        if FileManager.default.fileExists(atPath: "/Applications/Ollama.app") {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-g", "-a", "Ollama"]
        } else if let binary = ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["serve"]
        } else {
            return
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    // MARK: Pre-#6 Python runtime

    /// The old bash-installed Python runtime is no longer used. It's never deleted
    /// automatically; Settings offers to remove it.
    func measureLegacyRuntime() {
        let directory = legacyRuntimeDirectory
        guard FileManager.default.fileExists(atPath: directory.path) else {
            legacyRuntimeSize = nil
            return
        }
        Task.detached {
            let size = Self.directorySize(directory)
            await MainActor.run { ModelManager.shared.legacyRuntimeSize = size }
        }
    }

    func removeLegacyRuntime() {
        try? FileManager.default.removeItem(at: legacyRuntimeDirectory)
        measureLegacyRuntime()
    }

    nonisolated private static func directorySize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            let values = try? file.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }
}

private struct OllamaTags: Decodable {
    struct Model: Decodable { let name: String }
    let models: [Model]
}

private struct PullUpdate: Decodable {
    let status: String?
    let total: Int64?
    let completed: Int64?
    let error: String?
}

private struct PullError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
