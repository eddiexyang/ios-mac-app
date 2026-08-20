//
//  Created on 2022-02-23.
//
//  Copyright (c) 2022 Proton AG
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

import AppKit
import Dependencies
import Domain
import Foundation
import LegacyCommon
import Network
import VPNShared

protocol AppCertificateRefreshManagerFactory {
    func makeAppCertificateRefreshManager() -> AppCertificateRefreshManager
}

protocol AppCertificateRefreshManager {
    func planNextRefresh() async
    func startObservingEvents()
}

final class AppCertificateRefreshManagerImplementation: AppCertificateRefreshManager {
    typealias Factory = AppSessionManagerFactory

    final class TimerToken {
        private var cancellation: (() -> Void)?

        init(cancellation: @escaping () -> Void) {
            self.cancellation = cancellation
        }

        func cancel() {
            cancellation?()
            cancellation = nil
        }

        deinit {
            cancel()
        }
    }

    struct Environment {
        var notificationCenter: NotificationCenter
        var workspaceNotificationCenter: NotificationCenter
        var retryDelay: (ClosedRange<TimeInterval>) -> TimeInterval
        var scheduleTimer: (Date, @escaping () -> Void) -> TimerToken

        static var live: Self {
            .init(
                notificationCenter: .default,
                workspaceNotificationCenter: NSWorkspace.shared.notificationCenter,
                retryDelay: { TimeInterval.random(in: $0) },
                scheduleTimer: { nextRunTime, action in
                    let timer = Timer(
                        timeInterval: max(0, nextRunTime.timeIntervalSinceNow),
                        repeats: false
                    ) { _ in
                        action()
                    }
                    RunLoop.main.add(timer, forMode: .common)
                    return TimerToken(cancellation: { timer.invalidate() })
                }
            )
        }
    }

    private enum RefreshTrigger: String, Equatable, Sendable {
        case applicationBecameActive
        case networkRestored
        case systemClockChanged
        case systemWake
    }

    private enum Constants {
        static let initialRetryInterval: TimeInterval = 10
        static let maximumRetryInterval: TimeInterval = 15 * 60
        static let minimumRetryJitterFactor = 0.8
        static let refreshSchedulingLeeway: TimeInterval = 1
    }

    /// Exponential retry base before bounded jitter is applied by `nextRetryBackoff()`.
    private var lastRetryInterval = Constants.initialRetryInterval

    private let factory: Factory
    private let environment: Environment
    private lazy var appSessionManager: AppSessionManager = factory.makeAppSessionManager()
    private var timer: TimerToken?
    private var eventsTask: Task<Void, Never>?
    private var notificationObservers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var retryNotBefore: Date?

    private(set) var scheduledRefreshTime: Date?

    @Dependency(\.vpnAuthenticationStorage) var vpnAuthenticationStorage
    @Dependency(\.date) var date

    // MARK: - Init

    init(factory: Factory, environment: Environment = .live) {
        self.factory = factory
        self.environment = environment
    }

    func startObservingEvents() {
        guard eventsTask == nil else { return }

        let events = vpnAuthenticationStorage.events
        eventsTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                await self.handleEvent(event)
            }
        }

        observeExternalRefreshTriggers()
    }

    @MainActor
    private func handleEvent(_ event: VpnAuthenticationStorageEvent) async {
        switch event {
        case .certificateDeleted:
            certificateDeleted()
        case let .certificateStored(certificate):
            await certificateStored(certificate)
        }
    }

    deinit {
        eventsTask?.cancel()
        timer?.cancel()
        for observer in notificationObservers {
            observer.center.removeObserver(observer.token)
        }
    }

    @MainActor
    func planNextRefresh() async {
        guard appSessionManager.loggedIn else {
            log.debug("Skipping certificate refresh scheduling without an active session", category: .userCert)
            resetRetryBackoff()
            stopTimer()
            return
        }

        let now = date.now
        if let retryNotBefore, retryNotBefore > now {
            startTimer(at: retryNotBefore)
            return
        }

        guard let certificate = vpnAuthenticationStorage.getStoredCertificate() else {
            log.info("No current certificate, will try to generate new certificate right now.", category: .userCert)
            await refreshCertificate()
            return
        }

        var nextRefreshTime = certificate.refreshTime.addingTimeInterval(Constants.refreshSchedulingLeeway)

        if nextRefreshTime <= now {
            log.info("Current certificate should've been refreshed at \(nextRefreshTime). Starting refresh right now.", category: .userCert)
            nextRefreshTime = now
        }

        startTimer(at: nextRefreshTime)
    }

    @MainActor
    private func refreshCertificate() async {
        guard appSessionManager.loggedIn else {
            resetRetryBackoff()
            stopTimer()
            return
        }

        do {
            try await appSessionManager.refreshVpnAuthCertificate()
            guard appSessionManager.loggedIn else {
                resetRetryBackoff()
                stopTimer()
                return
            }
            resetRetryBackoff()
            // The timer can fire marginally before the certificate's refresh time. In that case the
            // refresh operation reuses the existing certificate and no `certificateStored` event is
            // emitted, so explicitly plan the next attempt after every successful operation.
            await planNextRefresh()
        } catch {
            guard appSessionManager.loggedIn else {
                resetRetryBackoff()
                stopTimer()
                return
            }
            let delay = nextRetryBackoff()
            log.error("Failed to refresh certificate through API: \(error). Will retry in \(delay) seconds.", category: .userCert)
            let retryTime = date.now.addingTimeInterval(delay)
            retryNotBefore = retryTime
            startTimer(at: retryTime)
        }
    }

    func nextRetryBackoff() -> TimeInterval {
        lastRetryInterval = min(lastRetryInterval * 2, Constants.maximumRetryInterval)
        let minimumDelay = lastRetryInterval * Constants.minimumRetryJitterFactor
        return environment.retryDelay(minimumDelay ... lastRetryInterval)
    }

    private func resetRetryBackoff() {
        lastRetryInterval = Constants.initialRetryInterval
        retryNotBefore = nil
    }

    private func startTimer(at nextRunTime: Date) {
        stopTimer()
        scheduledRefreshTime = nextRunTime
        timer = environment.scheduleTimer(nextRunTime) { [weak self] in
            Task { @MainActor [weak self] in
                await self?.refreshCertificate()
            }
        }
        log.info("Timer setup for \(nextRunTime)", category: .userCert)
    }

    private func stopTimer() {
        if timer != nil {
            timer?.cancel()
            log.info("Certificate refresh timer invalidated", category: .userCert)
        }
        timer = nil
        scheduledRefreshTime = nil
    }

    private func observeExternalRefreshTriggers() {
        observe(
            center: environment.notificationCenter,
            name: NSApplication.didBecomeActiveNotification,
            trigger: .applicationBecameActive
        )
        observe(
            center: environment.notificationCenter,
            name: Notification.Name("NSSystemClockDidChangeNotification"),
            trigger: .systemClockChanged
        )
        observe(
            center: environment.workspaceNotificationCenter,
            name: NSWorkspace.didWakeNotification,
            trigger: .systemWake
        )
        observe(
            center: environment.notificationCenter,
            name: AppEvent.reachabilityChanged.name,
            trigger: .networkRestored,
            shouldHandle: { notification in
                (notification.object as? NWPath)?.status == .satisfied
            }
        )
    }

    private func observe(
        center: NotificationCenter,
        name: Notification.Name,
        trigger: RefreshTrigger,
        shouldHandle: @escaping @Sendable (Notification) -> Bool = { _ in true }
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
            guard shouldHandle(notification) else { return }
            Task { @MainActor [weak self] in
                await self?.handleRefreshTrigger(trigger)
            }
        }
        notificationObservers.append((center, token))
    }

    @MainActor
    private func handleRefreshTrigger(_ trigger: RefreshTrigger) async {
        log.info("Rechecking certificate refresh schedule after \(trigger.rawValue)", category: .userCert)
        if trigger == .networkRestored {
            retryNotBefore = nil
        }
        await planNextRefresh()
    }
}

// MARK: - Event handlers

extension AppCertificateRefreshManagerImplementation {
    private func certificateDeleted() {
        resetRetryBackoff()
        stopTimer()
    }

    private func certificateStored(_: VpnCertificate) async {
        resetRetryBackoff()
        await planNextRefresh()
    }
}
