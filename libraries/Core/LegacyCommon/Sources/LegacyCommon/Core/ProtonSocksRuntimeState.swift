// Copyright (c) 2026 Proton AG

#if os(macOS)
    import Foundation

    /// Process-local VPN state used by the macOS SOCKS5 transport.
    ///
    /// The regular app derives this state from `NEVPNManager`. The SOCKS5 build
    /// deliberately has no Network Extension, so its state must stay entirely
    /// inside the host process instead.
    final class ProtonSocksRuntimeState: @unchecked Sendable {
        static let shared = ProtonSocksRuntimeState()

        private let lock = NSLock()
        private var storedState: VpnState = .disconnected

        private init() {}

        var state: VpnState {
            get {
                lock.lock()
                defer { lock.unlock() }
                return storedState
            }
            set {
                lock.lock()
                storedState = newValue
                lock.unlock()
            }
        }
    }
#endif
