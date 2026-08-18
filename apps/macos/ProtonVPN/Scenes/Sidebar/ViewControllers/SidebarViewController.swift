//
//  SidebarViewController.swift
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
import Combine
import ComposableArchitecture
import Dependencies

import Announcement
import Domain
import LegacyCommon
import Strings
import Theme
import VPNShared

final class SidebarViewController: NSViewController, NSWindowDelegate {
    private let allThings = NSView(frame: .zero)
    private let headerControllerViewContainer = NSView(frame: .zero)
    private let activeControllerViewContainer = NSView(frame: .zero)
    private let announcementsControllerViewContainer = NSView(frame: .zero)
    private let connectionOverlay = ConnectionOverlay(frame: .zero)
    private let sidebarContainerView = NSView(frame: .zero)
    private let mapSectionViewContainer = NSView(frame: .zero)
    private let expandButton = ExpandMapButton(frame: .zero)
    private var expandButtonLeading: NSLayoutConstraint!

    private var headerViewController: HeaderViewController!
    private var activeController: NSViewController!

    private var overlayViewController: ConnectingViewController?
    private var fadeOutOverlayTask: DispatchWorkItem?
    private var isAnimatingMapResize = false
    private var loading = false
    private var overlayViewModel: ConnectingOverlayViewModel?
    // Retain header view model to set `changeServerStateUpdated` when needed
    private var headerViewModel: HeaderViewModel?

    typealias Factory = AnnouncementsViewModelFactory
        & ConnectingOverlayViewModelFactory
        & CoreAlertServiceFactory
        & HeaderViewModelFactory
        & MapSectionViewModelFactory
        & VpnManagerFactory

    private let appStateManager: AppStateManager
    private let vpnGateway: VpnGatewayProtocol
    private let navService: NavigationService
    private let factory: Factory
    private let store: StoreOf<SidebarFeature>

    private lazy var countriesSectionViewController: CountriesSectionViewController = { [unowned self] in
        CountriesSectionViewController(
            store: store.scope(
                state: \.countriesSection,
                action: \.countriesSection
            )
        )
    }()

    private lazy var mapHeaderViewModel: MapHeaderViewModel = { [unowned self] in
        return MapHeaderViewModel(vpnGateway: vpnGateway, appStateManager: appStateManager)
    }()

    private lazy var mapSectionViewModel: MapSectionViewModel = factory.makeMapSectionViewModel()

    private lazy var announcementsViewModel: AnnouncementsViewModel = factory.makeAnnouncementsViewModel()
    private lazy var mapSectionViewController: MapSectionViewController = { [unowned self] in
        MapSectionViewController(
            mapSectionViewModel: mapSectionViewModel,
            mapHeaderViewModel: mapHeaderViewModel
        )
    }()

    // MARK: - Init

    init(
        appStateManager: AppStateManager,
        vpnGateway: VpnGatewayProtocol,
        navService: NavigationService,
        factory: Factory
    ) {
        let quickSettingsHandler = CountriesSectionQuickSettingsHandler(
            appStateManager: appStateManager,
            vpnGateway: vpnGateway,
            vpnManager: factory.makeVpnManager()
        )
        let store = Store(initialState: .init()) {
            SidebarFeature(
                quickSettingsEnvironment: .init(
                    performOptionSelection: { type, option, dismiss in
                        quickSettingsHandler.quickSettingsSelectOption(
                            type: type,
                            option: option,
                            dismiss: dismiss
                        )
                    },
                    initialNetShieldStats: {
                        quickSettingsHandler.quickSettingsInitialNetShieldStats
                    }
                ),
                environment: .init(
                    appStateChanged: {
                        AsyncStream { continuation in
                            let cancellable = appStateManager.appStateUpdates.sink { state in
                                continuation.yield(state)
                            }
                            continuation.onTermination = { _ in
                                cancellable.cancel()
                            }
                        }
                    },
                    sidebarWidth: Dimensions.sidebarWidth,
                    expandButtonWidth: Dimensions.expandButtonWidth,
                    defaultMapWidth: Dimensions.defaultMapContainerWidth
                )
            )
        }

        self.appStateManager = appStateManager
        self.vpnGateway = vpnGateway
        self.navService = navService
        self.factory = factory
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Unsupported initializer")
    }

    override func loadView() {
        let rootView = NSView(frame: NSRect(x: 0, y: 0, width: Dimensions.sidebarWidth, height: Dimensions.initialViewHeight))
        rootView.translatesAutoresizingMaskIntoConstraints = false
        view = rootView
        buildViewHierarchy(in: rootView)
        setupLayoutConstraints(in: rootView)
    }

    // MARK: Functions

    override func viewDidLoad() {
        super.viewDidLoad()

        setupMainView()
        setupHeader()
        setupActiveController()
        setupMapSection()

        store.send(.viewDidLoad)
        observe { [weak self] in
            guard let self else { return }
            applySidebarState()
            applyLoadingOverlayState()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        store.send(.viewDidAppear)
        view.window?.applySidebarAppearance()
        if let window = view.window {
            store.send(.windowDidResize(width: window.frame.width, height: window.frame.height))
        }

        if let overlayViewModel, !appStateManager.state.isConnected {
            showLoadingOverlay(with: overlayViewModel)
        } else {
            overlayViewModel = nil
        }
        vpnGateway.postConnectionInformation()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        applyExpandButtonLayoutDirection()
    }

    override func mouseDown(with _: NSEvent) {
        store.send(.mouseDown)
        view.window?.makeFirstResponder(nil)
    }

    // MARK: - Private

    private func showLoadingOverlay(with viewModel: ConnectingOverlayViewModel) {
        guard view.window != nil, overlayViewController == nil else { return }

        let connectingViewController = ConnectingViewController(viewModel: viewModel)
        overlayViewController = connectingViewController

        connectionOverlay.isHidden = false
        // Keep the connecting UI in the main window. Ordering a child window can
        // trip macOS 27's NSRemoteView consistency assertion.
        addChild(connectingViewController)
        connectingViewController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(connectingViewController.view, positioned: .above, relativeTo: connectionOverlay)
        NSLayoutConstraint.activate([
            connectingViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            connectingViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            connectingViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            connectingViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        store.send(.overlayWindowPresentedChanged(true))
    }

    private func loading(show: Bool, animateClose _: Bool = false) {
        guard let window = view.window else { return }

        loading = show

        if show {
            removeConnectingOverlay()
            let cancellation: (() -> Void) = { [weak self] in
                guard let self else {
                    return
                }

                store.send(.overlayDismissedByUser)
                removeConnectingOverlay()
            }

            overlayViewModel = factory.makeConnectingOverlayViewModel(cancellation: cancellation)

            if window.isVisible, NSApp.occlusionState.contains(.visible) {
                showLoadingOverlay(with: overlayViewModel!)
            }
        } else {
            switch appStateManager.state {
            case .connected:
                removeConnectingOverlay(animated: true)
            default:
                removeConnectingOverlay()
            }
        }
    }

    private func removeConnectingOverlay(animated: Bool = false) {
        overlayViewModel = nil

        guard let overlayViewController else { return }

        connectionOverlay.stopBlurAnimation()
        overlayViewController.stopAnimatingFade()
        guard self.overlayViewController === overlayViewController else { return }

        if animated {
            if !connectionOverlay.isHidden {
                connectionOverlay.removeBlur(over: Dimensions.overlayFadeDuration) { [weak self] in
                    self?.connectionOverlay.isHidden = true
                }
            }

            overlayViewController.fade(over: Dimensions.overlayFadeDuration) { [weak self, weak overlayViewController] in
                guard let self, let overlayViewController else { return }
                self.removeConnectingOverlayViewController(overlayViewController)
            }
        } else {
            connectionOverlay.isHidden = true
            removeConnectingOverlayViewController(overlayViewController)
        }
    }

    private func removeConnectingOverlayViewController(_ viewController: ConnectingViewController) {
        guard overlayViewController === viewController else { return }
        viewController.view.removeFromSuperview()
        viewController.removeFromParent()
        overlayViewController = nil
        store.send(.overlayWindowPresentedChanged(false))
    }

    private func buildViewHierarchy(in rootView: NSView) {
        for item in [allThings, connectionOverlay] {
            item.translatesAutoresizingMaskIntoConstraints = false
            rootView.addSubview(item)
        }

        for item in [sidebarContainerView, mapSectionViewContainer, expandButton] {
            item.translatesAutoresizingMaskIntoConstraints = false
            allThings.addSubview(item)
        }

        for item in [activeControllerViewContainer, headerControllerViewContainer, announcementsControllerViewContainer] {
            item.translatesAutoresizingMaskIntoConstraints = false
            sidebarContainerView.addSubview(item)
        }

        connectionOverlay.isHidden = true
    }

    private func setupLayoutConstraints(in rootView: NSView) {
        let announcementsPreferredWidth = announcementsControllerViewContainer.widthAnchor.constraint(equalToConstant: Dimensions.announcementsWidth)
        announcementsPreferredWidth.priority = .defaultLow
        let announcementsPreferredHeight = announcementsControllerViewContainer.heightAnchor.constraint(equalToConstant: Dimensions.announcementsHeight)
        announcementsPreferredHeight.priority = .defaultLow

        let headerPreferredHeight = headerControllerViewContainer.heightAnchor.constraint(equalToConstant: Dimensions.headerPreferredHeight)
        headerPreferredHeight.priority = .defaultLow

        expandButtonLeading = mapSectionViewContainer.leadingAnchor.constraint(equalTo: expandButton.trailingAnchor)

        NSLayoutConstraint.activate([
            allThings.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            allThings.topAnchor.constraint(equalTo: rootView.topAnchor),
            allThings.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            allThings.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            connectionOverlay.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            connectionOverlay.topAnchor.constraint(equalTo: rootView.topAnchor),
            connectionOverlay.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            connectionOverlay.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            sidebarContainerView.leadingAnchor.constraint(equalTo: allThings.leadingAnchor),
            sidebarContainerView.topAnchor.constraint(equalTo: allThings.topAnchor),
            sidebarContainerView.bottomAnchor.constraint(equalTo: allThings.bottomAnchor),
            sidebarContainerView.widthAnchor.constraint(equalToConstant: Dimensions.sidebarWidth),

            mapSectionViewContainer.topAnchor.constraint(equalTo: allThings.topAnchor),
            mapSectionViewContainer.trailingAnchor.constraint(equalTo: allThings.trailingAnchor),
            mapSectionViewContainer.bottomAnchor.constraint(equalTo: allThings.bottomAnchor),
            mapSectionViewContainer.leadingAnchor.constraint(equalTo: sidebarContainerView.trailingAnchor),

            expandButton.topAnchor.constraint(equalTo: allThings.topAnchor, constant: Dimensions.expandButtonTopOffset),
            expandButton.widthAnchor.constraint(equalToConstant: Dimensions.expandButtonWidth),
            expandButton.heightAnchor.constraint(equalToConstant: Dimensions.expandButtonHeight),
            expandButtonLeading,

            headerControllerViewContainer.leadingAnchor.constraint(equalTo: sidebarContainerView.leadingAnchor),
            headerControllerViewContainer.topAnchor.constraint(equalTo: sidebarContainerView.topAnchor),
            headerControllerViewContainer.trailingAnchor.constraint(equalTo: sidebarContainerView.trailingAnchor),
            headerPreferredHeight,

            activeControllerViewContainer.topAnchor.constraint(equalTo: headerControllerViewContainer.bottomAnchor),
            activeControllerViewContainer.leadingAnchor.constraint(equalTo: sidebarContainerView.leadingAnchor),
            activeControllerViewContainer.trailingAnchor.constraint(equalTo: sidebarContainerView.trailingAnchor),
            activeControllerViewContainer.bottomAnchor.constraint(equalTo: sidebarContainerView.bottomAnchor),

            announcementsControllerViewContainer.topAnchor.constraint(equalTo: sidebarContainerView.topAnchor, constant: Dimensions.announcementsTopOffset),
            announcementsControllerViewContainer.trailingAnchor.constraint(equalTo: sidebarContainerView.trailingAnchor, constant: Dimensions.announcementsTrailingOffset),
            announcementsPreferredWidth,
            announcementsPreferredHeight,
            announcementsControllerViewContainer.widthAnchor.constraint(lessThanOrEqualToConstant: Dimensions.announcementsWidth),
            announcementsControllerViewContainer.heightAnchor.constraint(lessThanOrEqualToConstant: Dimensions.announcementsHeight),
        ])
    }

    private func setupMainView() {
        view.wantsLayer = true
    }

    private func setupHeader() {
        headerViewModel = factory.makeHeaderViewModel()
        headerViewController = HeaderViewController(viewModel: headerViewModel!)
        headerViewController.announcementsButtonPressed = { [weak self] in
            self?.announcementsViewModel.open()
        }
        headerControllerViewContainer.pin(viewController: headerViewController)

        expandButton.target = self
        expandButton.action = #selector(expandButtonAction(_:))
        expandButton.expandState = .expanded
        applyExpandButtonLayoutDirection()
    }

    private func setupActiveController() {
        activeController = countriesSectionViewController
        activeControllerViewContainer.pin(viewController: activeController)
    }

    private func setupMapSection() {
        mapSectionViewContainer.pin(viewController: mapSectionViewController)
    }

    @objc
    private func expandButtonAction(_: NSButton) {
        store.send(.expandButtonTapped)
        applySidebarState()

        let mapContainerWidth = store.mapWidth > Dimensions.expandButtonWidth
            ? store.mapWidth
            : Dimensions.defaultMapContainerWidth

        let targetWidth: CGFloat = if store.expandState == .expanded {
            Dimensions.sidebarWidth + mapContainerWidth
        } else {
            Dimensions.sidebarWidth
        }
        animateMapResize(targetWidth: targetWidth)
    }

    private func animateMapResize(targetWidth: CGFloat) {
        guard var frame = view.window?.frame else { return }
        isAnimatingMapResize = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Dimensions.animationDuration
            frame.size.width = targetWidth
            self.view.window?.animator().setFrame(frame, display: true)
        }, completionHandler: { [weak self] in
            guard let self else { return }
            isAnimatingMapResize = false
            applySidebarState()
        })
    }

    private func applyExpandState(_ state: SidebarFeature.State.ExpandState) {
        guard !isAnimatingMapResize else { return }
        expandButton.isHidden = store.isExpandButtonHidden
        switch state {
        case .compact:
            expandButton.expandState = .compact
            expandButtonLeading.constant = 0.0
            expandButton.setAccessibilityLabel(Localizable.mapShow)
        case .expanded:
            expandButton.expandState = .expanded
            expandButtonLeading.constant = -Dimensions.expandButtonWidth
            expandButton.setAccessibilityLabel(Localizable.mapHide)
        }
    }

    private func applyExpandButtonLayoutDirection() {
        switch view.userInterfaceLayoutDirection {
        case .leftToRight:
            expandButton.transform = NSAffineTransform()
        case .rightToLeft:
            let transform = NSAffineTransform()
            transform.translateX(by: Dimensions.expandButtonWidth, yBy: 0)
            transform.scaleX(by: -1, yBy: 1)
            expandButton.transform = transform
        @unknown default:
            expandButton.transform = NSAffineTransform()
        }
        expandButton.needsDisplay = true
    }

    private func applySidebarState() {
        applyExpandState(store.expandState)
    }

    private func applyLoadingOverlayState() {
        // Keep the overlay detached when the app is occluded. This preserves the old
        // CoreImage workaround and avoids main-thread stalls on sleep/user switch.
        if store.shouldPresentLoadingOverlay {
            fadeOutOverlayTask?.cancel()
            if !store.isOverlayWindowPresented {
                loading(show: true)
            }
        } else {
            if store.isOverlayWindowPresented {
                loading(show: false)
            }
        }
    }
}

extension SidebarViewController {
    private enum Dimensions {
        static let sidebarWidth = UIConstants.Windows.sidebarWidth
        static let expandButtonWidth: CGFloat = 28
        static let expandButtonHeight: CGFloat = 26
        static let expandButtonTopOffset: CGFloat = 20
        static let initialViewHeight: CGFloat = 600
        static let defaultMapContainerWidth: CGFloat = 600
        static let announcementsWidth: CGFloat = 300
        static let announcementsHeight: CGFloat = 200
        static let announcementsTopOffset: CGFloat = 45
        static let announcementsTrailingOffset: CGFloat = -20
        static let headerPreferredHeight: CGFloat = 200

        static let animationDuration: CGFloat = 0.4
        static let overlayFadeDuration: CGFloat = 0.5
    }
}
