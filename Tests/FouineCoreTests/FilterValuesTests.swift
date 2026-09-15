// FilterValuesTests.swift — les valeurs qu'un filtre peut prendre (CM-11).
// Propriété : A-Core.
//
// Ces deux lectures n'existent que pour permettre un REFUS QUI NOMME : un
// filtre dont la valeur n'existe pas rendait zéro résultat, c'est-à-dire la
// même réponse que « votre corpus ne traite pas de ce sujet ». Ce qui est
// éprouvé ici est donc ce dont l'appelant a besoin pour écrire son message :
// une liste TRIÉE et sans doublon, et le sous-ensemble EXACT de ce qui manque.

import XCTest
@testable import FouineCore

final class FilterValuesTests: XCTestCase {

    // MARK: - Langues

    /// Triées, sans doublon, `und` comprise quand un document la porte : c'est
    /// une valeur de filtre légitime (« ceux dont la langue n'a pas été
    /// déterminée »), et la cacher ferait refuser une demande qui marcherait.
    func testKnownLanguagesAreSortedAndUnique() throws {
        let db = try makeDB()
        try addDoc(db, relPath: "Users/a/Livres/un.pdf", lang: "fr")
        try addDoc(db, relPath: "Users/a/Livres/deux.pdf", lang: "en")
        try addDoc(db, relPath: "Users/a/Livres/trois.pdf", lang: "fr")
        try addDoc(db, relPath: "Users/a/Livres/quatre.pdf",
                   lang: FacetKey.undeterminedLanguage)

        XCTAssertEqual(try db.store.knownLanguages(), ["en", "fr", "und"])
    }

    /// Les mêmes, RESTREINTES À DES RACINES (lot MN1) : c'est ce que le
    /// serveur MCP sert sous `--folders`, et son refus ne doit pas nommer une
    /// langue qui n'existe que hors périmètre.
    func testKnownLanguagesCanBeRestrictedToFolders() throws {
        let db = try makeDB()
        try addDoc(db, relPath: "Users/a/Livres/un.pdf", folder: "Livres", lang: "fr")
        try addDoc(db, relPath: "Users/a/Cours/deux.pdf", folder: "Cours", lang: "en")
        try addDoc(db, relPath: "Users/a/Cours/trois.pdf", folder: "Cours", lang: "de")

        XCTAssertEqual(try db.store.knownLanguages(inFolders: ["Livres"]), ["fr"])
        XCTAssertEqual(try db.store.knownLanguages(inFolders: ["Cours"]), ["de", "en"])
        XCTAssertEqual(try db.store.knownLanguages(inFolders: ["Livres", "Cours"]),
                       ["de", "en", "fr"])
        // Aucune étiquette = tout l'index, et c'est la requête d'avant.
        XCTAssertEqual(try db.store.knownLanguages(inFolders: []),
                       try db.store.knownLanguages())
        // Une racine qui n'existe pas ne rend rien — et ne fonde donc aucun
        // refus, par la règle de `FolderCheck`.
        XCTAssertEqual(try db.store.knownLanguages(inFolders: ["Inconnu"]), [])
    }

    /// Une langue ABSENTE (`NULL`) et une langue VIDE ne sont pas des valeurs :
    /// les rendre ferait proposer au modèle un filtre qui ne filtre rien.
    func testNullAndEmptyLanguagesAreNotValues() throws {
        let db = try makeDB()
        try addDoc(db, relPath: "Users/a/Livres/sans.pdf", lang: nil)
        let vide = try addDoc(db, relPath: "Users/a/Livres/vide.pdf", lang: nil)
        try db.store.setDocLanguage(vide, "")

        XCTAssertEqual(try db.store.knownLanguages(), [])
    }

    // MARK: - Identifiants de document

    /// Ce qui manque, et rien d'autre : le message d'erreur cite ces
    /// identifiants-là, dans l'ordre où on les a demandés.
    func testUnknownDocIDsKeepsOnlyWhatIsMissingInTheOrderAsked() throws {
        let db = try makeDB()
        let un = try addDoc(db, relPath: "Users/a/Livres/un.pdf")
        let deux = try addDoc(db, relPath: "Users/a/Livres/deux.pdf")

        XCTAssertEqual(try db.store.unknownDocIDs([un, 999_999, deux, 4_242]),
                       [999_999, 4_242])
        XCTAssertEqual(try db.store.unknownDocIDs([un, deux]), [])
        XCTAssertEqual(try db.store.unknownDocIDs([]), [],
                       "rien demandé, rien à refuser")
    }

    /// Un identifiant répété ne se cite qu'une fois : « unknown document id(s):
    /// 999999, 999999 » ferait douter le lecteur de ce qu'il a demandé.
    func testARepeatedUnknownIDIsNamedOnce() throws {
        let db = try makeDB()
        try addDoc(db, relPath: "Users/a/Livres/un.pdf")
        XCTAssertEqual(try db.store.unknownDocIDs([999_999, 999_999]), [999_999])
    }
}
