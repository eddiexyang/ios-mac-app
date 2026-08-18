//
//  Created on 31/03/2026 by Max Kupetskyi.
//
//  Copyright (c) 2026 Proton AG
//
//  Proton VPN is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Proton VPN is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Proton VPN.  If not, see <https://www.gnu.org/licenses/>.

#if os(macOS)
    import ComposableArchitecture
    @testable import Countries_macOS
    import CountriesShared
    import PaymentsShared
    import PersistenceTestSupport
    import Testing

    @Suite("Countries List Feature Tests mac")
    @MainActor
    struct CountriesListFeatureTests {
        @Test("dismiss clears all countries upsell destination")
        func dismissClearsAllCountriesUpsellDestination() async {
            var state = CountriesListFeature.State()
            state.destination = .allCountriesUpsell(
                .init(modalType: .allCountries(numberOfServers: 1, numberOfCountries: 1))
            )

            let store = TestStore(initialState: state) {
                CountriesListFeature()
            }

            await store.send(.destination(.dismiss)) {
                $0.destination = nil
            }
        }

        @Test("search text ignores duplicate values")
        func searchTextIgnoresDuplicateValues() async {
            var state = CountriesListFeature.State()
            state.searchText = "us"

            let store = TestStore(initialState: state) {
                CountriesListFeature()
            }

            await store.send(.searchText("us"))
        }

        @Test("free location groups are filtered to the free tier")
        func freeLocationGroupsAreFilteredToFreeTier() {
            let capturedFilters = LockIsolated<[[String]]>([])

            withDependencies {
                $0.serverRepository = .init(
                    serverCount: { 0 },
                    countryCount: { 0 },
                    upsertServers: { _ in },
                    deleteServers: { _, _ in 0 },
                    upsertLoads: { _ in },
                    groups: { filters, _, _ in
                        capturedFilters.withValue { $0.append(filters.map(\.description)) }
                        return []
                    },
                    servers: { _, _ in [] },
                    server: { _, _ in nil },
                    getMetadata: { _ in nil },
                    setMetadata: { _, _ in },
                    closeConnection: {}
                )
            } operation: {
                let feature = CountriesListFeature()
                _ = feature.groups(
                    with: .country,
                    search: "",
                    expandedCountryCode: nil,
                    secureCore: false,
                    freeOnly: true
                )
                _ = feature.groups(
                    with: .country,
                    search: "",
                    expandedCountryCode: nil,
                    secureCore: false,
                    freeOnly: false
                )
            }

            #expect(capturedFilters.value.count == 2)
            #expect(capturedFilters.value[0].contains("|maxTier=0"))
            #expect(!capturedFilters.value[1].contains("|maxTier=0"))
        }
    }
#endif
