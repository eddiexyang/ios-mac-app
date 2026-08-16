//
//  SidebarWindowController.swift
//  ProtonVPN - Created on 27.06.19.
//
//  Copyright (c) 2019 Proton Technologies AG
//
//  This file is part of ProtonVPN.
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
//

import Cocoa
import Theme

class SidebarWindowController: WindowController {
    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Unsupported initializer")
    }

    required init(viewController: SidebarViewController) {
        let window = NSWindow()
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentViewController = viewController
        super.init(window: window)

        windowFrameAutosaveName = NSWindow.FrameAutosaveName("Main Window")

        setupWindow()
        setupControls()
    }

    private func setupWindow() {
        guard let window else {
            return
        }

        window.titlebarAppearsTransparent = true
        window.title = "Proton VPN"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .color(.background, .weak)
        window.styleMask.insert(.resizable)
        window.styleMask.insert(.closable)
        window.styleMask.insert(.miniaturizable)

        if window.contentLayoutRect.width <= Dimensions.maximumCompactWidth {
            let expandedWidth = Dimensions.defaultExpandedWidth
            let expandedHeight = max(window.contentLayoutRect.height, Dimensions.defaultHeight)
            let expandedX = window.frame.origin.x - (expandedWidth - window.frame.size.width) / 2
            window.setFrameOrigin(CGPoint(x: expandedX, y: window.frame.origin.y))
            window.setContentSize(CGSize(width: expandedWidth, height: expandedHeight))
        }
    }

    private func setupControls() {
        monitorsKeyEvents = true
    }

    private enum Dimensions {
        static let maximumCompactWidth = UIConstants.Windows.sidebarWidth + 1
        static let defaultExpandedWidth: CGFloat = 1200
        static let defaultHeight: CGFloat = 600
    }
}
