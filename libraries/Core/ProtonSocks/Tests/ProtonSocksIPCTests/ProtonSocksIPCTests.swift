// Copyright (c) 2026 Proton AG

import Foundation
import XCTest
@testable import ProtonSocksIPC

final class ProtonSocksIPCTests: XCTestCase {
    func testRequestRoundTrip() throws {
        let configuration = ProtonSocksConfiguration(
            privateKey: "private-key",
            serverPublicKey: "public-key",
            tunnelAddress: "10.2.0.2/32",
            allowedIPs: "0.0.0.0/0",
            dnsServers: ["10.2.0.1"],
            endpointHost: "vpn.example.com",
            endpointPort: 51820,
            persistentKeepAlive: 25,
            listenAddress: "127.0.0.1:10808",
            socketType: "udp"
        )
        let requestID = try XCTUnwrap(UUID(uuidString: "01A000AF-6F71-7FC3-9AF2-C5416122C122"))
        let request = ProtonSocksRequest(
            id: requestID,
            command: .start,
            configuration: configuration
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ProtonSocksRequest.self, from: data)

        XCTAssertEqual(decoded, request)
    }

    func testFailureResponseRoundTrip() throws {
        let requestID = try XCTUnwrap(UUID(uuidString: "01A000AF-6F71-7FC3-9AF2-C5416122C122"))
        let response = ProtonSocksResponse(
            id: requestID,
            success: false,
            error: "invalid configuration"
        )

        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(ProtonSocksResponse.self, from: data)

        XCTAssertEqual(decoded, response)
    }
}
