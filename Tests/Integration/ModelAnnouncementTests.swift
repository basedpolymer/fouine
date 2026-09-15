// ModelAnnouncementTests.swift — `fouine model download` dit-il vrai ?
// Propriété : A-Recette. Audit A1-05.
//
// « Une annonce fausse détruit la valeur des annonces justes. » La commande
// imprimait DEUX CONSTANTES avant le premier octet — « github.com, puis
// release-assets.githubusercontent.com » et « 220 MB » — quelle que soit
// l'adresse. Avec `FOUINE_MODEL_URL` vers un autre serveur, Fouine annonçait
// donc des hôtes qu'il n'allait pas contacter et une taille qu'il ne
// connaissait pas, juste avant de contacter autre chose.
//
// ═══ AUCUN RÉSEAU ══════════════════════════════════════════════════════════
//
// Les deux adresses employées sont `https://127.0.0.1:1/…` (port 1, refus
// immédiat sur la boucle locale) et un `file://` inexistant. Base jetable,
// répertoire de modèle jetable (`FOUINE_MODEL_DIR`) : le modèle installé sur
// la machine n'est ni lu, ni écrit, ni effacé.

import Foundation
import XCTest

final class ModelAnnouncementTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-annonce-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: scratch,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    /// `model download` sur un répertoire de modèle JETABLE et une adresse
    /// jetable. Rend la sortie complète (stdout + stderr).
    private func announce(url: String) throws -> CommandResult {
        try Recette.run(
            ["model", "download"],
            database: scratch.appendingPathComponent("recette.db"),
            timeout: 120,
            extraEnvironment: [
                "FOUINE_MODEL_URL": url,
                "FOUINE_MODEL_DIR": scratch
                    .appendingPathComponent("models/e5-small").path,
            ])
    }

    /// Une adresse qui n'est PAS l'asset de release : ni « github.com », ni
    /// « 220 MB ». L'hôte réellement visé est nommé, la taille est dite
    /// inconnue.
    func testAnotherSourceIsNotAnnouncedAsGitHub() throws {
        let result = try announce(url: "https://127.0.0.1:1/x.zip")
        let text = result.stdout + result.stderr

        XCTAssertFalse(text.contains("github.com"),
                       "l'annonce cite GitHub pour une autre adresse : " + text)
        XCTAssertFalse(text.contains("220 MB"),
                       "l'annonce cite la taille de l'asset de release pour "
                       + "une autre archive : " + text)
        XCTAssertTrue(text.contains("127.0.0.1"),
                      "l'annonce doit nommer l'hôte réellement visé : " + text)
        XCTAssertTrue(text.contains("unknown until transfer"),
                      "la taille d'une archive quelconque n'est pas connue "
                      + "avant le transfert : " + text)
        // La connexion est refusée (port 1) : la commande échoue, ce qui est le
        // comportement voulu. Ce test porte sur l'ANNONCE, pas sur le transfert.
        XCTAssertNotEqual(result.status, 0, result.describe)
    }

    /// Une source locale : aucun hôte du tout — et toujours pas de GitHub.
    func testLocalSourceAnnouncesNoHostAtAll() throws {
        let missing = scratch.appendingPathComponent("absent.zip")
        let result = try announce(url: "file://" + missing.path)
        let text = result.stdout + result.stderr

        XCTAssertFalse(text.contains("github.com"), text)
        XCTAssertTrue(text.contains("hosts        : none"), text)
        XCTAssertNotEqual(result.status, 0, result.describe)
    }
}
