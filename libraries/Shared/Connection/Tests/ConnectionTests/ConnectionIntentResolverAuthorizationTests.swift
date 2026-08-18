//
//  Created on 2026-08-18.
//
//  Copyright (c) 2026 Proton AG
//
//  Proton VPN is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//

#if DEBUG
    import Dependencies
    import Domain
    import DomainTestSupport
    import XCTest

    @testable import Connection

    final class ConnectionIntentResolverAuthorizationTests: XCTestCase {
        func testFreeUserCanChooseLocationsThatResolveToFreeServers() throws {
            let locations: [ConnectionSpec.Location] = [
                .country(code: "US", order: .fastest),
                .city(name: "New York", code: "US", order: .fastest),
                .state(name: "New York", code: "US", order: .fastest),
                .exact(.free, logicalID: "free-server", number: 1, subregion: "New York", regionCode: "US"),
            ]

            for location in locations {
                let intent = ConnectionPreparationIntent(
                    spec: .init(location: location, features: []),
                    acceptableProtocols: .wireGuardUDP
                )

                try withDependencies {
                    $0.serverSelector = .init { _, _, _ in .ca }
                } operation: {
                    try ConnectionIntentResolver.liveValue.authorize(intent, .freeTier)
                }
            }
        }

        func testFreeUserStillGetsUpsellWhenLocationHasNoFreeServers() {
            let location = ConnectionSpec.Location.country(code: "HK", order: .fastest)
            let intent = ConnectionPreparationIntent(
                spec: .init(location: location, features: []),
                acceptableProtocols: .wireGuardUDP
            )

            XCTAssertThrowsError(
                try withDependencies {
                    $0.serverSelector = .init { _, _, _ throws(ServerSelector.SelectionError) in
                        throw .noLogical(.locationNotFound(location))
                    }
                } operation: {
                    try ConnectionIntentResolver.liveValue.authorize(intent, .freeTier)
                }
            ) { error in
                XCTAssertEqual(
                    error as? ConnectionIntentResolutionError,
                    .specificCountryUnavailable(countryCode: "HK")
                )
            }
        }
    }
#endif
