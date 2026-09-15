// IgnoreRuleSetTests.swift — les règles gardées par Fouine, et leur union avec
// le fichier `.fouineignore` (lot IG2). Propriété : A-Ingest.
//
// Ce que ces tests protègent :
//   · une règle invalide est REFUSÉE à la saisie, avec une phrase qui la nomme,
//     et n'entre jamais dans le jeu ;
//   · la forme canonique rend le dédoublonnage et le retrait fiables (casse,
//     accents, `/` initial, NFD collé depuis un terminal) ;
//   · le texte stocké se relit, et un texte abîmé n'applique rien sans le dire ;
//   · l'union au crawl : une règle gardée SANS fichier exclut, et une règle du
//     fichier répétée dans les réglages ne compte qu'une fois.

import XCTest
import FouineCore
@testable import FouineCrawl

final class IgnoreRuleSetTests: XCTestCase {

    // MARK: - Saisie et validation

    func testTheThreeFormsAreAcceptedInCanonicalForm() throws {
        XCTAssertEqual(try IgnoreRuleSet.canonical("  Santé/  "), "Santé/")
        XCTAssertEqual(try IgnoreRuleSet.canonical("/Cours/Archives//"), "Cours/Archives/")
        XCTAssertEqual(try IgnoreRuleSet.canonical("*.md"), "*.md")
        XCTAssertEqual(try IgnoreRuleSet.canonical("INDEX.md\n"), "INDEX.md",
                       "le saut de ligne de queue d'un copier-coller se retire")
        XCTAssertEqual(try IgnoreRuleSet.canonical("Cours/INDEX.md"), "Cours/INDEX.md")
        // NFD collé depuis un terminal : stocké en NFC.
        XCTAssertEqual(try IgnoreRuleSet.canonical("Sante\u{301}/"), "Santé/")
    }

    func testInvalidRulesAreRefusedWithASentenceThatNamesThem() {
        let cases: [(String, IgnoreRuleError)] = [
            ("", .empty),
            ("   ", .empty),
            ("/", .empty),
            ("!INDEX.md", .negation("!INDEX.md")),
            ("# note", .comment("# note")),
            ("Santé/\nCours/", .lineBreak("Santé/\nCours/")),
            ("Cours/../Santé/", .badPath("Cours/../Santé/")),
            ("./Santé/", .badPath("./Santé/")),
            ("A//B/", .badPath("A//B/")),
            ("..", .badPath("..")),
        ]
        for (raw, expected) in cases {
            XCTAssertThrowsError(try IgnoreRuleSet.canonical(raw), raw.debugDescription) {
                XCTAssertEqual($0 as? IgnoreRuleError, expected, raw.debugDescription)
            }
        }
        XCTAssertTrue(IgnoreRuleError.negation("!INDEX.md").message.contains("!INDEX.md"))
        XCTAssertTrue(IgnoreRuleError.badPath("a/../b/").message.contains("a/../b/"))
    }

    func testAnInvalidRuleNeverEntersTheSet() {
        var set = IgnoreRuleSet()
        XCTAssertThrowsError(try set.add("!x"))
        XCTAssertTrue(set.isEmpty)
        XCTAssertThrowsError(try IgnoreRuleSet(validating: ["Santé/", "!x"]))
    }

    // MARK: - Dédoublonnage et retrait

    func testTheSameRuleUnderAnotherSpellingIsKeptOnce() throws {
        var set = IgnoreRuleSet()
        XCTAssertTrue(try set.add("Santé/"))
        XCTAssertFalse(try set.add("/sante/"), "casse, accent et / initial : la même règle")
        XCTAssertFalse(try set.add("SANTE\u{301}/"))
        XCTAssertTrue(try set.add("Santé"), "sans / final, c'est une autre forme")
        XCTAssertEqual(set.rules, ["Santé/", "Santé"])
        XCTAssertEqual(set.stored("sante/"), "Santé/",
                       "« déjà ignoré » cite la forme gardée, pas la frappe")
    }

    func testRemovingFindsTheRuleUnderItsKey() throws {
        var set = try IgnoreRuleSet(validating: ["Santé/", "*.md"])
        XCTAssertTrue(set.remove("SANTÉ/"))
        XCTAssertFalse(set.remove("Santé/"), "déjà retirée")
        XCTAssertFalse(set.remove("!x"), "une règle invalide n'est pas là non plus")
        XCTAssertEqual(set.rules, ["*.md"])
    }

    // MARK: - Stockage

    func testTheStoredTextReadsBack() throws {
        let set = try IgnoreRuleSet(validating: ["Santé/", "*.md", "INDEX.md"])
        let json = try XCTUnwrap(set.json)
        XCTAssertEqual(json, #"["Santé/","*.md","INDEX.md"]"#,
                       "lisible en SQL : ni barre échappée, ni accent échappé")
        let decoded = IgnoreRuleSet.decode(json)
        XCTAssertEqual(decoded.set, set)
        XCTAssertTrue(decoded.warnings.isEmpty)
        XCTAssertNil(IgnoreRuleSet().json, "aucune règle : NULL, jamais []")
        XCTAssertTrue(IgnoreRuleSet.decode(nil).set.isEmpty)
    }

    func testADamagedStoredTextAppliesNothingAndSaysSo() {
        let unreadable = IgnoreRuleSet.decode("{pas du JSON")
        XCTAssertTrue(unreadable.set.isEmpty)
        XCTAssertEqual(unreadable.warnings.count, 1)

        // Une ligne fautive n'emporte pas les autres.
        let partial = IgnoreRuleSet.decode(#"["Santé/", "!x", 3, "*.md"]"#)
        XCTAssertEqual(partial.set.rules, ["Santé/", "*.md"])
        XCTAssertEqual(partial.warnings.count, 2)
    }

    // MARK: - Forme

    func testShapeSaysWhatARuleDesignates() {
        XCTAssertEqual(IgnoreRuleSet.shape(of: "Santé/"), .folder(components: ["Santé"]))
        XCTAssertEqual(IgnoreRuleSet.shape(of: "Cours/Archives/"),
                       .folder(components: ["Cours", "Archives"]))
        XCTAssertEqual(IgnoreRuleSet.shape(of: "Cours/INDEX.md"),
                       .path(components: ["Cours", "INDEX.md"]))
        XCTAssertEqual(IgnoreRuleSet.shape(of: "*.md"), .fileExtension("md"))
        XCTAssertEqual(IgnoreRuleSet.shape(of: "INDEX.md"), .fileName("INDEX.md"))
        XCTAssertEqual(IgnoreRuleSet.shape(of: "*brouillon*"), .namePattern("*brouillon*"))
        XCTAssertEqual(IgnoreRuleSet.shape(of: "*.m?"), .namePattern("*.m?"))
    }

    // MARK: - L'union

    func testAStoredRuleExcludesWithoutAnyFile() throws {
        let rules = IgnoreRules(stored: try IgnoreRuleSet(validating: ["Santé/", "*.md"]))
        XCTAssertTrue(rules.matches(relPath: "Santé/2025/bilan.pdf", isDirectory: false))
        XCTAssertTrue(rules.matches(relPath: "Cours/notes.MD", isDirectory: false))
        XCTAssertFalse(rules.matches(relPath: "Cours/TD 3.pdf", isDirectory: false))
        XCTAssertEqual(rules.entries.map(\.source), [.settings, .settings])
    }

    func testTheUnionCountsARepeatedRuleOnceAndKeepsTheFileFirst() throws {
        let file = IgnoreRules(text: "*.md\n/Santé/\n")
        let kept = IgnoreRules(stored: try IgnoreRuleSet(validating: ["sante/", "INDEX.pdf"]))
        let union = file.merging(kept)
        XCTAssertEqual(union.count, 3)
        XCTAssertEqual(union.entries, [
            IgnoreRules.Entry(rule: "*.md", source: .file),
            IgnoreRules.Entry(rule: "Santé/", source: .file),
            IgnoreRules.Entry(rule: "INDEX.pdf", source: .settings),
        ])
        XCTAssertTrue(union.contains(rule: "SANTÉ/"))
        XCTAssertFalse(union.contains(rule: "Santé"), "sans / final : une autre règle")
    }

    func testLoadUnitesTheFileAndTheStoredRules() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-ignore-union-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stored = try IgnoreRuleSet(validating: ["Santé/"])

        // Sans fichier : les règles gardées seules.
        XCTAssertEqual(IgnoreRules.load(root: directory, stored: stored)?.count, 1)
        XCTAssertNil(IgnoreRules.load(root: directory), "ni fichier ni règle : nil")

        try Data("*.md\n".utf8)
            .write(to: directory.appendingPathComponent(IgnoreRules.fileName))
        let both = try XCTUnwrap(IgnoreRules.load(root: directory, stored: stored))
        XCTAssertEqual(both.entries(from: .file).map(\.rule), ["*.md"])
        XCTAssertEqual(both.entries(from: .settings).map(\.rule), ["Santé/"])
        XCTAssertEqual(IgnoreRules.loadFile(root: directory)?.count, 1,
                       "le fichier seul ne voit pas les réglages")
    }

    // MARK: - Le compte

    func testCountMatchingCountsTheDocumentsAPassWouldRemove() throws {
        let rules = IgnoreRules(stored: try IgnoreRuleSet(
            validating: ["Santé/", "*.md", "Rapport.pages/"]))
        func doc(_ relPath: String, _ ext: String) -> DocRow {
            DocRow(id: 1, record: DocRecord(volUUID: "V", relPath: relPath, ext: ext,
                                            topFolder: "Perso", size: 1, mtime: 1))
        }
        let docs = [
            doc("Users/moi/Perso/Santé/bilan.pdf", "pdf"),
            doc("Users/moi/Perso/Sante\u{301}/2025/prise.pdf", "pdf"),
            doc("Users/moi/Perso/Cours/notes.md", "md"),
            doc("Users/moi/Perso/Cours/TD.pdf", "pdf"),
            // Un paquet-document est un DOSSIER pour le crawl.
            doc("Users/moi/Perso/Rapport.pages", "pages"),
            // Hors de la racine : jamais compté.
            doc("Users/moi/Autre/Santé/x.pdf", "pdf"),
        ]
        XCTAssertEqual(rules.countMatching(docs, rootRelPath: "Users/moi/Perso"), 4)
        XCTAssertEqual(IgnoreRules(text: "").countMatching(docs, rootRelPath: "Users/moi/Perso"), 0)
    }

    /// La consigne demandait « some documents » sans nombre si le compte
    /// dépassait 300 ms sur 2 000 documents. Mesuré ici plutôt que supposé :
    /// 57 à 68 ms en build debug, machine chargée, cinq règles (14/09/2026).
    /// Le nombre s'affiche donc ; l'assertion rougit si le compte venait à
    /// franchir le budget.
    func testCountingTwoThousandDocumentsIsFarBelowTheBudget() throws {
        let rules = IgnoreRules(stored: try IgnoreRuleSet(
            validating: ["Santé/", "*.md", "INDEX.md", "*brouillon*", "Cours/Archives/"]))
        let docs = (0..<2_000).map { index in
            DocRow(id: Int64(index), record: DocRecord(
                volUUID: "V", relPath: "Users/moi/Perso/Dossier \(index % 40)/Sous-dossier/fichier \(index).pdf",
                ext: "pdf", topFolder: "Perso", size: 1, mtime: 1))
        }
        let start = Date()
        _ = rules.countMatching(docs, rootRelPath: "Users/moi/Perso")
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 0.3, "compte de 2 000 documents : \(elapsed) s")
    }
}

// MARK: - Le crawl, avec des règles gardées

final class StoredIgnoreRulesCrawlTests: XCTestCase {

    var root: URL!
    var store: KeepingStore!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fouine-stored-ignore-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        let resolved = try VolumeResolver.resolve(path: root)
        store = KeepingStore()
        store.inner.addRoot(RootRecord(id: 1, volUUID: resolved.volUUID,
                                       relPath: resolved.relPath, label: "Perso",
                                       enabled: true))
        for relative in ["Santé/analyses.pdf", "Santé/2025/bilan.pdf",
                         "Cours/TD 3.pdf", "Cours/INDEX.md"] {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("contenu".utf8).write(to: url)
        }
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    var names: [String] {
        store.inner.allDocs.map { ($0.record.relPath as NSString).lastPathComponent }
            .sorted()
    }

    /// LE test d'IG1 rejoué sur une règle gardée, SANS fichier : ce qui était
    /// indexé sort à la passe suivante, et revient quand la règle part.
    func testAStoredRuleWithoutAFileTakesDocumentsOutAndBack() throws {
        let crawler = FouineCrawler(note: { _ in })
        _ = try crawler.crawl(rootID: 1, mode: .full, store: store)
        XCTAssertEqual(names, ["INDEX.md", "TD 3.pdf", "analyses.pdf", "bilan.pdf"])

        store.keep(try IgnoreRuleSet(validating: ["Santé/"]).json, rootID: 1)
        let second = try crawler.crawl(rootID: 1, mode: .delta, store: store)
        XCTAssertEqual(names, ["INDEX.md", "TD 3.pdf"])
        XCTAssertEqual(second.removed, 2)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(IgnoreRules.fileName).path),
            "rien n'est écrit dans le dossier de l'utilisateur")

        store.keep(nil, rootID: 1)
        let third = try crawler.crawl(rootID: 1, mode: .delta, store: store)
        XCTAssertEqual(names, ["INDEX.md", "TD 3.pdf", "analyses.pdf", "bilan.pdf"])
        XCTAssertEqual(third.added, 2)
    }

    /// Les deux sources à la fois : chacune exclut sa part.
    func testTheFileAndTheStoredRulesBothApply() throws {
        try Data("*.md\n".utf8).write(to: root.appendingPathComponent(IgnoreRules.fileName))
        store.keep(try IgnoreRuleSet(validating: ["Santé/"]).json, rootID: 1)
        _ = try FouineCrawler(note: { _ in }).crawl(rootID: 1, mode: .full, store: store)
        XCTAssertEqual(names, ["TD 3.pdf"])
    }

    /// Un texte abîmé en base se DIT, et n'exclut rien — comme un fichier qui
    /// n'est pas du texte.
    func testADamagedStoredTextIsReported() throws {
        store.keep("{abîmé", rootID: 1)
        let notes = NoteCollector()
        _ = try FouineCrawler(note: { notes.append($0) })
            .crawl(rootID: 1, mode: .full, store: store)
        XCTAssertEqual(names.count, 4)
        XCTAssertEqual(notes.messages.count, 1)
        XCTAssertTrue(notes.messages[0].contains("Perso"), notes.messages[0])
    }
}
