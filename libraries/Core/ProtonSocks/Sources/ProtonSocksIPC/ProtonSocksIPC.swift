// Copyright (c) 2026 Proton AG

import Foundation

public enum ProtonSocksCommand: String, Codable, Sendable {
    case ping
    case start
    case update
    case stop
}

public struct ProtonSocksConfiguration: Codable, Equatable, Sendable {
    public let privateKey: String
    public let serverPublicKey: String
    public let tunnelAddress: String
    public let allowedIPs: String
    public let dnsServers: [String]
    public let endpointHost: String
    public let endpointPort: UInt16
    public let persistentKeepAlive: UInt16?
    public let listenAddress: String
    public let socketType: String
    public let mtu: UInt16?

    public init(
        privateKey: String,
        serverPublicKey: String,
        tunnelAddress: String,
        allowedIPs: String,
        dnsServers: [String],
        endpointHost: String,
        endpointPort: UInt16,
        persistentKeepAlive: UInt16?,
        listenAddress: String,
        socketType: String,
        mtu: UInt16? = nil
    ) {
        self.privateKey = privateKey
        self.serverPublicKey = serverPublicKey
        self.tunnelAddress = tunnelAddress
        self.allowedIPs = allowedIPs
        self.dnsServers = dnsServers
        self.endpointHost = endpointHost
        self.endpointPort = endpointPort
        self.persistentKeepAlive = persistentKeepAlive
        self.listenAddress = listenAddress
        self.socketType = socketType
        self.mtu = mtu
    }
}

public struct ProtonSocksRequest: Codable, Equatable, Sendable {
    public let id: UUID
    public let command: ProtonSocksCommand
    public let configuration: ProtonSocksConfiguration?

    public init(
        id: UUID = UUID(),
        command: ProtonSocksCommand,
        configuration: ProtonSocksConfiguration? = nil
    ) {
        self.id = id
        self.command = command
        self.configuration = configuration
    }
}

public struct ProtonSocksResponse: Codable, Equatable, Sendable {
    public let id: UUID
    public let success: Bool
    public let error: String?

    public init(id: UUID, success: Bool, error: String? = nil) {
        self.id = id
        self.success = success
        self.error = error
    }
}
