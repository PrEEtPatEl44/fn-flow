import Foundation

/// Owns the local AI runtime: installs it (runtime/install_runtime.sh), launches the
/// Parakeet ASR server as a child process, and keeps Ollama/Nemotron available.
@MainActor
final class RuntimeManager: ObservableObject {
    static let shared = RuntimeManager()

    enum Status: Equatable {
        case checking, notInstalled, installing, starting, ready
        case failed(String)

        var label: String {
            switch self {
            case .checking: "Checking…"
            case .notInstalled: "Not installed"
            case .installing: "Installing…"
            case .starting: "Starting…"
            case .ready: "Ready"
            case .failed(let why): why
            }
        }
    }

    @Published private(set) var asrStatus: Status = .checking
    @Published private(set) var llmStatus: Status = .checking
    @Published private(set) var installLog = ""
    @Published private(set) var isInstalling = false

    var isReady: Bool { asrStatus == .ready }

    let runtimeDir = AppSettings.supportDirectory.appendingPathComponent("runtime", isDirectory: true)
    private var pythonURL: URL { runtimeDir.appendingPathComponent(".venv/bin/python") }
    private var serverScript: URL { runtimeDir.appendingPathComponent("server.py") }
    private var asrModelMarker: URL { runtimeDir.appendingPathComponent("asr_model") }

    var asrBaseURL: URL { URL(string: "http://127.0.0.1:\(AppSettings.shared.asrPort)")! }

    private var serverProcess: Process?
    private var installProcess: Process?
    private var logLines: [String] = []

    var isInstalled: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: pythonURL.path)
            && fm.fileExists(atPath: serverScript.path)
            && fm.fileExists(atPath: asrModelMarker.path)
    }

    /// Bundled scripts live in the .app's Resources; fall back to the repo when run via `swift run`.
    private func bundledRuntimeFile(_ name: String) -> URL? {
        let parts = name.split(separator: ".")
        if let url = Bundle.main.url(forResource: String(parts[0]), withExtension: String(parts[1])) {
            return url
        }
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = repo.appendingPathComponent("runtime/\(name)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private var processEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = ["\(runtimeDir.path)/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }

    // MARK: Lifecycle

    func bootstrap() async {
        async let asr: Void = startASR()
        async let llm: Void = refreshLLM()
        _ = await (asr, llm)
    }

    func startASR() async {
        if await asrHealthy() {
            asrStatus = .ready
            return
        }
        guard isInstalled else {
            asrStatus = .notInstalled
            return
        }
        asrStatus = .starting

        // Keep the runtime's server in sync with the one shipped in the app.
        if let bundled = bundledRuntimeFile("server.py") {
            try? FileManager.default.removeItem(at: serverScript)
            try? FileManager.default.copyItem(at: bundled, to: serverScript)
        }

        let process = Process()
        process.executableURL = pythonURL
        process.arguments = [serverScript.path, "--port", String(AppSettings.shared.asrPort)]
        process.currentDirectoryURL = runtimeDir
        var env = processEnvironment
        env["HF_HUB_OFFLINE"] = "1" // the model was downloaded by the installer
        if let model = try? String(contentsOf: asrModelMarker, encoding: .utf8) {
            env["FN_FLOW_ASR_MODEL"] = model.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        process.environment = env
        let logURL = runtimeDir.appendingPathComponent("server.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try? FileHandle(forWritingTo: logURL)
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.terminationHandler = { proc in
            let code = proc.terminationStatus
            Task { @MainActor in
                let manager = RuntimeManager.shared
                guard manager.serverProcess === proc else { return }
                manager.serverProcess = nil
                manager.asrStatus = .failed("ASR server exited (\(code)). See runtime/server.log")
            }
        }
        do {
            try process.run()
            serverProcess = process
        } catch {
            asrStatus = .failed("Couldn't launch ASR server: \(error.localizedDescription)")
            return
        }

        // Model load + MLX warm-up can take a while on first launch.
        for _ in 0..<180 {
            try? await Task.sleep(for: .seconds(1))
            if serverProcess == nil { return } // exited; termination handler set the status
            if await asrHealthy() {
                asrStatus = .ready
                return
            }
        }
        asrStatus = .failed("ASR server didn't start in time. See runtime/server.log")
    }

    func stopASR() {
        let process = serverProcess
        serverProcess = nil
        process?.terminate()
    }

    func asrHealthy() async -> Bool {
        var request = URLRequest(url: asrBaseURL.appendingPathComponent("health"), timeoutInterval: 2)
        request.httpMethod = "GET"
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let health = try? JSONDecoder().decode(Health.self, from: data) else { return false }
        return health.loaded
    }

    func refreshLLM() async {
        let model = AppSettings.shared.llmModel
        var tags = await ollamaModels()
        if tags == nil {
            launchOllama()
            for _ in 0..<20 where tags == nil {
                try? await Task.sleep(for: .seconds(1))
                tags = await ollamaModels()
            }
        }
        guard let tags else {
            llmStatus = .failed("Ollama isn't running")
            return
        }
        let installed = tags.contains { $0 == model || $0 == "\(model):latest" }
        llmStatus = installed ? .ready : .notInstalled
        if installed { await AIBridge.shared.warmUpLLM(model: model) }
    }

    private func ollamaModels() async -> [String]? {
        let url = AIBridge.ollamaURL.appendingPathComponent("api/tags")
        guard let (data, _) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 2)),
              let tags = try? JSONDecoder().decode(OllamaTags.self, from: data) else { return nil }
        return tags.models.map(\.name)
    }

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

    // MARK: Install

    func install() {
        guard !isInstalling else { return }
        guard let script = bundledRuntimeFile("install_runtime.sh") else {
            installLog = "install_runtime.sh not found in the app bundle."
            return
        }
        stopASR()
        isInstalling = true
        asrStatus = .installing
        logLines = []
        installLog = ""

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        var env = processEnvironment
        env["FN_FLOW_RUNTIME_DIR"] = runtimeDir.path
        env["FN_FLOW_LLM_MODEL"] = AppSettings.shared.llmModel
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in RuntimeManager.shared.appendLog(chunk) }
        }
        process.terminationHandler = { proc in
            let ok = proc.terminationStatus == 0
            Task { @MainActor in
                let manager = RuntimeManager.shared
                pipe.fileHandleForReading.readabilityHandler = nil
                manager.isInstalling = false
                manager.installProcess = nil
                manager.appendLog(ok ? "\n✅ Install finished.\n" : "\n❌ Install failed (exit \(proc.terminationStatus)).\n")
                manager.asrStatus = ok ? .checking : .failed("Install failed. See log")
                if ok { await manager.bootstrap() }
            }
        }
        do {
            try process.run()
            installProcess = process
        } catch {
            isInstalling = false
            asrStatus = .failed("Couldn't run installer: \(error.localizedDescription)")
        }
    }

    func cancelInstall() {
        installProcess?.terminate()
    }

    private func appendLog(_ chunk: String) {
        let clean = chunk
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "\n")
        for line in clean.components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            // Collapse progress-bar spam (ollama/pip/hf) into a single updating line.
            if let last = logLines.last, line.contains("%"), last.contains("%"),
               line.prefix(12) == last.prefix(12) {
                logLines[logLines.count - 1] = line
            } else {
                logLines.append(line)
            }
        }
        if logLines.count > 400 { logLines.removeFirst(logLines.count - 400) }
        installLog = logLines.joined(separator: "\n")
    }
}

private struct Health: Decodable { let loaded: Bool }
private struct OllamaTags: Decodable {
    struct Model: Decodable { let name: String }
    let models: [Model]
}
