//
//  AppCertificateRefreshManagerTests.swift
//  ProtonVPNTests
//
//  Copyright (c) 2026 Proton AG
//
//  This file is part of Proton VPN.
//

import AppKit
import CommonNetworking
import Dependencies
import Foundation
@testable import ProtonVPN
import VPNShared
import XCTest

final class AppCertificateRefreshManagerTests: XCTestCase {
    @MainActor
    func testPlansRefreshAfterServerRefreshTimeWithSafetyLeeway() async {
        let now = Date(timeIntervalSince1970: 1_000)
        let refreshTime = now.addingTimeInterval(60)
        let timerRecorder = TimerRecorder()
        let manager = makeManager(
            now: now,
            certificate: certificate(refreshTime: refreshTime),
            timerRecorder: timerRecorder
        )

        await manager.planNextRefresh()

        XCTAssertEqual(timerRecorder.scheduledDates, [refreshTime.addingTimeInterval(1)])
        XCTAssertEqual(manager.scheduledRefreshTime, refreshTime.addingTimeInterval(1))
    }

    func testRetryBackoffIsCappedAtFifteenMinutes() {
        let timerRecorder = TimerRecorder()
        let manager = makeManager(
            now: Date(timeIntervalSince1970: 1_000),
            certificate: nil,
            timerRecorder: timerRecorder
        )

        let delays = (0 ..< 12).map { _ in manager.nextRetryBackoff() }

        XCTAssertEqual(Array(delays.prefix(6)), [20, 40, 80, 160, 320, 640])
        XCTAssertTrue(delays.allSatisfy { $0 <= 15 * 60 })
        XCTAssertEqual(Array(delays.suffix(4)), [15 * 60, 15 * 60, 15 * 60, 15 * 60])
    }

    @MainActor
    func testApplicationActivationRechecksSchedule() async {
        let now = Date(timeIntervalSince1970: 1_000)
        let refreshTime = now.addingTimeInterval(60)
        let timerRecorder = TimerRecorder()
        let notificationCenter = NotificationCenter()
        let manager = makeManager(
            now: now,
            certificate: certificate(refreshTime: refreshTime),
            timerRecorder: timerRecorder,
            notificationCenter: notificationCenter
        )
        manager.startObservingEvents()

        notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await waitForTasksToDrain()

        XCTAssertEqual(timerRecorder.scheduledDates, [refreshTime.addingTimeInterval(1)])
    }

    @MainActor
    func testExternalTriggerDoesNotScheduleWithoutActiveSession() async {
        let now = Date(timeIntervalSince1970: 1_000)
        let timerRecorder = TimerRecorder()
        let notificationCenter = NotificationCenter()
        let manager = makeManager(
            now: now,
            certificate: certificate(refreshTime: now.addingTimeInterval(60)),
            timerRecorder: timerRecorder,
            notificationCenter: notificationCenter,
            loggedIn: false
        )
        manager.startObservingEvents()

        notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await waitForTasksToDrain()

        XCTAssertTrue(timerRecorder.scheduledDates.isEmpty)
        XCTAssertNil(manager.scheduledRefreshTime)
    }

    @MainActor
    func testApplicationActivationDoesNotBypassRetryBackoff() async {
        let now = Date(timeIntervalSince1970: 1_000)
        let timerRecorder = TimerRecorder()
        let notificationCenter = NotificationCenter()
        let manager = makeManager(
            now: now,
            certificate: certificate(refreshTime: now.addingTimeInterval(-60)),
            timerRecorder: timerRecorder,
            notificationCenter: notificationCenter,
            refreshError: TestError.refreshFailed
        )
        manager.startObservingEvents()
        await manager.planNextRefresh()

        timerRecorder.fireLast()
        await waitForTasksToDrain()
        let retryTime = now.addingTimeInterval(20)
        XCTAssertEqual(timerRecorder.scheduledDates.last, retryTime)

        notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await waitForTasksToDrain()

        XCTAssertEqual(Array(timerRecorder.scheduledDates.suffix(2)), [retryTime, retryTime])
    }

    private func makeManager(
        now: Date,
        certificate: VpnCertificate?,
        timerRecorder: TimerRecorder,
        notificationCenter: NotificationCenter = NotificationCenter(),
        loggedIn: Bool = true,
        refreshError: Error? = nil
    ) -> AppCertificateRefreshManagerImplementation {
        let sessionManager = AppSessionManagerMock(loggedIn: loggedIn, refreshError: refreshError)
        let factory = AppSessionManagerFactoryMock(sessionManager: sessionManager)
        let environment = AppCertificateRefreshManagerImplementation.Environment(
            notificationCenter: notificationCenter,
            workspaceNotificationCenter: NotificationCenter(),
            retryDelay: { $0.upperBound },
            scheduleTimer: timerRecorder.schedule
        )

        return withDependencies {
            $0.date = .constant(now)
            $0.vpnAuthenticationStorage = .testStorage(certificate: certificate)
        } operation: {
            AppCertificateRefreshManagerImplementation(factory: factory, environment: environment)
        }
    }

    private func certificate(refreshTime: Date) -> VpnCertificate {
        .init(
            certificate: "certificate",
            validUntil: refreshTime.addingTimeInterval(60 * 60),
            refreshTime: refreshTime
        )
    }

    private func waitForTasksToDrain() async {
        for _ in 0 ..< 20 {
            await Task.yield()
        }
    }
}

private final class TimerRecorder {
    private(set) var scheduledDates: [Date] = []
    private(set) var actions: [() -> Void] = []

    lazy var schedule: (Date, @escaping () -> Void) -> AppCertificateRefreshManagerImplementation.TimerToken = { [weak self] date, action in
        self?.scheduledDates.append(date)
        self?.actions.append(action)
        return .init(cancellation: {})
    }

    func fireLast() {
        actions.last?()
    }
}

private struct AppSessionManagerFactoryMock: AppSessionManagerFactory {
    let sessionManager: AppSessionManager

    func makeAppSessionManager() -> AppSessionManager {
        sessionManager
    }
}

private final class AppSessionManagerMock: AppSessionManager {
    var sessionStatus: SessionStatus
    let loggedIn: Bool
    let refreshError: Error?

    init(loggedIn: Bool, refreshError: Error?) {
        self.loggedIn = loggedIn
        self.refreshError = refreshError
        self.sessionStatus = loggedIn ? .established : .notEstablished
    }

    func attemptSilentLogIn() async throws {}
    func refreshVpnAuthCertificate() async throws {
        if let refreshError {
            throw refreshError
        }
    }
    func finishLogin(authCredentials _: AuthCredentials, success: @escaping () -> Void, failure _: @escaping (Error) -> Void) {
        success()
    }

    func logOut(force _: Bool, reason _: String?) {}
    func logOut() {}
    func replyToApplicationShouldTerminate() {}
}

private enum TestError: Error {
    case refreshFailed
}
