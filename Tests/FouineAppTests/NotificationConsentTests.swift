// NotificationConsentTests.swift — la case des notifications ne promet que ce
// que macOS a autorisé (audit BU-23, lot UX3). Propriété : A-App.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// Le défaut mesuré : la case restait cochée après une bannière d'autorisation
// laissée sans réponse pendant quatre minutes, et aucune notification n'est
// venue quand la file de pages scannées s'est vidée. La décision est ici, et
// elle est pure — la vue ne fait que l'appliquer.

import XCTest
import UserNotifications
@testable import FouineApp

final class NotificationConsentTests: XCTestCase {

    func testAnAuthorisedMacKeepsTheSwitchOn() {
        let outcome = NotificationConsent.resolve(wanted: true,
                                                  status: .authorized)
        XCTAssertTrue(outcome.switchOn)
        XCTAssertNil(outcome.notice)
    }

    /// Le cas MESURÉ : la bannière est restée sans réponse. `granted` valait
    /// faux, le réglage était déjà écrit, et rien ne le disait.
    func testAnIgnoredBannerTurnsTheSwitchBackOff() {
        let outcome = NotificationConsent.resolve(wanted: true,
                                                  status: .notDetermined)
        XCTAssertFalse(outcome.switchOn)
        XCTAssertEqual(outcome.notice, .notAllowed)
        XCTAssertNotNil(outcome.notice?.settingsURL,
                        "la ligne doit offrir le geste, pas seulement le constat")
    }

    func testARefusalTurnsTheSwitchBackOff() {
        let outcome = NotificationConsent.resolve(wanted: true, status: .denied)
        XCTAssertFalse(outcome.switchOn)
        XCTAssertEqual(outcome.notice, .notAllowed)
    }

    /// « provisional » livre les messages silencieusement : ils arrivent, ce
    /// que la case promet. L'éteindre serait éteindre une case qui marche.
    func testAProvisionalAuthorisationCounts() {
        let outcome = NotificationConsent.resolve(wanted: true,
                                                  status: .provisional)
        XCTAssertTrue(outcome.switchOn)
        XCTAssertNil(outcome.notice)
    }

    /// Hors bundle (`swift run FouineApp`), le système ne connaît pas Fouine :
    /// la case s'éteint, et la ligne dit pourquoi sans envoyer nulle part.
    func testWithoutABundleTheSwitchSaysSo() {
        let outcome = NotificationConsent.resolve(wanted: true, status: nil)
        XCTAssertFalse(outcome.switchOn)
        XCTAssertEqual(outcome.notice, .unavailable)
        XCTAssertNil(outcome.notice?.settingsURL)
    }

    /// Décocher n'a rien à demander à personne, et ne laisse aucun avis.
    func testUntickingAsksNothing() {
        for status: UNAuthorizationStatus? in [.authorized, .denied, nil] {
            let outcome = NotificationConsent.resolve(wanted: false,
                                                      status: status)
            XCTAssertFalse(outcome.switchOn)
            XCTAssertNil(outcome.notice)
        }
    }
}
