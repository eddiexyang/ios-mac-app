//
//  Created on 14/11/2023.
//
//  Copyright (c) 2023 Proton AG
//
//  ProtonVPN is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  ProtonVPN is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with ProtonVPN.  If not, see <https://www.gnu.org/licenses/>.

import Foundation

#if !os(macOS)
    import KeychainAccess
#endif

/// As you might see this is named `...Actor`, but in fact it's a class. This is due to a revert we did
/// of the async keychain changes that caused multiple fires in production. The class was left here as
/// an easy way of resuming the work in the future.
#if os(macOS)
    private final class Socks5JSONCredentialStore: @unchecked Sendable {
        private struct Contents: Codable {
            var services: [String: [String: Data]] = [:]
        }

        static let shared = Socks5JSONCredentialStore()

        private let lock = NSLock()
        private let directoryURL: URL
        private let fileURL: URL
        private var contents: Contents

        private init() {
            let applicationSupportURL = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
            let directoryURL = applicationSupportURL
                .appendingPathComponent("ProtonVPN-SOCKS5", isDirectory: true)
            let fileURL = directoryURL.appendingPathComponent("credentials.json")

            self.directoryURL = directoryURL
            self.fileURL = fileURL
            self.contents = if let data = try? Data(contentsOf: fileURL),
                               let storedContents = try? JSONDecoder().decode(Contents.self, from: data) {
                storedContents
            } else {
                Contents()
            }
        }

        func data(forKey key: String, service: String) -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return contents.services[service]?[key]
        }

        func set(_ value: Data, forKey key: String, service: String) throws {
            lock.lock()
            defer { lock.unlock() }

            let previousContents = contents
            contents.services[service, default: [:]][key] = value
            do {
                try persist()
            } catch {
                contents = previousContents
                throw error
            }
        }

        func remove(_ key: String, service: String) throws {
            lock.lock()
            defer { lock.unlock() }

            guard contents.services[service]?[key] != nil else { return }
            let previousContents = contents
            contents.services[service]?[key] = nil
            if contents.services[service]?.isEmpty == true {
                contents.services[service] = nil
            }
            do {
                try persist()
            } catch {
                contents = previousContents
                throw error
            }
        }

        func remove(_ keys: [String], service: String) throws {
            lock.lock()
            defer { lock.unlock() }

            guard var serviceContents = contents.services[service] else { return }
            let previousContents = contents
            for key in keys {
                serviceContents[key] = nil
            }
            contents.services[service] = serviceContents.isEmpty ? nil : serviceContents
            guard contents.services != previousContents.services else { return }
            do {
                try persist()
            } catch {
                contents = previousContents
                throw error
            }
        }

        private func persist() throws {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(contents).write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        }
    }

    public class KeychainActor {
        private let service: String

        public init(accessGroup _: String) {
            self.service = KeychainConstants.appKeychain
        }

        public init() {
            self.service = KeychainConstants.appKeychain
        }

        public init(service: String) {
            self.service = service
        }

        public func getData(_ key: String, ignoringAttributeSynchronizable _: Bool = true) throws -> Data? {
            Socks5JSONCredentialStore.shared.data(forKey: key, service: service)
        }

        public func set(_ value: Data, key: String, ignoringAttributeSynchronizable _: Bool = true) throws {
            try Socks5JSONCredentialStore.shared.set(value, forKey: key, service: service)
        }

        public func clear(contextValues: [String]) {
            try? Socks5JSONCredentialStore.shared.remove(contextValues, service: service)
        }

        public func remove(_ key: String, ignoringAttributeSynchronizable _: Bool = true) throws {
            try Socks5JSONCredentialStore.shared.remove(key, service: service)
        }
    }
#else
public class KeychainActor {
    private let keychain: KeychainAccess.Keychain

    public init(accessGroup: String) {
        self.keychain =
            .init(service: KeychainConstants.appKeychain, accessGroup: accessGroup)
                .accessibility(.afterFirstUnlockThisDeviceOnly)
    }

    public init() {
        self.keychain =
            .init(service: KeychainConstants.appKeychain)
                .accessibility(.afterFirstUnlockThisDeviceOnly)
    }

    public init(service: String) {
        self.keychain =
            .init(service: service)
                .accessibility(.afterFirstUnlockThisDeviceOnly)
    }

    public func getData(_ key: String, ignoringAttributeSynchronizable: Bool = true) throws -> Data? {
        try keychain.getData(key, ignoringAttributeSynchronizable: ignoringAttributeSynchronizable)
    }

    public func set(_ value: Data, key: String, ignoringAttributeSynchronizable: Bool = true) throws {
        try keychain.set(value, key: key, ignoringAttributeSynchronizable: ignoringAttributeSynchronizable)
    }

    public func clear(contextValues: [String]) {
        for storageKey in contextValues {
            keychain[data: storageKey] = nil
        }
    }

    public func remove(_ key: String, ignoringAttributeSynchronizable: Bool = true) throws {
        try keychain.remove(key, ignoringAttributeSynchronizable: ignoringAttributeSynchronizable)
    }
}
#endif
