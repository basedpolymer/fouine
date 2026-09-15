// FixRegressionTests.swift — non-régression de la vague corrective (recette
// tranche A) : bogue 1 (pres:N + flou -> sortie 3), bogue 2 (pageMeta non
// sargable, P4), bogue 3 (sondes trigrammes, P8), arbitrage T5 (exclusion par
// DOCUMENT), observation 5 (geste TCC réservé au refus de lecture).
// Propriété : A-Core.

import XCTest
@testable import FouineCore

final class FixRegressionTests: XCTestCase {

    // MARK: - Bogue 1 · `pres:N` + flou ne doit JAMAIS sortir en erreur

    /// La commande du §8.1 T2 : tous les termes ≥ 6 lettres sont dans le NEAR,
    /// `substitute` n'y touche pas, aucune branche fz ne peut naître. L'ancien
    /// code produisait `u AS (SELECT * FROM ex)` que SQLite aplatit — bm25()
    /// interdit, erreur 1, sortie 3. Le repli exact doit rendre le même
    /// résultat dans les TROIS modes.
    func testNEARWithFuzzyDoesNotFailAndMatchesExactResults() throws {
        let db = try makeDB()
        let docID = try addDoc(db, relPath: "Users/alice/Livres/capes.pdf")
        try db.store.replacePages(docID: docID, pages: [
            page(1, "Énergie libre F et enthalpie libre G, ou énergie de Gibbs."),
            page(2, "rien à voir ici"),
        ])
        try TrigramExpander(store: db.store).warm()

        let input = "pres:10 energie libre gibbs"
        let off = try db.store.search(try query(input, fuzzy: .off))
        XCTAssertEqual(off.totalPages, 1)
        XCTAssertEqual(off.hits.map(\.page), [1])

        for mode in [FuzzyMode.auto, .on] {
            for scope in [FuzzyScope.ocrOnly, .all] {
                let r = try db.store.search(try query(input, fuzzy: mode,
                                                      scope: scope))
                XCTAssertEqual(r.totalPages, off.totalPages,
                               "\(mode)/\(scope) : résultat ≠ exact (bogue 1)")
                XCTAssertEqual(r.hits.map(\.page), off.hits.map(\.page))
                XCTAssertEqual(r.hits.first?.fuzzyDistance, 0)
            }
        }

        // La facette sur la même requête ne doit pas dépendre de la chance
        // (élimination de bm25 par SQLite) : prélude exact sans bm25().
        let facets = try db.store.facets(try query(input, fuzzy: .on, scope: .all),
                                         by: .folder)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: facets), ["Livres": 1])
    }

    /// Mixte : un terme substituable HORS NEAR + un NEAR. Le plan flou doit
    /// porter ses branches sans erreur, et le NEAR rester intact.
    func testMixedNEARAndBareTermWithFuzzyOn() throws {
        let db = try makeDB()
        let docID = try addDoc(db, relPath: "Users/alice/Livres/mixte.pdf")
        try db.store.replacePages(docID: docID, pages: [
            page(1, "enthalpie et energie libre de gibbs reunies ici"),
        ])
        try TrigramExpander(store: db.store).warm()
        let r = try db.store.search(
            try query("enthalpie pres:10 energie libre gibbs",
                      fuzzy: .on, scope: .all))
        XCTAssertEqual(r.totalPages, 1)
        XCTAssertEqual(r.hits.first?.fuzzyDistance, 0)
    }

    func testIsSubstitutableIgnoresNEARMembersAndPhrases() {
        let fts = "enthalpie AND \"gaz azote\" AND NEAR(energie libre gibbs, 10)"
        XCTAssertTrue(GRDBStore.isSubstitutable("enthalpie", in: fts))
        XCTAssertFalse(GRDBStore.isSubstitutable("energie", in: fts),
                       "membre d'un NEAR : jamais substituable (§5.5.3)")
        XCTAssertFalse(GRDBStore.isSubstitutable("azote", in: fts),
                       "intérieur de phrase : jamais substituable")
        XCTAssertFalse(GRDBStore.isSubstitutable("gibbs", in: fts))
    }

    // MARK: - Bogue 2 · pageMeta sargable (P4)

    /// Le plan DOIT passer par la clé primaire de page_src — l'ancienne forme
    /// `(doc_id*100000+page) IN (…)` déclenchait `SCAN page_src` : 42-49 ms
    /// par appel sur l'index complet, deux fois par recherche.
    func testPageMetaPlanUsesThePrimaryKey() throws {
        let db = try makeDB()
        let docID = try addDoc(db, relPath: "Users/alice/Livres/meta.pdf")
        try db.store.replacePages(docID: docID, pages: [
            page(1, "alpha"), page(2, "beta"),
        ])
        let keys = (1...50).map { (docID: docID, page: $0) }
        let plan = try db.store.rawPlanDetails(GRDBStore.pageMetaSQL(for: keys))
            .joined(separator: " | ")
        XCTAssertTrue(plan.contains("PRIMARY KEY"),
                      "pageMeta ne passe pas par la PK de page_src : \(plan)")
        XCTAssertFalse(plan.contains("SCAN page_src"),
                       "balayage de page_src (bogue 2) : \(plan)")
    }

    func testPageMetaReturnsTheSameRowsAsBefore() throws {
        let db = try makeDB()
        let a = try addDoc(db, relPath: "Users/alice/Livres/a.pdf")
        let b = try addDoc(db, relPath: "Users/alice/Cours/b.pdf", folder: "Cours")
        try db.store.replacePages(docID: a, pages: [page(1, "un"), page(2, "deux")])
        try db.store.completeOCR(docID: b, page: 3,
                                 result: ocrPage("page reconnue par Vision"))
        let meta = try db.store.pageMeta(for: [(a, 1), (a, 2), (b, 3), (b, 99)])
        XCTAssertEqual(meta.count, 3, "la clé absente (b, 99) ne rend rien")
        XCTAssertEqual(meta[Schema.ftsRowID(docID: a, page: 1)]?.source, .native)
        XCTAssertEqual(meta[Schema.ftsRowID(docID: b, page: 3)]?.source, .ocrAccurate)
        XCTAssertEqual(meta[Schema.ftsRowID(docID: b, page: 3)]?.engine, .vision)
    }

    // MARK: - Arbitrage T5 · `-terme` exclut le DOCUMENT entier

    func testNegativeTermExcludesTheWholeDocument() throws {
        let db = try makeDB()
        // docA : « enthalpie » p.1, « biologie » p.2 SEULEMENT -> exclu ENTIER
        // (l'ancienne sémantique par page aurait gardé la p.1).
        let docA = try addDoc(db, relPath: "Users/alice/Livres/aExclure.pdf")
        try db.store.replacePages(docID: docA, pages: [
            page(1, "toute l'enthalpie du systeme"),
            page(2, "un chapitre entier de biologie"),
        ])
        // docB : « enthalpie » sans « biologie » nulle part -> conservé.
        let docB = try addDoc(db, relPath: "Users/alice/Livres/aGarder.pdf")
        try db.store.replacePages(docID: docB, pages: [
            page(1, "enthalpie libre et energie de gibbs"),
        ])

        let (q, negative) = try QueryParser.searchPlan("enthalpie -biologie",
                                                       fuzzy: .off)
        XCTAssertEqual(q.fts, "enthalpie",
                       "les négatifs ne participent plus au MATCH de page")
        XCTAssertEqual(negative, "biologie")

        let r = try db.store.search(q, excludingDocsMatching: negative)
        XCTAssertEqual(r.hits.map(\.docID), [docB],
                       "T5 : un document portant « biologie » sur UNE page "
                       + "est exclu en entier")
        XCTAssertEqual(r.totalPages, 1)
        XCTAssertEqual(r.totalDocs, 1)

        // Les facettes suivent la même portée.
        let facets = try db.store.facets(q, by: .folder,
                                         excludingDocsMatching: negative)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: facets), ["Livres": 1])

        // Sans exclusion, les deux documents répondent (contrôle).
        let all = try db.store.search(q, excludingDocsMatching: nil)
        XCTAssertEqual(Set(all.hits.map(\.docID)), [docA, docB])
    }

    func testSeveralNegativeTermsExcludeAnyMatchingDocument() throws {
        let db = try makeDB()
        let bio = try addDoc(db, relPath: "Users/alice/Livres/bio.pdf")
        try db.store.replacePages(docID: bio, pages: [
            page(1, "enthalpie"), page(2, "biologie")])
        let geo = try addDoc(db, relPath: "Users/alice/Livres/geo.pdf")
        try db.store.replacePages(docID: geo, pages: [
            page(1, "enthalpie"), page(2, "geologie")])
        let keep = try addDoc(db, relPath: "Users/alice/Livres/ok.pdf")
        try db.store.replacePages(docID: keep, pages: [page(1, "enthalpie")])

        let (q, negative) = try QueryParser.searchPlan(
            "enthalpie -biologie -geologie", fuzzy: .off)
        XCTAssertEqual(negative, "biologie OR geologie")
        let r = try db.store.search(q, excludingDocsMatching: negative)
        XCTAssertEqual(r.hits.map(\.docID), [keep])
    }

    /// Le flou respecte l'exclusion par document : une variante ne réintroduit
    /// pas un document exclu.
    func testFuzzyBranchesHonourTheDocumentExclusion() throws {
        let db = try makeDB()
        let excluded = try addDoc(db, relPath: "Users/alice/Cours/exclu.pdf",
                                  folder: "Cours")
        // « polymrre » : une coquille d'OCR à distance 1, et non le pluriel,
        // qui est une forme exacte du mot depuis le lot R1 (Morphology).
        try db.store.completeOCR(docID: excluded, page: 1,
                                 result: ocrPage("les polymrre et la biologie"))
        let kept = try addDoc(db, relPath: "Users/alice/Cours/garde.pdf",
                              folder: "Cours")
        try db.store.completeOCR(docID: kept, page: 1,
                                 result: ocrPage("les polymrre thermodurcissables"))
        try TrigramExpander(store: db.store).warm()

        let (q, negative) = try QueryParser.searchPlan("polymere -biologie",
                                                       fuzzy: .on)
        let r = try db.store.search(q, excludingDocsMatching: negative)
        XCTAssertEqual(r.hits.map(\.docID), [kept],
                       "la branche floue a réintroduit un document exclu")
        XCTAssertEqual(r.hits.first?.fuzzyDistance, 1)
    }

    /// Un NOT seul : message clair, pas une erreur SQLite (sortie 3).
    func testExclusionOnlyQueryIsRefusedWithAClearMessage() {
        for input in ["-biologie", "-a -b", "dossier:Cours -biologie"] {
            XCTAssertThrowsError(try QueryParser.parse(input), input) { error in
                XCTAssertEqual(error as? QueryError, .exclusionOnly)
                XCTAssertEqual(
                    (error as? QueryError)?.errorDescription,
                    "exclusion alone (-term): add at least one term to search for")
            }
        }
    }

    // MARK: - Bogue 3 · flou en portée `ocr` sans page OCR : court-circuit

    /// Sans AUCUNE page OCR, la branche fz joindrait un ensemble vide : le
    /// résultat est identique à l'exact et l'expansion (sondes SQL +
    /// Levenshtein) ne doit même pas être payée.
    func testFuzzyOCRScopeWithoutOCRPagesBehavesExactly() throws {
        let db = try makeDB()
        let docID = try addDoc(db, relPath: "Users/alice/Livres/natif.pdf")
        try db.store.replacePages(docID: docID, pages: [
            page(1, "le taux de conversion mesure au reacteur"),
        ])
        try TrigramExpander(store: db.store).warm()

        // Terme garblé : l'exact ne trouve rien, et le flou en portée ocr non
        // plus (aucune page OCR) — sans erreur. C'est ce que prouve le mode
        // `off` : le chemin qui dégénérait est emprunté, et il ne lève rien.
        let off = try db.store.search(try query("converslon", fuzzy: .off,
                                                scope: .ocrOnly))
        XCTAssertEqual(off.totalPages, 0)
        // DEPUIS LE LOT MP1 (C2-08), la portée `ocr` qui ne rend rien est
        // rejouée sur TOUT l'index : c'est exactement le cas de l'utilisateur
        // qui se trompe dans SA requête sur un corpus sans page scannée. Le
        // court-circuit du bogue 3 joue toujours — la PREMIÈRE passe ne paie
        // aucune expansion —, mais la recherche, elle, répond maintenant.
        let on = try db.store.search(try query("converslon", fuzzy: .on,
                                               scope: .ocrOnly))
        XCTAssertEqual(on.totalPages, 1)
        XCTAssertTrue(on.fuzzyFallback)
        XCTAssertEqual(on.hits.first?.fuzzyDistance, 1)
        // En portée all, l'expansion joue (contrôle que le court-circuit est
        // bien limité à la portée ocr).
        let all = try db.store.search(try query("converslon", fuzzy: .on,
                                                scope: .all))
        XCTAssertEqual(all.totalPages, 1)
        XCTAssertEqual(all.hits.first?.fuzzyDistance, 1)
    }

    // MARK: - Observation 5 · geste TCC réservé au refus de lecture

    func testMissingRootReasonDoesNotMentionTCC() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-inexistant-\(UUID().uuidString)")
        XCTAssertThrowsError(try RootProbe.probe(missing)) { error in
            guard case let FouineError.rootUnreadable(_, reason) = error else {
                return XCTFail("attendu rootUnreadable, obtenu \(error)")
            }
            // Le motif est TYPÉ depuis le palier 3.5 : on affirme sur le
            // CAS, pas sur des mots de la phrase.
            XCTAssertEqual(RootProbe.reason(reason), .missing,
                           "un dossier disparu doit rendre .missing : \(reason)")
            XCTAssertFalse(RootProbe.isPermissionDenial(reason))
            // Et la phrase rendue ne parle pas de confidentialité : le geste
            // TCC est réservé au refus de lecture (§7.1).
            XCTAssertFalse(RootProbe.Reason.missing.english
                               .contains(RootProbe.tccGuidance),
                           "dossier disparu : pas de geste TCC dans la phrase")
        }
    }

    func testPermissionDeniedRootIsFlaggedForTCCGesture() throws {
        try XCTSkipIf(geteuid() == 0, "root ignore les permissions POSIX")
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("fouine-eperm-\(UUID().uuidString)",
                                    isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("fichier.txt")
        try Data("contenu".utf8).write(to: file)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            try? fm.removeItem(at: dir)
        }
        XCTAssertThrowsError(try RootProbe.probe(dir)) { error in
            guard case let FouineError.rootUnreadable(_, reason) = error else {
                return XCTFail("attendu rootUnreadable, obtenu \(error)")
            }
            XCTAssertTrue(RootProbe.isPermissionDenial(reason),
                          "refus de lecture non reconnu comme tel : \(reason)")
        }
    }

    func testIsPermissionDenialClassifier() {
        XCTAssertTrue(RootProbe.isPermissionDenial(
            RootProbe.Reason.permissionDenied.token))
        XCTAssertFalse(RootProbe.isPermissionDenial(
            RootProbe.Reason.missing.token))
        XCTAssertFalse(RootProbe.isPermissionDenial(nil))
        // Un motif d'un binaire PLUS ANCIEN (une phrase française) se relit en
        // `.system` et n'est jamais pris pour un refus de lecture.
        XCTAssertEqual(
            RootProbe.reason("dossier introuvable (déplacé, renommé ou supprimé)"),
            .system("dossier introuvable (déplacé, renommé ou supprimé)"))
        XCTAssertFalse(RootProbe.isPermissionDenial(
            "dossier introuvable (déplacé, renommé ou supprimé)"))
    }
}
