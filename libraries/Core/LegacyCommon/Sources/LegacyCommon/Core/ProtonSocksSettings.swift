// Copyright (c) 2026 Proton AG

import Foundation

#if os(macOS)
public enum ProtonSocksSettings {
    public static let defaultListenPort: UInt16 = 10_808
    private static let listenPortKey = "ProtonSocksListenPort"

    public static var listenPort: UInt16 {
        get {
            let value = UserDefaults.standard.integer(forKey: listenPortKey)
            return UInt16(exactly: value) ?? defaultListenPort
        }
        set {
            UserDefaults.standard.set(Int(newValue), forKey: listenPortKey)
        }
    }

    public static var listenAddress: String {
        "127.0.0.1:\(listenPort)"
    }
}
#endif
