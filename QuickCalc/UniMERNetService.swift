//
//  UniMERNetService.swift
//  QuickCalc
//
//  Created by Codex on 10.04.2026.
//

import Foundation

enum UniMERNetServiceError: LocalizedError {
    case pythonMissing(URL?)
    case bootstrapScriptMissing(URL)
    case workerMissing(URL)
    case bootstrapFailed(details: String?)
    case workerStartupFailed(details: String?)
    case recognitionFailed(details: String?)
    case malformedWorkerReply

    var errorDescription: String? {
        switch self {
        case .pythonMissing:
            return "A supported Python 3 runtime was not found."
        case .bootstrapScriptMissing:
            return "The AI bootstrap script is missing."
        case .workerMissing:
            return "The AI worker script is missing."
        case .bootstrapFailed:
            return "The AI model could not be prepared."
        case .workerStartupFailed:
            return "The AI model could not be started."
        case .recognitionFailed, .malformedWorkerReply:
            return "Handwriting could not be read."
        }
    }
}

actor UniMERNetService {
    static let shared = UniMERNetService()

    private enum WorkerDevice: String, CaseIterable {
        case mps
        case cpu
    }

    private enum ModelVariant: String, CaseIterable {
        case base
        case small
        case tiny
    }

    private struct WorkerConfiguration: Equatable, Sendable {
        let variant: ModelVariant
        let device: WorkerDevice
    }

    private struct WorkerRequest: Encodable {
        let id: String
        let imagePath: String

        enum CodingKeys: String, CodingKey {
            case id
            case imagePath = "image_path"
        }
    }

    private struct BootstrapResponse: Decodable {
        let ok: Bool
        let pythonPath: String
        let modelDir: String

        enum CodingKeys: String, CodingKey {
            case ok
            case pythonPath = "python_path"
            case modelDir = "model_dir"
        }
    }

    private struct WorkerResponse: Decodable {
        let type: String
        let id: String?
        let ok: Bool
        let latex: String?
        let errorCode: String?

        enum CodingKeys: String, CodingKey {
            case type
            case id
            case ok
            case latex
            case errorCode = "error_code"
        }
    }

    private struct PendingRequest {
        let continuation: CheckedContinuation<String, Error>
    }

    private struct BootstrapState {
        let pythonURL: URL
        let modelDirectoryURL: URL
    }

    private struct PythonVersion: Comparable {
        let major: Int
        let minor: Int
        let patch: Int

        static func < (lhs: PythonVersion, rhs: PythonVersion) -> Bool {
            if lhs.major != rhs.major {
                return lhs.major < rhs.major
            }

            if lhs.minor != rhs.minor {
                return lhs.minor < rhs.minor
            }

            return lhs.patch < rhs.patch
        }

        var isSupported: Bool {
            major == 3 && minor >= 10
        }
    }

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let fileManager = FileManager.default

    private var bootstrapStates: [ModelVariant: BootstrapState] = [:]
    private var process: Process?
    private var standardInput: FileHandle?
    private var stdoutBuffer = Data()
    private var pending: [String: PendingRequest] = [:]
    private var startupContinuation: CheckedContinuation<Void, Error>?
    private var queuedStartupResult: Result<Void, Error>?
    private var preparationTask: Task<Void, Error>?
    private var currentConfiguration: WorkerConfiguration?
    private var hasSuccessfulInference = false
    private var quarantinedDevices: Set<WorkerDevice> = []

    func prewarm() async {
        do {
            try await ensureWorkerReady()
        } catch {
            await logInternal("prewarm_failed: \(error.localizedDescription)", to: paths.bootstrapLogURL)
        }
    }

    func recognize(imageURL: URL) async throws -> String {
        try await ensureWorkerReady()

        do {
            let latex = try await sendRequest(imageURL: imageURL)
            hasSuccessfulInference = true
            return latex
        } catch {
            guard let currentConfiguration, shouldAttemptFallback(after: error, from: currentConfiguration) else {
                throw sanitize(error)
            }

            if currentConfiguration.device == .mps {
                await quarantineDevice(.mps, reason: "runtime_failure: \(error.localizedDescription)")
            }

            var lastError = error

            for fallbackConfiguration in fallbackConfigurations(after: currentConfiguration) {
                do {
                    await logInternal(
                        "retrying_with_\(fallbackConfiguration.variant.rawValue)_\(fallbackConfiguration.device.rawValue)",
                        to: paths.bootstrapLogURL
                    )

                    try await restartWorker(with: fallbackConfiguration)
                    let latex = try await sendRequest(imageURL: imageURL)
                    hasSuccessfulInference = true
                    return latex
                } catch {
                    if fallbackConfiguration.device == .mps {
                        await quarantineDevice(.mps, reason: "fallback_failure: \(error.localizedDescription)")
                    }
                    lastError = error
                }
            }

            throw sanitize(lastError)
        }
    }

    private func ensureWorkerReady() async throws {
        if let process, process.isRunning {
            return
        }

        if let preparationTask {
            return try await preparationTask.value
        }

        let task = Task {
            try await self.prepareWorker()
        }
        preparationTask = task

        defer {
            preparationTask = nil
        }

        try await task.value
    }

    private func prepareWorker() async throws {
        let startupPlans = availableStartupPlans()

        var lastError: Error?

        for configuration in startupPlans {
            do {
                try await startWorker(with: configuration)
                return
            } catch {
                if configuration.device == .mps {
                    await quarantineDevice(.mps, reason: "startup_failure: \(error.localizedDescription)")
                }
                lastError = error
                await logInternal(
                    "startup_failed[\(configuration.variant.rawValue)-\(configuration.device.rawValue)]: \(error.localizedDescription)",
                    to: paths.bootstrapLogURL
                )
            }
        }

        throw sanitize(lastError ?? UniMERNetServiceError.workerStartupFailed(details: "no_configuration_succeeded"))
    }

    private func restartWorker(with configuration: WorkerConfiguration) async throws {
        shutdownWorker()
        try await startWorker(with: configuration)
    }

    private func startWorker(with configuration: WorkerConfiguration) async throws {
        let bootstrapState = try bootstrapRuntime(for: configuration.variant)
        guard fileManager.fileExists(atPath: paths.workerURL.path) else {
            throw UniMERNetServiceError.workerMissing(paths.workerURL)
        }

        try fileManager.createDirectory(at: paths.logsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.appSupportURL, withIntermediateDirectories: true)

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = bootstrapState.pythonURL
        process.arguments = [
            "-u",
            paths.workerURL.path,
            "--model-dir",
            bootstrapState.modelDirectoryURL.path,
            "--device",
            configuration.device.rawValue,
            "--log-file",
            paths.workerLogURL.path
        ]
        process.currentDirectoryURL = paths.appSupportURL
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            Task {
                await self.handleStdout(data)
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            Task {
                await self.handleStderr(data)
            }
        }

        process.terminationHandler = { [self] finishedProcess in
            Task {
                await self.handleTermination(status: finishedProcess.terminationStatus)
            }
        }

        stdoutBuffer.removeAll(keepingCapacity: true)
        pending.removeAll()
        queuedStartupResult = nil
        hasSuccessfulInference = false
        currentConfiguration = nil

        do {
            try process.run()
        } catch {
            throw UniMERNetServiceError.workerStartupFailed(details: error.localizedDescription)
        }

        self.process = process
        standardInput = inputPipe.fileHandleForWriting

        do {
            try await waitForStartupReady()
            currentConfiguration = configuration
        } catch {
            shutdownWorker()
            throw error
        }
    }

    private func waitForStartupReady() async throws {
        if let queuedStartupResult {
            self.queuedStartupResult = nil
            return try queuedStartupResult.get()
        }

        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: 90_000_000_000)
            self.handleStartupTimeout()
        }

        defer {
            timeoutTask.cancel()
        }

        try await withCheckedThrowingContinuation { continuation in
            if let queuedStartupResult {
                self.queuedStartupResult = nil
                continuation.resume(with: queuedStartupResult)
                return
            }

            startupContinuation = continuation
        }
    }

    private func sendRequest(imageURL: URL) async throws -> String {
        guard let standardInput else {
            throw UniMERNetServiceError.recognitionFailed(details: "worker_input_missing")
        }

        let requestID = UUID().uuidString
        let payload = WorkerRequest(id: requestID, imagePath: imageURL.path)
        var encoded = try encoder.encode(payload)
        encoded.append(0x0A)

        return try await withCheckedThrowingContinuation { continuation in
            pending[requestID] = PendingRequest(continuation: continuation)

            do {
                try standardInput.write(contentsOf: encoded)
            } catch {
                pending.removeValue(forKey: requestID)
                continuation.resume(
                    throwing: UniMERNetServiceError.recognitionFailed(details: error.localizedDescription)
                )
            }
        }
    }

    private func handleStdout(_ data: Data) {
        guard !data.isEmpty else { return }

        stdoutBuffer.append(data)

        while let newlineIndex = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer.prefix(upTo: newlineIndex)
            stdoutBuffer.removeSubrange(...newlineIndex)

            guard !lineData.isEmpty else { continue }

            do {
                let response = try decoder.decode(WorkerResponse.self, from: lineData)
                handleWorkerResponse(response)
            } catch {
                let rawLine = String(decoding: lineData, as: UTF8.self)
                Task {
                    await self.logInternal("stdout_non_json: \(rawLine)", to: self.paths.stdoutLogURL)
                }
            }
        }
    }

    private func handleWorkerResponse(_ response: WorkerResponse) {
        switch response.type {
        case "ready":
            let result: Result<Void, Error>
            if response.ok {
                result = .success(())
            } else {
                result = .failure(
                    UniMERNetServiceError.workerStartupFailed(details: response.errorCode)
                )
            }

            if let continuation = startupContinuation {
                startupContinuation = nil
                continuation.resume(with: result)
            } else {
                queuedStartupResult = result
            }

        case "result":
            guard let id = response.id, let pendingRequest = pending.removeValue(forKey: id) else {
                return
            }

            if response.ok, let latex = response.latex {
                pendingRequest.continuation.resume(returning: latex)
            } else {
                pendingRequest.continuation.resume(
                    throwing: UniMERNetServiceError.recognitionFailed(details: response.errorCode)
                )
            }

        default:
            Task {
                await self.logInternal("unknown_worker_message_type: \(response.type)", to: self.paths.stdoutLogURL)
            }
        }
    }

    private func handleStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        let text = String(decoding: data, as: UTF8.self)

        Task {
            await self.logInternal(text, to: self.paths.stderrLogURL)
        }
    }

    private func handleStartupTimeout() {
        guard let continuation = startupContinuation else { return }
        startupContinuation = nil
        continuation.resume(throwing: UniMERNetServiceError.workerStartupFailed(details: "timeout"))
        shutdownWorker()
    }

    private func handleTermination(status: Int32) {
        let startupContinuation = startupContinuation
        self.startupContinuation = nil

        let requests = pending
        pending.removeAll()

        process = nil
        standardInput = nil
        stdoutBuffer.removeAll(keepingCapacity: true)
        currentConfiguration = nil
        queuedStartupResult = nil

        if let startupContinuation {
            startupContinuation.resume(
                throwing: UniMERNetServiceError.workerStartupFailed(details: "terminated_\(status)")
            )
        }

        for request in requests.values {
            request.continuation.resume(
                throwing: UniMERNetServiceError.recognitionFailed(details: "terminated_\(status)")
            )
        }
    }

    private func shutdownWorker() {
        process?.terminationHandler = nil
        process?.standardOutput = nil
        process?.standardError = nil
        process?.standardInput = nil

        if let process, process.isRunning {
            process.terminate()
        }

        process = nil
        standardInput = nil
        stdoutBuffer.removeAll(keepingCapacity: true)
        queuedStartupResult = nil
        currentConfiguration = nil

        if let startupContinuation {
            self.startupContinuation = nil
            startupContinuation.resume(throwing: UniMERNetServiceError.workerStartupFailed(details: "interrupted"))
        }

        let requests = pending
        pending.removeAll()
        for request in requests.values {
            request.continuation.resume(throwing: UniMERNetServiceError.recognitionFailed(details: "interrupted"))
        }
    }

    private func bootstrapRuntime(for variant: ModelVariant) throws -> BootstrapState {
        if let state = bootstrapStates[variant],
           fileManager.isExecutableFile(atPath: state.pythonURL.path),
           fileManager.fileExists(atPath: state.modelDirectoryURL.path) {
            return state
        }

        guard fileManager.fileExists(atPath: paths.bootstrapURL.path) else {
            throw UniMERNetServiceError.bootstrapScriptMissing(paths.bootstrapURL)
        }

        try fileManager.createDirectory(at: paths.appSupportURL, withIntermediateDirectories: true)

        let bootstrapPython = try locateBootstrapPython()
        let result = try runProcess(
            executableURL: bootstrapPython,
            arguments: [
                "-u",
                paths.bootstrapURL.path,
                "--app-support-dir",
                paths.appSupportURL.path,
                "--model",
                variant.rawValue
            ],
            currentDirectoryURL: paths.appSupportURL
        )

        if result.stderr.isEmpty == false {
            try appendLog(result.stderr, to: paths.bootstrapLogURL)
        }

        guard result.terminationStatus == 0 else {
            throw UniMERNetServiceError.bootstrapFailed(
                details: String(decoding: result.stderr, as: UTF8.self)
            )
        }

        let stdoutText = String(decoding: result.stdout, as: UTF8.self)
        guard let lastLine = stdoutText
            .split(whereSeparator: \.isNewline)
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let data = lastLine.data(using: .utf8) else {
            throw UniMERNetServiceError.bootstrapFailed(details: "empty_bootstrap_output")
        }

        let response: BootstrapResponse
        do {
            response = try decoder.decode(BootstrapResponse.self, from: data)
        } catch {
            try appendLog(data, to: paths.stdoutLogURL)
            throw UniMERNetServiceError.bootstrapFailed(details: "bootstrap_json_parse_failed")
        }

        guard response.ok else {
            throw UniMERNetServiceError.bootstrapFailed(details: "bootstrap_not_ok")
        }

        let state = BootstrapState(
            pythonURL: URL(fileURLWithPath: response.pythonPath),
            modelDirectoryURL: URL(fileURLWithPath: response.modelDir)
        )
        bootstrapStates[variant] = state
        return state
    }

    private func fallbackConfigurations(after configuration: WorkerConfiguration) -> [WorkerConfiguration] {
        let startupPlans = Self.startupPlans(
            environment: ProcessInfo.processInfo.environment,
            physicalMemory: ProcessInfo.processInfo.physicalMemory
        )

        guard let currentIndex = startupPlans.firstIndex(of: configuration) else {
            return availableStartupPlans()
        }

        let remaining = Array(startupPlans.dropFirst(currentIndex + 1))
        let filtered = remaining.filter { quarantinedDevices.contains($0.device) == false }
        return filtered.isEmpty ? remaining : filtered
    }

    private func availableStartupPlans() -> [WorkerConfiguration] {
        let startupPlans = Self.startupPlans(
            environment: ProcessInfo.processInfo.environment,
            physicalMemory: ProcessInfo.processInfo.physicalMemory
        )
        let filtered = startupPlans.filter { quarantinedDevices.contains($0.device) == false }
        return filtered.isEmpty ? startupPlans : filtered
    }

    private func shouldAttemptFallback(after error: Error, from configuration: WorkerConfiguration) -> Bool {
        if configuration.device == .mps {
            return true
        }

        return hasSuccessfulInference == false
    }

    private func quarantineDevice(_ device: WorkerDevice, reason: String) async {
        guard device == .mps else { return }
        guard quarantinedDevices.insert(device).inserted else { return }

        await logInternal(
            "device_quarantined[\(device.rawValue)]: \(reason)",
            to: paths.bootstrapLogURL
        )
    }

    private func sanitize(_ error: Error) -> Error {
        if let serviceError = error as? UniMERNetServiceError {
            return serviceError
        }

        return UniMERNetServiceError.recognitionFailed(details: error.localizedDescription)
    }

    nonisolated private static func startupPlans(
        environment: [String: String],
        physicalMemory: UInt64
    ) -> [WorkerConfiguration] {
        let variants = preferredModelVariants(environment: environment, physicalMemory: physicalMemory)
        let devices = preferredDevices(environment: environment)

        return variants.flatMap { variant in
            devices.map { device in
                WorkerConfiguration(variant: variant, device: device)
            }
        }
    }

    nonisolated private static func preferredModelVariants(
        environment: [String: String],
        physicalMemory: UInt64
    ) -> [ModelVariant] {
        if let override = environment["QUICKCALC_UNIMERNET_MODEL"]?.lowercased(),
           let variant = ModelVariant(rawValue: override) {
            return [variant]
        }

        let memoryInGiB = Double(physicalMemory) / 1_073_741_824
        if memoryInGiB < 8 {
            return [.tiny, .small, .base]
        }

        if memoryInGiB < 16 {
            return [.small, .base, .tiny]
        }

        return [.base, .small, .tiny]
    }

    nonisolated private static func preferredDevices(environment: [String: String]) -> [WorkerDevice] {
        preferredDevices(environment: environment, supportsMPS: systemSupportsMPS())
    }

    nonisolated private static func preferredDevices(
        environment: [String: String],
        supportsMPS: Bool
    ) -> [WorkerDevice] {
        if let override = environment["QUICKCALC_UNIMERNET_DEVICE"]?.lowercased(),
           let device = WorkerDevice(rawValue: override) {
            switch device {
            case .cpu:
                return [.cpu]
            case .mps:
                return supportsMPS ? [.mps, .cpu] : [.cpu]
            }
        }

        return [.cpu]
    }

    nonisolated private static func systemSupportsMPS() -> Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    private func locateBootstrapPython() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let pathDirectories = (environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":")
            .map(String.init)

        let explicitCandidates = [
            environment["QUICKCALC_PYTHON"],
            environment["QUICKCALC_PYTHON3"],
            environment["QUICKCALC_PYTHON312"],
            environment["QUICKCALC_PYTHON311"],
            environment["QUICKCALC_PYTHON310"]
        ].compactMap { $0 }

        let pathCandidates = pathDirectories.flatMap { directory in
            ["python3.12", "python3.11", "python3.10", "python3"].map { "\(directory)/\($0)" }
        }

        let commonCandidates = [
            "/opt/homebrew/bin/python3.12",
            "/opt/homebrew/bin/python3.11",
            "/opt/homebrew/bin/python3.10",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3.12",
            "/usr/local/bin/python3.11",
            "/usr/local/bin/python3.10",
            "/usr/local/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12",
            "/Library/Frameworks/Python.framework/Versions/3.11/bin/python3.11",
            "/Library/Frameworks/Python.framework/Versions/3.10/bin/python3.10",
            "/usr/bin/python3"
        ]

        var uniquePaths = Set<String>()
        var supportedCandidates: [(url: URL, version: PythonVersion)] = []

        for path in explicitCandidates + pathCandidates + commonCandidates {
            guard uniquePaths.insert(path).inserted else { continue }
            guard fileManager.isExecutableFile(atPath: path) else { continue }

            let url = URL(fileURLWithPath: path)
            guard let version = try? pythonVersion(at: url), version.isSupported else {
                continue
            }

            supportedCandidates.append((url: url, version: version))
        }

        if let selected = supportedCandidates.max(by: { $0.version < $1.version }) {
            return selected.url
        }

        throw UniMERNetServiceError.pythonMissing(nil)
    }

    private func pythonVersion(at executableURL: URL) throws -> PythonVersion {
        let result = try runProcess(
            executableURL: executableURL,
            arguments: [
                "-c",
                "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}')"
            ],
            currentDirectoryURL: paths.appSupportURL
        )

        guard result.terminationStatus == 0 else {
            throw UniMERNetServiceError.pythonMissing(executableURL)
        }

        let versionText = String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let components = versionText.split(separator: ".").compactMap { Int($0) }
        guard components.count == 3 else {
            throw UniMERNetServiceError.pythonMissing(executableURL)
        }

        return PythonVersion(major: components[0], minor: components[1], patch: components[2])
    }

    private func runProcess(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL
    ) throws -> (terminationStatus: Int32, stdout: Data, stderr: Data) {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, stdout, stderr)
    }

    private func appendLog(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: url.path) == false {
            fileManager.createFile(atPath: url.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data("\n".utf8))
    }

    private func logInternal(_ message: String, to url: URL) async {
        try? appendLog(Data(message.utf8), to: url)
    }

    private var paths: UniMERNetPaths {
        UniMERNetPaths()
    }

    nonisolated static func preferredDeviceNamesForTesting(
        environment: [String: String],
        supportsMPS: Bool
    ) -> [String] {
        preferredDevices(environment: environment, supportsMPS: supportsMPS).map(\.rawValue)
    }
}

private struct UniMERNetPaths {
    let appSupportURL: URL
    let logsURL: URL
    let bootstrapURL: URL
    let workerURL: URL
    let bootstrapLogURL: URL
    let workerLogURL: URL
    let stderrLogURL: URL
    let stdoutLogURL: URL

    nonisolated init() {
        let fileManager = FileManager.default
        let sourceFileURL = URL(fileURLWithPath: #filePath)
        let sourceRootURL = sourceFileURL.deletingLastPathComponent()
        let applicationSupportBaseURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

        let appSupportURL = applicationSupportBaseURL
            .appendingPathComponent("QuickCalc", isDirectory: true)
        let logsURL = appSupportURL.appendingPathComponent("logs", isDirectory: true)

        let supportCandidates = [
            Bundle.main.resourceURL,
            Bundle.main.resourceURL?.appendingPathComponent("UniMERNetSupport", isDirectory: true),
            sourceRootURL.appendingPathComponent("UniMERNetSupport", isDirectory: true)
        ].compactMap { $0 }

        let supportURL = supportCandidates.first(where: {
            fileManager.fileExists(atPath: $0.appendingPathComponent("unimernet_bootstrap.py").path)
                && fileManager.fileExists(atPath: $0.appendingPathComponent("unimernet_worker.py").path)
        }) ?? sourceRootURL.appendingPathComponent("UniMERNetSupport", isDirectory: true)

        self.appSupportURL = appSupportURL
        self.logsURL = logsURL
        self.bootstrapURL = supportURL.appendingPathComponent("unimernet_bootstrap.py")
        self.workerURL = supportURL.appendingPathComponent("unimernet_worker.py")
        self.bootstrapLogURL = logsURL.appendingPathComponent("unimernet-bootstrap.log")
        self.workerLogURL = logsURL.appendingPathComponent("unimernet-worker.log")
        self.stderrLogURL = logsURL.appendingPathComponent("unimernet-worker.stderr.log")
        self.stdoutLogURL = logsURL.appendingPathComponent("unimernet-worker.stdout.log")
    }
}
