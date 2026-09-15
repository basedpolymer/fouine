// LanguageBackfillTests.swift — rattrapage de `docs.lang` (lot U3, R-10).
// Propriété : A-Core.
//
// Ce qui est prouvé ici, et pourquoi : `docs.lang` n'était écrite qu'à
// l'extraction, et 1 392 des 1 499 documents de la base réelle étaient donc
// restés NULL (mesure du lot U2). Le rattrapage doit (a) ne relire QUE ce qui
// en a besoin, (b) ne jamais relire deux fois le même document — d'où le jeton
// « und » quand la détection ne conclut pas —, et (c) laisser la facette et le
// filtre voir NULL et « und » comme une seule et même valeur.
//
// La détection est INJECTÉE (elle vit dans FouineIndex, que ce paquet de tests
// ne voit pas) : un détecteur de contrôle rend ici des réponses choisies, ce
// qui rend chaque cas déterministe — NLLanguageRecognizer, lui, est testé dans
// `FouineIndexTests/LanguageDetectorTests`.

import XCTest
@testable import FouineCore

final class LanguageBackfillTests: XCTestCase {

    /// Un détecteur de contrôle : le premier mot de la première page est la
    /// langue, sauf « ? » qui ne conclut pas — comme un texte trop court.
    private func firstWord(_ pages: [PageText]) -> String? {
        guard let first = pages.first?.text.split(separator: " ").first else { return nil }
        return first == "?" ? nil : String(first)
    }

    /// Un document extrait, avec ses pages et son compte de pages.
    @discardableResult
    private func indexed(_ db: TempDB, _ relPath: String, pages: [PageText],
                         lang: String? = nil, nPages: Int? = nil) throws -> Int64 {
        let id = try addDoc(db, relPath: relPath, lang: lang)
        if !pages.isEmpty { try db.store.replacePages(docID: id, pages: pages) }
        try db.store.setPageCount(id, nPages ?? max(pages.count, 1))
        try db.store.setDocState(id, .extracted, err: nil)
        return id
    }

    // MARK: - Qui est candidat

    func testListeBorneeEtOrdonnee() throws {
        let db = try makeDB()
        var ids: [Int64] = []
        for i in 1...5 {
            ids.append(try indexed(db, "Users/a/d\(i).pdf",
                                   pages: [page(1, "fr texte")]))
        }
        XCTAssertEqual(try db.store.documentsWithoutLanguage(limit: 3),
                       Array(ids.prefix(3)),
                       "bornée par la limite, et ordonnée par id : le rattrapage "
                       + "avance dans le fonds au lieu de repiocher les mêmes")
        XCTAssertEqual(try db.store.documentsWithoutLanguage(limit: 0), [])
        XCTAssertEqual(try db.store.documentsWithoutLanguageCount(), 5)
    }

    func testSeulsLesDocumentsExtraitsSansLangueSontCandidats() throws {
        let db = try makeDB()
        let sansLangue = try indexed(db, "Users/a/sans.pdf", pages: [page(1, "fr a")])
        // Déjà détecté à l'extraction : rien à refaire.
        try indexed(db, "Users/a/avec.pdf", pages: [page(1, "fr b")], lang: "fr")
        // Découvert mais pas encore extrait : son texte n'est pas en base.
        let neuf = try addDoc(db, relPath: "Users/a/neuf.pdf")
        try db.store.setPageCount(neuf, 3)
        // Extrait mais sans aucune page : rien à lire.
        let vide = try indexed(db, "Users/a/vide.pdf", pages: [], nPages: 0)
        _ = vide

        XCTAssertEqual(try db.store.documentsWithoutLanguage(limit: 100), [sansLangue])
    }

    // MARK: - Le rattrapage lui-même

    func testRattrapageEcritLesCodesEtLeJetonIndetermine() throws {
        let db = try makeDB()
        let fr = try indexed(db, "Users/a/fr.pdf", pages: [page(1, "fr enthalpie")])
        let en = try indexed(db, "Users/a/en.pdf", pages: [page(1, "en enthalpy")])
        let und = try indexed(db, "Users/a/court.pdf", pages: [page(1, "? ?")])

        let report = try db.store.backfillLanguages(
            limit: 100, sampleCharacters: 4_000, detect: firstWord)

        XCTAssertEqual(report.scanned, 3)
        XCTAssertEqual(report.determined, 2)
        XCTAssertEqual(report.remaining, 0)
        XCTAssertEqual(report.counts,
                       ["fr": 1, "en": 1, FacetKey.undeterminedLanguage: 1])
        XCTAssertEqual(try lang(db, fr), "fr")
        XCTAssertEqual(try lang(db, en), "en")
        XCTAssertEqual(try lang(db, und), FacetKey.undeterminedLanguage,
                       "« und » et NON NULL : sinon ce document redevient "
                       + "candidat à chaque passe, pour rien")
    }

    func testAucunDocumentNEstReluDeuxFois() throws {
        let db = try makeDB()
        // Une page vide et un texte qui ne conclut pas : les deux populations
        // qui, sans jeton, tourneraient en boucle.
        try indexed(db, "Users/a/court.pdf", pages: [page(1, "? ?")])
        try indexed(db, "Users/a/blanc.pdf", pages: [page(1, "")])

        let first = try db.store.backfillLanguages(
            limit: 100, sampleCharacters: 4_000, detect: firstWord)
        XCTAssertEqual(first.scanned, 2)

        let second = try db.store.backfillLanguages(
            limit: 100, sampleCharacters: 4_000, detect: firstWord)
        XCTAssertEqual(second.scanned, 0, "la deuxième exécution ne trouve plus rien")
        XCTAssertEqual(second.remaining, 0)
        XCTAssertEqual(try db.store.documentsWithoutLanguage(limit: 10), [])
    }

    func testLimiteEtReste() throws {
        let db = try makeDB()
        for i in 1...5 {
            try indexed(db, "Users/a/d\(i).pdf", pages: [page(1, "fr texte")])
        }
        let report = try db.store.backfillLanguages(
            limit: 2, sampleCharacters: 4_000, chunk: 1, detect: firstWord)
        XCTAssertEqual(report.scanned, 2, "au plus `limit` documents par exécution")
        XCTAssertEqual(report.remaining, 3)
        XCTAssertEqual(report.distribution, "fr 2")

        // La suivante reprend là où celle-ci s'est arrêtée.
        let next = try db.store.backfillLanguages(
            limit: 10, sampleCharacters: 4_000, detect: firstWord)
        XCTAssertEqual(next.scanned, 3)
        XCTAssertEqual(next.remaining, 0)
    }

    /// L'échantillon est BORNÉ et RÉPARTI (constat C2-01). Il était pris sur
    /// les premières pages : c'est-à-dire sur la page de garde, le préambule
    /// Gutenberg ou les en-têtes d'un courriel — 62 documents de la base réelle
    /// en portaient une langue improbable. Trois régions sont désormais lues,
    /// vers 10 %, 50 % et 90 % du document, et le coût de lecture ne bouge pas.
    func testEchantillonReparti() throws {
        let db = try makeDB()
        let long = String(repeating: "a", count: 300)
        try indexed(db, "Users/a/pave.pdf",
                    pages: (1...20).map { page($0, "fr \(long)") })

        var seen: [PageText] = []
        _ = try db.store.backfillLanguages(limit: 1, sampleCharacters: 1_000,
                                           detect: { pages in
            seen = pages
            return "fr"
        })
        let read = seen.map(\.page)
        XCTAssertFalse(read.contains(1),
                       "la tête du document ne décide plus de la langue : \(read)")
        XCTAssertTrue(read.contains { $0 <= 5 } && read.contains { (8...13).contains($0) }
                      && read.contains { $0 >= 16 },
                      "trois régions, réparties sur le document : \(read)")
        XCTAssertLessThanOrEqual(seen.reduce(0) { $0 + $1.text.count }, 1_100,
                                 "l'échantillon reste borné : un ouvrage de "
                                 + "1 570 pages ne traverse pas la base")
    }

    /// Un document court est lu d'un bloc : il n'y a rien à répartir sur une
    /// lettre d'une page, et un tiers d'échantillon donnerait MOINS de matière
    /// qu'avant à la moitié d'un fonds ordinaire.
    func testDocumentCourtLuDUnBloc() throws {
        let db = try makeDB()
        try indexed(db, "Users/a/lettre.pdf",
                    pages: (1...2).map { page($0, "fr page \($0)") })

        var seen: [PageText] = []
        _ = try db.store.backfillLanguages(limit: 1, sampleCharacters: 1_000,
                                           detect: { pages in
            seen = pages
            return "fr"
        })
        XCTAssertEqual(seen.map(\.page), [1, 2])
    }

    /// `--redetect-languages` : la colonne est effacée pour TOUS les documents
    /// extraits, y compris ceux qui portaient déjà une langue — sans quoi les
    /// 62 documents rangés en hongrois ne seraient jamais relus.
    func testReinitialisationDeToutesLesLangues() throws {
        let db = try makeDB()
        try indexed(db, "Users/a/fr.pdf", pages: [page(1, "fr a")], lang: "fr")
        try indexed(db, "Users/a/hu.pdf", pages: [page(1, "en b")], lang: "hu")
        try indexed(db, "Users/a/und.pdf", pages: [page(1, "? c")],
                    lang: FacetKey.undeterminedLanguage)
        // Un document NON extrait n'est candidat à rien.
        let brouillon = try addDoc(db, relPath: "Users/a/brouillon.pdf", lang: "fr")

        XCTAssertEqual(try db.store.documentsWithoutLanguageCount(), 0)
        XCTAssertEqual(try db.store.resetAllLanguages(), 3)
        XCTAssertEqual(try db.store.documentsWithoutLanguageCount(), 3)

        let report = try db.store.backfillLanguages(
            limit: .max, sampleCharacters: 4_000, detect: firstWord)
        XCTAssertEqual(report.scanned, 3)
        XCTAssertEqual(report.counts["fr"], 1)
        XCTAssertEqual(report.counts["en"], 1,
                       "le document rangé en « hu » a bien été rejugé")
        XCTAssertEqual(report.counts[FacetKey.undeterminedLanguage], 1)
        let untouched = try db.store.documentsWithoutLanguage(limit: 10)
        XCTAssertFalse(untouched.contains(brouillon))
    }

    // MARK: - NULL et « und », une seule valeur (facette et filtre)

    func testFacetteEtFiltreVoientNullEtUndDeLaMemeFacon() throws {
        let db = try makeDB()
        // Un document jamais examiné (NULL) et un document rattrapé sans
        // conclusion (« und ») : l'utilisateur ne voit qu'une seule langue
        // « non déterminée », et `--lang und` doit ramener les deux.
        let nul = try indexed(db, "Users/a/nul.pdf", pages: [page(1, "enthalpie ?")])
        let und = try indexed(db, "Users/a/und.pdf", pages: [page(1, "enthalpie ?")],
                              lang: FacetKey.undeterminedLanguage)
        let fr = try indexed(db, "Users/a/fr.pdf", pages: [page(1, "enthalpie libre")],
                             lang: "fr")

        let facets = try db.store.facets(try query("enthalpie"), by: .lang)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: facets),
                       [FacetKey.undeterminedLanguage: 2, "fr": 1],
                       "une seule ligne « und », et non deux")

        var q = try query("enthalpie")
        q.langs = [FacetKey.undeterminedLanguage]
        XCTAssertEqual(Set(try db.store.search(q).hits.map(\.docID)), [nul, und])
        XCTAssertEqual(try db.store.search(q).totalDocs, 2)

        q.langs = ["fr"]
        XCTAssertEqual(try db.store.search(q).hits.map(\.docID), [fr])

        // Le même contrat pour le canal vectoriel, qui ne lit pas ce SQL mais
        // reçoit un ensemble de documents autorisés (lot U2).
        XCTAssertEqual(
            try db.store.docIDsMatching(langs: [FacetKey.undeterminedLanguage],
                                        modifiedAfter: nil),
            [nul, und])
    }

    /// Le rattrapage rejoint la facette : après lui, les documents détectés
    /// quittent « und » sans qu'aucun code d'interface ne change.
    func testApresRattrapageLaFacetteSePeuple() throws {
        let db = try makeDB()
        try indexed(db, "Users/a/fr.pdf", pages: [page(1, "fr enthalpie libre")])
        try indexed(db, "Users/a/en.pdf", pages: [page(1, "en enthalpie free")])
        try indexed(db, "Users/a/court.pdf", pages: [page(1, "? enthalpie")])

        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues:
                        try db.store.facets(try query("enthalpie"), by: .lang)),
            [FacetKey.undeterminedLanguage: 3],
            "avant : une seule valeur, la facette ne dit rien")

        _ = try db.store.backfillLanguages(limit: 100, sampleCharacters: 4_000,
                                           detect: firstWord)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues:
                        try db.store.facets(try query("enthalpie"), by: .lang)),
            ["fr": 1, "en": 1, FacetKey.undeterminedLanguage: 1])
    }

    // MARK: - Relecture après arrivée de texte OCR (PERSP-5)

    /// Un document scanné marqué « und » redevient NULL quand son texte OCR
    /// arrive, puis reçoit sa vraie langue au rattrapage.
    func testDocumentUndDevientNullPuisRattrapeQuandTexteOCREstEcrit() throws {
        let db = try makeDB()
        // Un document scanné : aucune page native, langue posée à « und ».
        let doc = try indexed(db, "Users/a/scan.pdf", pages: [],
                              lang: FacetKey.undeterminedLanguage, nPages: 1)
        XCTAssertEqual(try lang(db, doc), FacetKey.undeterminedLanguage)
        XCTAssertEqual(try db.store.documentsWithoutLanguageCount(), 0,
                       "« und » n'est pas compté dans docs_without_language avant l'OCR")

        // La passe OCR écrit le texte d'une page : dans la même transaction,
        // lang repasse à NULL.
        let text = "fr un texte en francais avec largement assez de caracteres pour etre utile"
        try db.store.completeOCR(docID: doc, page: 1, result: ocrPage(text))

        XCTAssertNil(try lang(db, doc),
                     "lang est remise à NULL par completeOCR : le document redevient candidat")
        XCTAssertEqual(try db.store.documentsWithoutLanguageCount(), 1,
                       "status.docs_without_language reflète immédiatement le document à rattraper")
        XCTAssertEqual(try db.store.documentsWithoutLanguage(limit: 10), [doc])

        // Le rattrapage s'exécute : la langue est détectée.
        let report = try db.store.backfillLanguages(
            limit: 100, sampleCharacters: 4_000, detect: firstWord)
        XCTAssertEqual(report.scanned, 1)
        XCTAssertEqual(report.determined, 1)
        XCTAssertEqual(try lang(db, doc), "fr")
        XCTAssertEqual(try db.store.documentsWithoutLanguageCount(), 0,
                       "après rattrapage, docs_without_language revient à 0")
    }

    /// Un document dont la langue a déjà été reconnue (« fr ») ne change pas
    /// quand une page OCR arrive.
    func testDocumentDejaFrNeChangePasQuandTexteOCREstEcrit() throws {
        let db = try makeDB()
        let doc = try indexed(db, "Users/a/deja_fr.pdf", pages: [page(1, "fr texte natif")],
                              lang: "fr", nPages: 2)
        XCTAssertEqual(try lang(db, doc), "fr")

        // L'OCR d'une autre page écrit du texte : lang ne doit PAS être remise à NULL.
        let text = "en some english text from OCR which should not override document language"
        try db.store.completeOCR(docID: doc, page: 2, result: ocrPage(text))

        XCTAssertEqual(try lang(db, doc), "fr",
                       "un document dont la langue est déjà déterminée reste inchangé")
        XCTAssertEqual(try db.store.documentsWithoutLanguageCount(), 0)
    }

    /// Un document « und » dont le texte OCR reste indéterminable (trop court,
    /// charabia) redevient « und » et n'est plus relu aux passes suivantes.
    func testDocumentUndResteUndSiTexteOCRIndeterminableEtNeBouclePas() throws {
        let db = try makeDB()
        let doc = try indexed(db, "Users/a/charabia.pdf", pages: [],
                              lang: FacetKey.undeterminedLanguage, nPages: 1)
        XCTAssertEqual(try db.store.documentsWithoutLanguageCount(), 0)

        // Texte OCR écrit (>= 20 caractères), mais la détection ne conclut pas ("?").
        let text = "? du bruit et des symboles sans langue reconnaissable 123456789"
        try db.store.completeOCR(docID: doc, page: 1, result: ocrPage(text))

        XCTAssertNil(try lang(db, doc), "lang est bien remise à NULL à l'écriture")
        XCTAssertEqual(try db.store.documentsWithoutLanguageCount(), 1)

        // Premier rattrapage : la détection ne conclut pas (firstWord retourne nil pour "?").
        let report = try db.store.backfillLanguages(
            limit: 100, sampleCharacters: 4_000, detect: firstWord)
        XCTAssertEqual(report.scanned, 1)
        XCTAssertEqual(report.determined, 0)
        XCTAssertEqual(try lang(db, doc), FacetKey.undeterminedLanguage,
                       "le document redevient « und »")
        XCTAssertEqual(try db.store.documentsWithoutLanguageCount(), 0,
                       "docs_without_language revient à 0")

        // Passe suivante : il n'est PLUS relu (idempotence).
        let second = try db.store.backfillLanguages(
            limit: 100, sampleCharacters: 4_000, detect: firstWord)
        XCTAssertEqual(second.scanned, 0,
                       "aucun document n'est relu à la passe suivante")
        XCTAssertEqual(try db.store.documentsWithoutLanguage(limit: 10), [])
    }

    /// Test unitaire direct de la méthode resetLanguageIfUndetermined.
    func testResetLanguageIfUndeterminedDirectement() throws {
        let db = try makeDB()
        let und = try indexed(db, "Users/a/und.pdf", pages: [page(1, "texte")],
                              lang: FacetKey.undeterminedLanguage)
        let empty = try indexed(db, "Users/a/empty.pdf", pages: [page(1, "texte")],
                                lang: "")
        let fr = try indexed(db, "Users/a/fr.pdf", pages: [page(1, "texte")],
                             lang: "fr")
        let nilDoc = try indexed(db, "Users/a/nil.pdf", pages: [page(1, "texte")],
                                 lang: nil)

        // « und » est réinitialisé à NULL
        XCTAssertTrue(try db.store.resetLanguageIfUndetermined(docID: und))
        XCTAssertNil(try lang(db, und))

        // « » (vide) est réinitialisé à NULL
        XCTAssertTrue(try db.store.resetLanguageIfUndetermined(docID: empty))
        XCTAssertNil(try lang(db, empty))

        // « fr » n'est pas touché
        XCTAssertFalse(try db.store.resetLanguageIfUndetermined(docID: fr))
        XCTAssertEqual(try lang(db, fr), "fr")

        // Déjà NULL : aucun changement
        XCTAssertFalse(try db.store.resetLanguageIfUndetermined(docID: nilDoc))
        XCTAssertNil(try lang(db, nilDoc))
    }

    private func lang(_ db: TempDB, _ id: Int64) throws -> String? {
        try db.store.docRow(id: id)?.record.lang
    }
}
