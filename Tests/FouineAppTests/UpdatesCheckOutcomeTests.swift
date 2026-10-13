// UpdatesCheckOutcomeTests.swift — ce que l'onglet « Mises à jour » appelle un
// échec de vérification (`Updates.checkFailed`). Propriété : A-Pack.
//
// Sparkle arrête son pilote par une erreur aussi quand tout s'est bien passé
// pour l'utilisateur : aucune nouvelle version, ou une version trouvée dont il
// a annulé ou remis à plus tard l'installation. Seuls les vrais échecs (réseau,
// serveur, flux illisible) doivent faire dire « Fouine n'a pas pu vérifier… ».
//
// Les codes sont écrits en clair (`SUErrors.h` de Sparkle 2.9) : la cible de
// tests ne dépend pas de Sparkle, et un code qui bougerait dans une version
// future de Sparkle doit faire rougir ce test, pas passer inaperçu.

import XCTest
@testable import FouineApp

final class UpdatesCheckOutcomeTests: XCTestCase {

    private func sparkle(_ code: Int) -> NSError {
        NSError(domain: "SUSparkleErrorDomain", code: code)
    }

    func testNoNewVersionIsNotAFailure() {
        XCTAssertFalse(Updates.checkFailed(sparkle(1001)))   // SUNoUpdateError
    }

    func testCancellingTheInstallOfAFoundVersionIsNotAFailure() {
        XCTAssertFalse(Updates.checkFailed(sparkle(4007)),   // SUInstallationCanceledError
                       "le serveur a répondu et proposé une version")
        XCTAssertFalse(Updates.checkFailed(sparkle(4008)))   // SUInstallationAuthorizeLaterError
    }

    func testUnreachableServerOrUnreadableFeedIsAFailure() {
        XCTAssertTrue(Updates.checkFailed(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)))
        XCTAssertTrue(Updates.checkFailed(sparkle(1002)))    // SUAppcastError
        XCTAssertTrue(Updates.checkFailed(sparkle(4005)))    // SUInstallationError
    }

    /// Le code seul ne suffit pas : un 1001 d'un autre domaine n'est pas
    /// « aucune mise à jour ».
    func testTheDomainIsChecked() {
        XCTAssertTrue(Updates.checkFailed(NSError(domain: NSPOSIXErrorDomain, code: 1001)))
    }
}
