// Copyright (c) 2026 Proton AG

import Foundation
import ProtonSocksIPC

private enum ProtonSocksHelperError: LocalizedError {
    case missingConfiguration

    var errorDescription: String? {
        switch self {
        case .missingConfiguration: "The command requires a WireGuard configuration"
        }
    }
}

private final class ProtonSocksHelperServer {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private var isStarted = false

    private lazy var adapter = WireGuardSocksBackend { level, message in
        self.writeLog("[WireGuard \(level)] \(message)")
    }

    func run() {
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8) else {
                writeLog("Ignored a non-UTF-8 IPC request")
                continue
            }

            do {
                let request = try decoder.decode(ProtonSocksRequest.self, from: data)
                writeResponse(handle(request))
            } catch {
                writeLog("Ignored an invalid IPC request: \(error.localizedDescription)")
            }
        }

        if isStarted {
            _ = waitForAdapterOperation { completion in
                adapter.stop(completionHandler: completion)
            }
        }
    }

    private func handle(_ request: ProtonSocksRequest) -> ProtonSocksResponse {
        do {
            switch request.command {
            case .ping:
                break

            case .start:
                guard let configuration = request.configuration else {
                    throw ProtonSocksHelperError.missingConfiguration
                }
                if let error = waitForAdapterOperation({ completion in
                    adapter.start(
                        configuration: configuration,
                        completionHandler: completion
                    )
                }) {
                    throw error
                }
                isStarted = true

            case .update:
                guard let configuration = request.configuration else {
                    throw ProtonSocksHelperError.missingConfiguration
                }
                if let error = waitForAdapterOperation({ completion in
                    adapter.update(
                        configuration: configuration,
                        completionHandler: completion
                    )
                }) {
                    throw error
                }

            case .stop:
                if isStarted {
                    if let error = waitForAdapterOperation({ completion in
                        adapter.stop(completionHandler: completion)
                    }) {
                        throw error
                    }
                    isStarted = false
                }
            }

            return ProtonSocksResponse(id: request.id, success: true)
        } catch {
            return ProtonSocksResponse(
                id: request.id,
                success: false,
                error: error.localizedDescription
            )
        }
    }

    private func waitForAdapterOperation(
        _ operation: (@escaping (WireGuardSocksBackendError?) -> Void) -> Void
    ) -> WireGuardSocksBackendError? {
        let semaphore = DispatchSemaphore(value: 0)
        var operationError: WireGuardSocksBackendError?
        operation { error in
            operationError = error
            semaphore.signal()
        }
        semaphore.wait()
        return operationError
    }

    private func writeResponse(_ response: ProtonSocksResponse) {
        do {
            var data = try encoder.encode(response)
            data.append(0x0A)
            try FileHandle.standardOutput.write(contentsOf: data)
        } catch {
            writeLog("Could not write an IPC response: \(error.localizedDescription)")
        }
    }

    private func writeLog(_ message: String) {
        guard let data = "\(message)\n".data(using: .utf8) else { return }
        try? FileHandle.standardError.write(contentsOf: data)
    }
}

ProtonSocksHelperServer().run()
