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
            return "Python 3.11 was not found."
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

    private enum WorkerDevice: String {
        case mps
        case cpu
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
        let device: String?

        enum CodingKeys: String, CodingKey {
            case type
            case id
            case ok
            case latex
            case errorCode = "error_code"
            case device
        }
    }

    private struct PendingRequest {
        let continuation: CheckedContinuation<String, Error>
    }

    private struct BootstrapState {
        let pythonURL: URL
        let modelDirectoryURL: URL
    }

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let fileManager = FileManager.default

    private var bootstrapState: BootstrapState?
    private var process: Process?
    private var standardInput: FileHandle?
    private var stdoutBuffer = Data()
    private var pending: [String: PendingRequest] = [:]
    private var startupContinuation: CheckedContinuation<Void, Error>?
    private var queuedStartupResult: Result<Void, Error>?
    private var preparationTask: Task<Void, Error>?
    private var currentDevice: WorkerDevice?
    private var hasSuccessfulInference = false
    private var didFallbackToCPU = false

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
            guard shouldRetryOnCPU(after: error) else {
                throw sanitize(error)
            }

            didFallbackToCPU = true
            await logInternal("switching_to_cpu_after_first_failure", to: paths.bootstrapLogURL)
            try await restartWorker(on: .cpu)

            do {
                let latex = try await sendRequest(imageURL: imageURL)
                hasSuccessfulInference = true
                return latex
            } catch {
                throw sanitize(error)
            }
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
        _ = try bootstrapRuntime()
        let preferredDevice = Self.preferredStartupDevice(environment: ProcessInfo.processInfo.environment)

        do {
            try await startWorker(device: preferredDevice)
        } catch {
            guard preferredDevice == .mps, shouldRetryOnCPU(afterStartup: error) else {
                throw sanitize(error)
            }

            didFallbackToCPU = true
            await logInternal("mps_start_failed_retrying_cpu", to: paths.bootstrapLogURL)
            try await startWorker(device: .cpu)
        }
    }

    private func restartWorker(on device: WorkerDevice) async throws {
        shutdownWorker()
        try await startWorker(device: device)
    }

    private func startWorker(device: WorkerDevice) async throws {
        let bootstrapState = try bootstrapRuntime()
        guard fileManager.fileExists(atPath: paths.workerURL.path) else {
            throw UniMERNetServiceError.workerMissing(paths.workerURL)
        }

        try fileManager.createDirectory(at: paths.logsURL, withIntermediateDirectories: true)

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
            device.rawValue,
            "--log-file",
            paths.workerLogURL.path
        ]
        process.currentDirectoryURL = paths.projectRootURL
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
        currentDevice = nil

        do {
            try process.run()
        } catch {
            throw UniMERNetServiceError.workerStartupFailed(details: error.localizedDescription)
        }

        self.process = process
        standardInput = inputPipe.fileHandleForWriting

        do {
            try await waitForStartupReady()
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
            if let device = response.device.flatMap(WorkerDevice.init(rawValue:)) {
                currentDevice = device
            }

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
        currentDevice = nil
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

    private func bootstrapRuntime() throws -> BootstrapState {
        if let bootstrapState,
           fileManager.isExecutableFile(atPath: bootstrapState.pythonURL.path),
           fileManager.fileExists(atPath: bootstrapState.modelDirectoryURL.path) {
            return bootstrapState
        }

        guard fileManager.fileExists(atPath: paths.bootstrapURL.path) else {
            throw UniMERNetServiceError.bootstrapScriptMissing(paths.bootstrapURL)
        }

        let bootstrapPython = try locateBootstrapPython()
        let result = try runProcess(
            executableURL: bootstrapPython,
            arguments: [
                "-u",
                paths.bootstrapURL.path,
                "--app-support-dir",
                paths.appSupportURL.path
            ],
            currentDirectoryURL: paths.projectRootURL
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
        bootstrapState = state
        return state
    }

    private func shouldRetryOnCPU(afterStartup error: Error) -> Bool {
        guard didFallbackToCPU == false else { return false }

        switch error {
        case UniMERNetServiceError.pythonMissing,
             UniMERNetServiceError.bootstrapScriptMissing,
             UniMERNetServiceError.workerMissing,
             UniMERNetServiceError.bootstrapFailed:
            return false
        default:
            return true
        }
    }

    private func shouldRetryOnCPU(after error: Error) -> Bool {
        guard didFallbackToCPU == false else { return false }
        guard currentDevice == .mps else { return false }
        guard hasSuccessfulInference == false else { return false }

        switch error {
        case UniMERNetServiceError.recognitionFailed,
             UniMERNetServiceError.malformedWorkerReply:
            return true
        default:
            return false
        }
    }

    private func sanitize(_ error: Error) -> Error {
        if let serviceError = error as? UniMERNetServiceError {
            return serviceError
        }

        return UniMERNetServiceError.recognitionFailed(details: error.localizedDescription)
    }

    nonisolated private static func preferredStartupDevice(environment: [String: String]) -> WorkerDevice {
        switch environment["QUICKCALC_UNIMERNET_DEVICE"]?.lowercased() {
        case WorkerDevice.mps.rawValue:
            return .mps
        case WorkerDevice.cpu.rawValue:
            return .cpu
        default:
            // MPS currently fails reliably for this model on this machine.
            return .cpu
        }
    }

    private func locateBootstrapPython() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let candidatePaths = [
            environment["QUICKCALC_PYTHON311"],
            "/opt/homebrew/bin/python3.11",
            "/usr/local/bin/python3.11",
            "/Library/Frameworks/Python.framework/Versions/3.11/bin/python3.11",
            "/usr/bin/python3.11"
        ].compactMap { $0 }

        if let path = candidatePaths.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }

        throw UniMERNetServiceError.pythonMissing(nil)
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
}

private struct UniMERNetPaths {
    let projectRootURL: URL
    let appSupportURL: URL
    let logsURL: URL
    let bootstrapURL: URL
    let workerURL: URL
    let bootstrapLogURL: URL
    let workerLogURL: URL
    let stderrLogURL: URL
    let stdoutLogURL: URL

    nonisolated init() {
        let sourceFileURL = URL(fileURLWithPath: #filePath)
        let sourceRootURL = sourceFileURL.deletingLastPathComponent()
        let projectRootURL = sourceRootURL.deletingLastPathComponent()
        let applicationSupportBaseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

        let appSupportURL = applicationSupportBaseURL
            .appendingPathComponent("QuickCalc", isDirectory: true)
        let logsURL = appSupportURL.appendingPathComponent("logs", isDirectory: true)
        let supportURL = projectRootURL.appendingPathComponent("QuickCalcSupport", isDirectory: true)

        self.projectRootURL = projectRootURL
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
