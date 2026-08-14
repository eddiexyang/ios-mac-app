// Copyright (c) 2026 Proton AG

import Foundation
import Network
import ProtonSocksIPC
import WireGuardKitGo

enum WireGuardSocksBackendError: LocalizedError {
    case invalidState
    case invalidPrivateKey
    case invalidServerPublicKey
    case invalidTunnelAddress
    case invalidAllowedIPs
    case invalidDNSServer
    case invalidEndpoint(String)
    case startWireGuardBackend(Int32)
    case setWireGuardConfig(Int64)

    var errorDescription: String? {
        switch self {
        case .invalidState:
            "The WireGuard SOCKS5 backend is in an invalid state"
        case .invalidPrivateKey:
            "Invalid WireGuard private key"
        case .invalidServerPublicKey:
            "Invalid WireGuard server public key"
        case .invalidTunnelAddress:
            "Invalid WireGuard tunnel address"
        case .invalidAllowedIPs:
            "Invalid WireGuard allowed IPs"
        case .invalidDNSServer:
            "Missing a classic IPv4 WireGuard DNS server"
        case let .invalidEndpoint(description):
            "Invalid WireGuard server endpoint: \(description)"
        case let .startWireGuardBackend(code):
            "Could not start the WireGuard SOCKS5 backend (\(code))"
        case let .setWireGuardConfig(code):
            "Could not update the WireGuard SOCKS5 backend (\(code))"
        }
    }
}

final class WireGuardSocksBackend {
    typealias LogHandler = (String, String) -> Void

    private struct Settings {
        let uapi: String
        let tunnelAddresses: String
        let dnsAddress: String
    }

    private let logHandler: LogHandler
    private let workQueue = DispatchQueue(label: "WireGuardSocksBackendWorkQueue")
    private let pathQueue = DispatchQueue(label: "WireGuardSocksBackendPathQueue")
    private var pathMonitor: NWPathMonitor?
    private var handle: Int32?

    init(logHandler: @escaping LogHandler) {
        self.logHandler = logHandler
        setupLogHandler()
    }

    deinit {
        pathMonitor?.cancel()
        if let handle {
            wgTurnOff(handle)
        }
        wgSetLogger(nil, nil)
    }

    func start(
        configuration: ProtonSocksConfiguration,
        completionHandler: @escaping (WireGuardSocksBackendError?) -> Void
    ) {
        workQueue.async {
            guard self.handle == nil else {
                completionHandler(.invalidState)
                return
            }

            do {
                let settings = try Self.makeSettings(configuration)
                let handle = wgTurnOnSocks(
                    settings.uapi,
                    configuration.listenAddress,
                    settings.tunnelAddresses,
                    settings.dnsAddress,
                    Int32(configuration.mtu ?? 1280),
                    configuration.socketType
                )
                guard handle >= 0 else {
                    completionHandler(.startWireGuardBackend(handle))
                    return
                }

                self.handle = handle
                wgSetNetworkAvailable(handle, 1)
                self.startPathMonitor()
                completionHandler(nil)
            } catch let error as WireGuardSocksBackendError {
                completionHandler(error)
            } catch {
                completionHandler(.invalidEndpoint(error.localizedDescription))
            }
        }
    }

    func update(
        configuration: ProtonSocksConfiguration,
        completionHandler: @escaping (WireGuardSocksBackendError?) -> Void
    ) {
        workQueue.async {
            guard let handle = self.handle else {
                completionHandler(.invalidState)
                return
            }

            do {
                let settings = try Self.makeSettings(configuration)
                let result = wgSetConfig(handle, settings.uapi)
                guard result == 0 else {
                    completionHandler(.setWireGuardConfig(result))
                    return
                }
                wgBumpSockets(handle)
                completionHandler(nil)
            } catch let error as WireGuardSocksBackendError {
                completionHandler(error)
            } catch {
                completionHandler(.invalidEndpoint(error.localizedDescription))
            }
        }
    }

    func stop(completionHandler: @escaping (WireGuardSocksBackendError?) -> Void) {
        workQueue.async {
            guard let handle = self.handle else {
                completionHandler(.invalidState)
                return
            }

            self.pathMonitor?.cancel()
            self.pathMonitor = nil
            self.handle = nil
            wgTurnOff(handle)
            completionHandler(nil)
        }
    }

    private static func makeSettings(_ configuration: ProtonSocksConfiguration) throws -> Settings {
        guard let privateKey = keyHex(configuration.privateKey) else {
            throw WireGuardSocksBackendError.invalidPrivateKey
        }
        guard let publicKey = keyHex(configuration.serverPublicKey) else {
            throw WireGuardSocksBackendError.invalidServerPublicKey
        }

        let tunnelAddresses = addressRanges(configuration.tunnelAddress)
        guard !tunnelAddresses.isEmpty, tunnelAddresses.allSatisfy(isValidIPRange) else {
            throw WireGuardSocksBackendError.invalidTunnelAddress
        }
        let allowedIPs = addressRanges(configuration.allowedIPs)
        guard !allowedIPs.isEmpty, allowedIPs.allSatisfy(isValidIPRange) else {
            throw WireGuardSocksBackendError.invalidAllowedIPs
        }
        guard let dnsAddress = configuration.dnsServers
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { IPv4Address($0) != nil }) else {
            throw WireGuardSocksBackendError.invalidDNSServer
        }

        let endpoint = try resolveEndpoint(
            host: configuration.endpointHost,
            port: configuration.endpointPort
        )

        var uapi = "private_key=\(privateKey)\n"
        uapi.append("replace_peers=true\n")
        uapi.append("public_key=\(publicKey)\n")
        uapi.append("endpoint=\(endpoint)\n")
        uapi.append("persistent_keepalive_interval=\(configuration.persistentKeepAlive ?? 0)\n")
        uapi.append("replace_allowed_ips=true\n")
        for allowedIP in allowedIPs {
            uapi.append("allowed_ip=\(allowedIP)\n")
        }

        return Settings(
            uapi: uapi,
            tunnelAddresses: tunnelAddresses.joined(separator: ","),
            dnsAddress: dnsAddress
        )
    }

    private static func keyHex(_ base64Key: String) -> String? {
        guard let key = Data(base64Encoded: base64Key), key.count == 32 else { return nil }

        let digits = Array("0123456789abcdef".utf8)
        var result = [UInt8]()
        result.reserveCapacity(key.count * 2)
        for byte in key {
            result.append(digits[Int(byte >> 4)])
            result.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: result, as: UTF8.self)
    }

    private static func addressRanges(_ value: String) -> [String] {
        value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func isValidIPRange(_ value: String) -> Bool {
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2,
              let prefixLength = UInt8(components[1]) else {
            return false
        }

        let address = String(components[0])
        if IPv4Address(address) != nil {
            return prefixLength <= 32
        }
        if IPv6Address(address) != nil {
            return prefixLength <= 128
        }
        return false
    }

    private static func resolveEndpoint(host: String, port: UInt16) throws -> String {
        var hostname = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if hostname.hasPrefix("["), hostname.hasSuffix("]") {
            hostname.removeFirst()
            hostname.removeLast()
        }
        guard !hostname.isEmpty else {
            throw WireGuardSocksBackendError.invalidEndpoint("empty hostname")
        }

        var hints = addrinfo()
        hints.ai_flags = AI_ALL
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_protocol = IPPROTO_UDP

        var resultPointer: UnsafeMutablePointer<addrinfo>?
        defer { resultPointer.flatMap { freeaddrinfo($0) } }

        let errorCode = getaddrinfo(hostname, String(port), &hints, &resultPointer)
        guard errorCode == 0 else {
            throw WireGuardSocksBackendError.invalidEndpoint(
                String(cString: gai_strerror(errorCode))
            )
        }

        var ipv6Endpoint: String?
        var current = resultPointer
        while let addressInfo = current?.pointee {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let nameError = getnameinfo(
                addressInfo.ai_addr,
                addressInfo.ai_addrlen,
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if nameError == 0 {
                let numericHost = String(cString: buffer)
                if addressInfo.ai_family == AF_INET {
                    return "\(numericHost):\(port)"
                }
                if addressInfo.ai_family == AF_INET6, ipv6Endpoint == nil {
                    ipv6Endpoint = "[\(numericHost)]:\(port)"
                }
            }
            current = addressInfo.ai_next
        }

        guard let ipv6Endpoint else {
            throw WireGuardSocksBackendError.invalidEndpoint("DNS returned no IP addresses")
        }
        return ipv6Endpoint
    }

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            self?.workQueue.async {
                guard let self, let handle = self.handle else { return }
                if path.status == .satisfied {
                    wgSetNetworkAvailable(handle, 1)
                    wgBumpSockets(handle)
                } else {
                    wgSetNetworkAvailable(handle, 0)
                }
            }
        }
        pathMonitor = monitor
        monitor.start(queue: pathQueue)
    }

    private func setupLogHandler() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        wgSetLogger(context) { context, logLevel, message in
            guard let context, let message else { return }
            let backend = Unmanaged<WireGuardSocksBackend>.fromOpaque(context).takeUnretainedValue()
            let level = logLevel == 1 ? "error" : "verbose"
            backend.logHandler(level, String(cString: message).trimmingCharacters(in: .newlines))
        }
    }
}
