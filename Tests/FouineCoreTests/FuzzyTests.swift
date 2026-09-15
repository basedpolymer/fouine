// FuzzyTests.swift — expansion floue (SPEC §5.5.2, §5.5.3 ; T13, T14, T15, P8).
// Propriété : A-Core.

import XCTest
@testable import FouineCore

extension FuzzyTests {

    /// LE PLAFOND DÉPEND DE LA PORTÉE (lot MC1). En portée `ocr`, deux
    /// éditions sur six lettres restent une faute de MACHINE (« rn » lu
    /// « m ») ; en repli sur tout l'index, ce sont les fautes de frappe de
    /// l'utilisateur, et `Kenvue` y trouvait « Kenne ».
    func testDistanceCeilingDependsOnScope() throws {
        XCTAssertEqual(TrigramExpander.maxDistance(for: "Kenvue", scope: .ocrOnly), 2)
        XCTAssertEqual(TrigramExpander.maxDistance(for: "Kenvue", scope: .all), 1)
        XCTAssertEqual(TrigramExpander.maxDistance(for: "polymere", scope: .all), 1,
                       "huit lettres : une seule édition")
        XCTAssertEqual(TrigramExpander.maxDistance(for: "enthalpie", scope: .all), 2,
                       "neuf lettres : deux éditions restent plausibles")
        XCTAssertEqual(TrigramExpander.maxDistance(for: "Villeurbane", scope: .all), 2)
    }

    /// L'EXPANSION ORDINAIRE SE DIT (lot MC1, PM-13). `fuzzyFallback` ne
    /// couvre que le REPLI ; en mode `auto`, l'élargissement a lieu dans la
    /// passe normale et rien ne l'annonçait.
    func testFuzzyExpandedIsTrueOutsideAnyFallback() throws {
        let db = try makeDB()
        _ = try mixedCorpus(db)
        let widened = try db.store.search(try query("converslon", fuzzy: .on))
        XCTAssertGreaterThan(widened.totalPages, 0)
        XCTAssertTrue(widened.fuzzyExpanded, "des résultats portent une "
                      + "orthographe proche, sans aucun repli")
        XCTAssertFalse(widened.fuzzyFallback)
        let exact = try db.store.search(try query("conversion", fuzzy: .off))
        XCTAssertGreaterThan(exact.totalPages, 0)
        XCTAssertFalse(exact.fuzzyExpanded)
    }
}

final class FuzzyTests: XCTestCase {

    // MARK: - Levenshtein

    func testLevenshteinWithEarlyAbandon() {
        var scratch = LevenshteinScratch(capacity: 32)
        func d(_ a: String, _ b: String, _ maxD: Int = 2) -> Int? {
            scratch.distance(Array(a.unicodeScalars.map(\.value)),
                             Array(b.unicodeScalars.map(\.value)), maxDistance: maxD)
        }
        XCTAssertEqual(d("conversion", "conversion"), 0)
        XCTAssertEqual(d("conversion", "converslon"), 1)   // substitution
        XCTAssertEqual(d("equilibre", "lequilibre"), 1)    // insertion
        XCTAssertEqual(d("volume", "volue"), 1)            // suppression
        XCTAssertEqual(d("enthalpie", "estholpie"), 2)
        XCTAssertEqual(d("application", "applicabian"), 2)
        XCTAssertNil(d("relation", "retorion"), "d = 3 : abandonné (§5.5.2)")
        XCTAssertNil(d("joule", "jarla"))
        XCTAssertEqual(d("mayer", "bayer"), 1)
    }

    // MARK: - Sondes (stratégie corrigée, bogue 3 de la recette)

    /// Deux sondes disjointes qui COUVRENT le terme : moitié-préfixe ⌈n/2⌉
    /// (« commence par », B-tree vocab_seen) + moitié-suffixe (« contient »,
    /// trigramme, donc ≥ 3 caractères). Une édition n'en touche qu'une :
    /// d = 1 entièrement garanti, d = 2 dès que les deux éditions tombent
    /// dans la même moitié.
    func testProbesAreTwoDisjointCoveringHalves() {
        for term in ["volume", "polymer", "polymere", "conversion", "applicabian",
                     "lequilibre", "estholpie", "chromatographie"] {
            let (prefix, suffix) = TrigramExpander.probes(for: term)
            XCTAssertEqual(prefix + suffix, term,
                           "\(term) : les sondes doivent couvrir le terme")
            XCTAssertGreaterThanOrEqual(suffix.count, 3,
                "\(term) : la sonde trigramme doit faire ≥ 3 caractères")
            XCTAssertGreaterThanOrEqual(prefix.count, suffix.count,
                "\(term) : la coupe est à ⌈n/2⌉")
        }
        // La coupe ⌈n/2⌉ donne à `enthalpie` la sonde « lpie » — celle qui
        // rattrape `estholpie` (§5.5.2).
        XCTAssertEqual(TrigramExpander.probes(for: "enthalpie").suffix, "lpie")
        XCTAssertEqual(TrigramExpander.probes(for: "estholpie").prefix, "estho")
    }

    func testRangeUpperBoundBumpsTheLastScalar() {
        XCTAssertEqual(TrigramExpander.rangeUpperBound(after: "poly"), "polz")
        XCTAssertEqual(TrigramExpander.rangeUpperBound(after: "entha"), "enthb")
        XCTAssertEqual(TrigramExpander.rangeUpperBound(after: "a"), "b")
    }

    /// Les cas de rappel du §5.5.2 passent par les nouvelles sondes : la
    /// moitié-préfixe rattrape les éditions de fin, la moitié-suffixe les
    /// éditions de tête (dont `estholpie`, ses deux éditions étant dans
    /// « estho »/« entha »).
    func testSpecRecallCasesSurviveTheNewProbes() throws {
        let db = try makeDB()
        let expander = try seededVocabulary(db)
        let estholpie = try expander.expand("estholpie", cap: 20)
        XCTAssertEqual(estholpie.first { $0.term == "enthalpie" }?.distance, 2,
                       "enthalpie ← estholpie (d2, sonde « lpie ») perdu")
        let volume = try expander.expand("volute", cap: 20)
        XCTAssertEqual(volume.first { $0.term == "volume" }?.distance, 1,
                       "volume ← volute (d1) perdu")
        let equilibre = try expander.expand("lequilibre", cap: 20)
        XCTAssertEqual(equilibre.first { $0.term == "equilibre" }?.distance, 1,
                       "equilibre ← lequilibre (d1) perdu")
    }

    // MARK: - T15 : d = 0 sous 6 lettres

    func testShortTermsAreNeverExpanded() throws {
        let db = try makeDB()
        let expander = try seededVocabulary(db)
        for short in ["mayer", "gibbs", "azote"] {
            let neighbours = try expander.expand(short, cap: 20)
            XCTAssertEqual(neighbours.count, 1, "\(short) : 5 lettres -> d = 0 (T15)")
            XCTAssertEqual(neighbours[0].term, short)
            XCTAssertEqual(neighbours[0].distance, 0)
        }
    }

    func testSixLetterTermsAreExpanded() throws {
        let db = try makeDB()
        let expander = try seededVocabulary(db)
        let neighbours = try expander.expand("enthalpie", cap: 20)
        XCTAssertEqual(neighbours.first?.term, "enthalpie")
        XCTAssertEqual(neighbours.first?.distance, 0)
        let terms = Set(neighbours.map(\.term))
        XCTAssertTrue(terms.contains("enthalpies"), "voisin d1 attendu")
        XCTAssertTrue(neighbours.allSatisfy { $0.distance <= 2 })
        XCTAssertEqual(neighbours.map(\.distance), neighbours.map(\.distance).sorted())
    }

    func testSubstitutionInTheMiddleIsFound() throws {
        let db = try makeDB()
        let expander = try seededVocabulary(db)
        // Le MATCH trigramme du terme ENTIER ne trouve rien ici : ce sont les
        // sondes par blocs qui ramènent « conversion » (voir l'en-tête du module).
        let neighbours = try expander.expand("converslon", cap: 20)
        let found = neighbours.first { $0.term == "conversion" }
        XCTAssertEqual(found?.distance, 1)
    }

    func testWarmIsIdempotent() throws {
        let db = try makeDB()
        _ = try seededVocabulary(db)
        let first = try db.store.rawInt64s("SELECT count(*) FROM vocab_tri")[0]
        try TrigramExpander(store: db.store).warm()
        let second = try db.store.rawInt64s("SELECT count(*) FROM vocab_tri")[0]
        XCTAssertEqual(first, second)
        XCTAssertGreaterThan(first, 0)
    }

    // MARK: - T13 : la page OCR bruitée redevient trouvable

    func testFuzzyOnFindsTheNoisyOCRPageWithDistanceOne() throws {
        let db = try makeDB()
        let (_, ocrDoc) = try mixedCorpus(db)

        let off = try db.store.search(try query("converslon", fuzzy: .off))
        XCTAssertEqual(off.totalPages, 0, "T13 : --fuzzy off -> 0 résultat")

        let on = try db.store.search(try query("converslon", fuzzy: .on))
        XCTAssertEqual(on.totalPages, 1)
        let hit = try XCTUnwrap(on.hits.first)
        XCTAssertEqual(hit.docID, ocrDoc)
        XCTAssertEqual(hit.fuzzyDistance, 1)
        XCTAssertEqual(hit.source, .ocrAccurate)
        XCTAssertFalse(hit.snippet.isEmpty)
    }

    func testFuzzyScopeOCROnlyLeavesNativePagesAlone() throws {
        let db = try makeDB()
        let (nativeDoc, ocrDoc) = try mixedCorpus(db)

        let scoped = try db.store.search(try query("converslon", fuzzy: .on,
                                                   scope: .ocrOnly))
        XCTAssertEqual(scoped.hits.map(\.docID), [ocrDoc],
                       "portée ocr : une page native ne sort JAMAIS par le flou")

        let everywhere = try db.store.search(try query("converslon", fuzzy: .on,
                                                       scope: .all))
        XCTAssertEqual(Set(everywhere.hits.map(\.docID)), [nativeDoc, ocrDoc])
    }

    // MARK: - T14 : déduplication, exacts devant, pénalité 1/(1+d)

    func testExactMatchesComeFirstAndPagesAreNeverDuplicated() throws {
        let db = try makeDB()
        let docID = try addDoc(db, relPath: "Users/alice/Cours/ocr.pdf", folder: "Cours")
        // Page 1 : contient le terme EXACT et un voisin -> matche les deux branches.
        // Le voisin est une COQUILLE d'OCR (« polymrre »), pas le pluriel : depuis
        // le lot R1, « polymeres » est une forme exacte du mot (Morphology).
        try db.store.completeOCR(docID: docID, page: 1, result: ocrPage(
            "le polymere et les polymrre forment une chaine macromoleculaire"))
        // Page 2 : ne contient QUE le voisin à distance 1.
        try db.store.completeOCR(docID: docID, page: 2, result: ocrPage(
            "les polymrre thermodurcissables et leur reticulation chimique"))
        try TrigramExpander(store: db.store).warm()

        let results = try db.store.search(try query("polymere", fuzzy: .on))
        XCTAssertEqual(results.hits.count, 2)
        XCTAssertEqual(results.totalPages, 2, "T14 : aucune page en double")
        XCTAssertEqual(results.hits.map(\.page), [1, 2],
                       "la page exacte 1 a aussi un meilleur score bm25")
        XCTAssertEqual(results.hits[0].fuzzyDistance, 0)
        XCTAssertEqual(results.hits[1].fuzzyDistance, 1)

        // Pénalité : le score de la page floue est celui de bm25 divisé par 1 + d.
        // La sonde « forme tapée » (lot P1) est désarmée sur le TÉMOIN, et sur
        // lui seul : la page 2 ne porte pas « polymere » et ne la reçoit donc
        // pas dans la recherche ci-dessus, mais elle porte « polymrre » et la
        // recevrait ici — on comparerait un score nu à un score bonifié.
        var control = try query("polymrre", fuzzy: .off)
        control.typedFormBoost = false
        let exactOnly = try db.store.search(control)
        let rawPage2 = try XCTUnwrap(exactOnly.hits.first { $0.page == 2 }).score
        XCTAssertEqual(results.hits[1].score, rawPage2 / 2.0, accuracy: 1e-9)
    }

    /// D-R1 : une page trouvée par flou (d = 1) avec un bon score bm25 bat une
    /// page exacte faible. L'ancien tri ORDER BY fz ASC, r ASC faisait passer
    /// toute page exacte devant, quelle que soit sa qualité.
    func testFuzzyHitWithBetterScoreBeatsWeakerExactHit() throws {
        let db = try makeDB()
        let docID = try addDoc(db, relPath: "Users/alice/Cours/scores.pdf", folder: "Cours")
        // Page 1 : correspondance exacte mais très diluée (faible bm25, proche de 0).
        let filler = (1...60).map { "mot\($0)" }.joined(separator: " ")
        try db.store.completeOCR(docID: docID, page: 1, result: ocrPage(
            "\(filler) polymere \(filler)"))
        // Page 2 : correspondance floue dense (coquille d=1 répétée sur document
        // court — pas le pluriel, forme exacte depuis le lot R1).
        try db.store.completeOCR(docID: docID, page: 2, result: ocrPage(
            "polymrre polymrre polymrre polymrre polymrre polymrre"))
        try TrigramExpander(store: db.store).warm()

        // D-R1 se juge sur bm25 NU : la sonde « forme tapée » du lot P1 est
        // désarmée ici, et le cas suivant dit ce qu'elle change.
        var plain = try query("polymere", fuzzy: .on)
        plain.typedFormBoost = false
        let results = try db.store.search(plain)
        XCTAssertEqual(results.hits.count, 2)
        // La page 2 (d=1, score divisé par 2 mais très négatif) doit battre la page 1 (exacte mais faible).
        XCTAssertEqual(results.hits[0].page, 2, "La page floue très pertinente doit battre la page exacte faible")
        XCTAssertEqual(results.hits[0].fuzzyDistance, 1)
        XCTAssertEqual(results.hits[1].page, 1)
        XCTAssertEqual(results.hits[1].fuzzyDistance, 0)
        XCTAssertLessThan(results.hits[0].score, results.hits[1].score, "Score de p2 plus négatif que p1")

        // CE QUE LE LOT P1 CHANGE, et il faut le dire : la sonde « forme tapée »
        // vaut × 1,5, la pénalité floue × 0,5. Sur ce cas limite — où la page
        // floue ne gagnait que d'un facteur 1,42 après pénalité — la page qui
        // porte le mot TAPÉ repasse devant. Il faut désormais un bm25 plus de
        // trois fois meilleur pour qu'une coquille d'OCR gagne ; D-R1 tient
        // toujours (il n'y a pas de barrière, seulement un facteur), mais la
        // calibration a bougé. `--no-typed-form` rend l'ordre ci-dessus.
        let boosted = try db.store.search(try query("polymere", fuzzy: .on))
        XCTAssertEqual(boosted.hits.map(\.page), [1, 2])
    }

    /// D-R4 : calcul du pourcentage de pertinence (meilleur = 100 %, monotone, borné).
    func testRelevancePercentageCalculation() {
        let best = -8.0
        func pct(_ score: Double) -> Int {
            guard best < 0, score <= 0 else { return 100 }
            let ratio = 100.0 * (score / best)
            return max(0, min(100, Int(round(ratio))))
        }
        XCTAssertEqual(pct(-8.0), 100, "Le meilleur hit vaut 100 %")
        XCTAssertEqual(pct(-4.0), 50, "La moitié du score vaut 50 %")
        XCTAssertEqual(pct(-2.0), 25, "Le quart du score vaut 25 %")
        XCTAssertEqual(pct(0.0), 0, "Score nul vaut 0 %")
        // Monotonie : pour des scores de plus en plus faibles (plus proches de 0), pct diminue
        let scores = [-8.0, -7.0, -5.5, -4.0, -2.0, -1.0, 0.0]
        let pcts = scores.map(pct)
        XCTAssertEqual(pcts, pcts.sorted(by: >), "Les pourcentages doivent décroître de façon monotone")
        XCTAssertTrue(pcts.allSatisfy { (0...100).contains($0) }, "Tous les pourcentages sont dans [0, 100]")
    }

    func testAutoModeOnlyExpandsWhenTheExactQueryIsThin() throws {
        let db = try makeDB()
        let docID = try addDoc(db, relPath: "Users/alice/Cours/auto.pdf", folder: "Cours")
        // 25 pages OCR contenant le terme exact : au-dessus du seuil de 20.
        for p in 1...25 {
            try db.store.completeOCR(docID: docID, page: p, result: ocrPage(
                "page \(p) : le polymere etudie ici est un polyester courant"))
        }
        // Une coquille (« polymrre »), pas le pluriel : « polymeres » est une
        // forme exacte du mot depuis le lot R1 et compterait dans les 25.
        try db.store.completeOCR(docID: docID, page: 26, result: ocrPage(
            "la polymrre seule, sans le terme exact, sur cette page-ci"))
        try TrigramExpander(store: db.store).warm()

        let auto = try db.store.search(try query("polymere", limit: 100, fuzzy: .auto))
        XCTAssertEqual(auto.totalPages, 25,
                       "auto : 25 ≥ 20 pages exactes -> aucune expansion (§5.5.2)")
        let forced = try db.store.search(try query("polymere", limit: 100, fuzzy: .on))
        XCTAssertEqual(forced.totalPages, 26)
        // Amendement D-R1 : le tri est par score scalaire r_final et non plus fz ASC.
        XCTAssertEqual(forced.hits.filter { $0.fuzzyDistance == 0 }.count, 25)
        XCTAssertEqual(forced.hits.filter { $0.fuzzyDistance == 1 }.count, 1)
        let scores = forced.hits.map(\.score)
        XCTAssertEqual(scores, scores.sorted(), "les scores doivent être croissants")
    }

    func testAutoModeExpandsBelowTheThreshold() throws {
        let db = try makeDB()
        let (_, _) = try mixedCorpus(db)
        let auto = try db.store.search(try query("converslon", fuzzy: .auto))
        XCTAssertEqual(auto.totalPages, 1, "0 page exacte < 20 -> expansion déclenchée")
        XCTAssertEqual(auto.hits.first?.fuzzyDistance, 1)
    }

    /// Les totaux voyagent avec les lignes de résultat ; une page vide n'en
    /// portant aucune, ils doivent rester ceux du jeu complet.
    func testTotalsSurviveAnOffsetPastTheLastFuzzyHit() throws {
        let db = try makeDB()
        _ = try mixedCorpus(db)
        var q = try query("converslon", fuzzy: .on)
        q.offset = 1
        let past = try db.store.search(q)
        XCTAssertTrue(past.hits.isEmpty)
        XCTAssertEqual(past.totalPages, 1)
        XCTAssertEqual(past.totalDocs, 1)
    }

    func testFuzzyOffNeverExpands() throws {
        let db = try makeDB()
        _ = try mixedCorpus(db)
        XCTAssertEqual(try db.store.search(try query("converslon", fuzzy: .off))
                        .totalPages, 0)
    }

    // MARK: - Budget (P8)

    /// LE BUDGET P8 (§5.5.2), prouvé par un RAPPORT et non par une horloge.
    ///
    /// Ce qui tient la promesse « ≤ 10 ms par terme » n'est pas la vitesse de
    /// la machine : c'est le PLAFOND DE CANDIDATS des deux sondes, qui fait que
    /// le coût ne suit PAS la taille du vocabulaire. Un seuil en millisecondes
    /// mesurait donc la charge de la machine autant que le code — 2,76 s
    /// relevées sous une autre compilation pour un seuil de 10 ms, sans qu'une
    /// ligne ait changé (lot BT1). On mesure donc la MÊME expansion sur 20
    /// termes puis sur 20 020, dans le même test et sous la même charge.
    func testExpansionDoesNotFollowTheVocabularySize() throws {
        let db = try makeDB()
        let expander = try seededVocabulary(db)
        let small = try medianExpansionMS(expander)
        try addSyntheticNoise(db, terms: 20_000)
        try expander.warm()
        let big = try medianExpansionMS(expander)

        // Facteur 10 et 3 ms de plancher : le vocabulaire est mille fois plus
        // gros, la profondeur du B-tree change et la mesure porte sur des
        // fractions de milliseconde. Une expansion redevenue linéaire, elle,
        // rendrait un rapport de plusieurs dizaines.
        XCTAssertLessThan(big, small * 10 + 3,
                          "expansion : \(small) ms sur 20 termes, \(big) ms sur "
                          + "20 020 — le coût suit la taille du vocabulaire")
        // Garde-fou absolu, très large : il ne prouve pas le budget (la charge
        // de la machine le rendrait faux), il attrape un effondrement.
        XCTAssertLessThan(big, 500, "\(big) ms pour une expansion")
    }

    /// Médiane de trois passes : une seule mesure attrape n'importe quel
    /// hoquet d'ordonnancement.
    private func medianExpansionMS(_ expander: TrigramExpander) throws -> Double {
        var samples: [Double] = []
        for _ in 0..<3 {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try expander.expand("enthalpie", cap: 12)
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start)
                           / 1_000_000)
        }
        return samples.sorted()[1]
    }

    // MARK: - Corpus de test

    /// Une page NATIVE et une page OCR contenant toutes deux « conversion ».
    private func mixedCorpus(_ db: TempDB) throws -> (native: Int64, ocr: Int64) {
        let nativeDoc = try addDoc(db, relPath: "Users/alice/Livres/natif.pdf")
        try db.store.replacePages(docID: nativeDoc, pages: [
            page(1, "le taux de conversion est defini par le rapport des debits"),
        ])
        let ocrDoc = try addDoc(db, relPath: "Users/alice/Cours/scan.pdf",
                                folder: "Cours")
        try db.store.completeOCR(docID: ocrDoc, page: 1, result: ocrPage(
            "Connaissant le taux de conversion et le temps de passage du reacteur"))
        try TrigramExpander(store: db.store).warm()
        return (nativeDoc, ocrDoc)
    }

    @discardableResult
    private func seededVocabulary(_ db: TempDB) throws -> TrigramExpander {
        let docID = try addDoc(db, relPath: "Users/alice/Livres/vocabulaire.pdf")
        let pages = [page(1, """
            enthalpie enthalpies enthalpique enthalpy conversion conversions
            application applications volume volumes equilibre equilibres
            mayer bayer layer gibbs azote polymere polymeres polymer
            """)]
        try db.store.replacePages(docID: docID, pages: pages)
        let expander = TrigramExpander(store: db.store)
        try expander.warm()
        return expander
    }

    /// 20 000 termes synthétiques, dans un document à part et APRÈS coup : le
    /// budget P8 se mesure sur les deux tailles de vocabulaire, l'une puis
    /// l'autre, dans une seule base.
    private func addSyntheticNoise(_ db: TempDB, terms: Int) throws {
        let docID = try addDoc(db, relPath: "Users/alice/Livres/bruit.pdf")
        var pages = [page(1, "bruit synthetique du budget P8")]
        var noise: [String] = []
        noise.reserveCapacity(terms)
        for i in 0..<terms { noise.append("terme\(i)synthetique") }
        for chunk in stride(from: 0, to: terms, by: 1_000) {
            let slice = noise[chunk..<min(chunk + 1_000, terms)]
            pages.append(page(pages.count + 1, slice.joined(separator: " ")))
        }
        try db.store.replacePages(docID: docID, pages: pages)
    }
}
