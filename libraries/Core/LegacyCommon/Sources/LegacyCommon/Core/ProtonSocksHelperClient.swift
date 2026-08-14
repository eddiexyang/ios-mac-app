// Copyright (c) 2026 Proton AG

#if os(macOS)
import Foundation
import ProtonSocksIPC

enum ProtonSocksHelperClientError: LocalizedError {
    case helperNotFound(String)
    case launchFailed(String)
    case writeFailed(String)
    case helperExited(Int32)
    case invalidResponse(String)
    case requestTimedOut(ProtonSocksCommand)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case let .helperNotFound(path):
            "The SOCKS5 helper is missing or is not executable at \(path)"
        case let .launchFailed(description):
            "Could not launch the SOCKS5 helper: \(description)"
        case let .writeFailed(description):
            "Could not send a command to the SOCKS5 helper: \(description)"
        case let .helperExited(status):
            "The SOCKS5 helper exited with status \(status)"
        case let .invalidResponse(description):
            "The SOCKS5 helper returned an invalid response: \(description)"
        case let .requestTimedOut(command):
            "The SOCKS5 helper timed out while handling \(command.rawValue)"
        case let .commandFailed(description):
            description
        }
    }
}

final class ProtonSocksHelperClient {
    typealias Completion = (Error?) -> Void

    private struct PendingRequest {
        let command: ProtonSocksCommand
        let completion: Completion
    }

    private let queue = DispatchQueue(label: "ch.protonvpn.socks-helper-client")
    private let requestTimeout: TimeInterval
    private let helperURL: URL
    private let logHandler: (String) -> Void
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var outputBuffer = Data()
    private var errorBuffer = Data()
    private var pendingRequests: [UUID: PendingRequest] = [:]

    init(
        helperURL: URL = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("ProtonSocksHelper", isDirectory: false),
        requestTimeout: TimeInterval = 30,
        logHandler: @escaping (String) -> Void
    ) {
        self.helperURL = helperURL
        self.requestTimeout = requestTimeout
        self.logHandler = logHandler
    }

    deinit {
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        inputHandle?.closeFile()
        if process?.isRunning == true {
            process?.terminate()
        }
    }

    func start(configuration: ProtonSocksConfiguration, completion: @escaping Completion) {
        send(command: .start, configuration: configuration, completion: completion)
    }

    func update(configuration: ProtonSocksConfiguration, completion: @escaping Completion) {
        send(command: .update, configuration: configuration, completion: completion)
    }

    func stop(completion: @escaping Completion) {
        send(command: .stop, configuration: nil, completion: completion)
    }

    private func send(
        command: ProtonSocksCommand,
        configuration: ProtonSocksConfiguration?,
        completion: @escaping Completion
    ) {
        queue.async {
            do {
                let inputHandle = try self.ensureHelperIsRunning()
                let request = ProtonSocksRequest(command: command, configuration: configuration)
                var data = try self.encoder.encode(request)
                data.append(0x0A)

                self.pendingRequests[request.id] = PendingRequest(
                    command: command,
                    completion: completion
                )

                do {
                    try inputHandle.write(contentsOf: data)
                } catch {
                    let clientError = ProtonSocksHelperClientError.writeFailed(error.localizedDescription)
                    self.failAllRequests(with: clientError)
                    self.stopHelperProcess()
                    return
                }

                self.queue.asyncAfter(deadline: .now() + self.requestTimeout) {
                    self.handleTimeout(for: request.id)
                }
            } catch {
                completion(error)
            }
        }
    }

    private func ensureHelperIsRunning() throws -> FileHandle {
        if process?.isRunning == true, let inputHandle {
            return inputHandle
        }

        if let process {
            let error = ProtonSocksHelperClientError.helperExited(process.terminationStatus)
            clearProcessState()
            failAllRequests(with: error)
        } else {
            clearProcessState()
        }

        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw ProtonSocksHelperClientError.helperNotFound(helperURL.path)
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = helperURL
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let outputHandle = outputPipe.fileHandleForReading
        outputHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.queue.async {
                self?.consumeOutput(data)
            }
        }

        let errorHandle = errorPipe.fileHandleForReading
        errorHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.queue.async {
                self?.consumeErrorOutput(data)
            }
        }

        process.terminationHandler = { [weak self] process in
            self?.queue.async {
                self?.helperDidExit(process)
            }
        }

        self.process = process
        inputHandle = inputPipe.fileHandleForWriting
        self.outputHandle = outputHandle
        self.errorHandle = errorHandle

        do {
            try process.run()
        } catch {
            clearProcessState()
            throw ProtonSocksHelperClientError.launchFailed(error.localizedDescription)
        }

        guard let inputHandle else {
            clearProcessState()
            throw ProtonSocksHelperClientError.launchFailed("stdin pipe is unavailable")
        }
        return inputHandle
    }

    private func consumeOutput(_ data: Data) {
        outputBuffer.append(data)
        let lines = Self.extractLines(from: &outputBuffer)
        for line in lines {
            do {
                let response = try decoder.decode(ProtonSocksResponse.self, from: line)
                guard let pendingRequest = pendingRequests.removeValue(forKey: response.id) else {
                    logHandler("SOCKS5 helper returned a response for an unknown request")
                    continue
                }

                if response.success {
                    pendingRequest.completion(nil)
                } else {
                    pendingRequest.completion(
                        ProtonSocksHelperClientError.commandFailed(
                            response.error ?? "The SOCKS5 helper command failed"
                        )
                    )
                }
            } catch {
                let clientError = ProtonSocksHelperClientError.invalidResponse(error.localizedDescription)
                failAllRequests(with: clientError)
                stopHelperProcess()
                return
            }
        }
    }

    private func consumeErrorOutput(_ data: Data) {
        errorBuffer.append(data)
        let lines = Self.extractLines(from: &errorBuffer)
        for line in lines {
            guard let message = String(data: line, encoding: .utf8) else { continue }
            logHandler(message)
        }
    }

    private static func extractLines(from buffer: inout Data) -> [Data] {
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if !line.isEmpty {
                lines.append(line)
            }
        }
        return lines
    }

    private func handleTimeout(for requestID: UUID) {
        guard let request = pendingRequests[requestID] else { return }
        failAllRequests(with: ProtonSocksHelperClientError.requestTimedOut(request.command))
        stopHelperProcess()
    }

    private func helperDidExit(_ exitedProcess: Process) {
        guard process === exitedProcess else { return }

        if !errorBuffer.isEmpty, let message = String(data: errorBuffer, encoding: .utf8) {
            logHandler(message)
        }
        errorBuffer.removeAll(keepingCapacity: false)
        outputBuffer.removeAll(keepingCapacity: false)

        let error = ProtonSocksHelperClientError.helperExited(exitedProcess.terminationStatus)
        clearProcessState()
        failAllRequests(with: error)
    }

    private func stopHelperProcess() {
        inputHandle?.closeFile()
        if process?.isRunning == true {
            process?.terminate()
        } else {
            clearProcessState()
        }
    }

    private func clearProcessState() {
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        inputHandle?.closeFile()
        process?.terminationHandler = nil
        process = nil
        inputHandle = nil
        outputHandle = nil
        errorHandle = nil
        outputBuffer.removeAll(keepingCapacity: true)
        errorBuffer.removeAll(keepingCapacity: true)
    }

    private func failAllRequests(with error: Error) {
        let requests = Array(pendingRequests.values)
        pendingRequests.removeAll(keepingCapacity: true)
        for request in requests {
            request.completion(error)
        }
    }
}
#endif
