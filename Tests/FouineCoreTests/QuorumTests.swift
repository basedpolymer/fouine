// QuorumTests.swift — le quorum des mots (lot RK2, constat RK-04).
// Propriété : A-Core.
//
// Ce que ces tests prouvent : l'expression relâchée est exactement celle qu'on
// croit (les combinaisons, et les mots courts jamais exigés), les requêtes qui
// doivent rester strictes le restent, et le quorum ne s'allume que sous le
// seuil et seulement s'il apporte quelque chose.

import XCTest
@testable import FouineCore

final class QuorumTests: XCTestCase {

    // MARK: - L'expression

    /// Trois mots longs : k = ⌈0,6 × 3⌉ = 2, donc les trois paires.
    func testThreeWordsAskForTwoOfThem() throws {
        XCTAssertEqual(
            QueryParser.quorumFTS(terms: ["chaleur", "degagee", "reaction"]),
            "(chaleur AND degagee) OR (chaleur AND reaction) OR (degagee AND reaction)")
    }

    /// Quatre mots : k = ⌈2,4⌉ = 3, donc C(4,3) = 4 groupes de trois.
    func testFourWordsAskForThreeOfThem() throws {
        let expression = QueryParser.quorumFTS(
            terms: ["mesurer", "chaleur", "degagee", "reaction"])
        XCTAssertEqual(expression?.components(separatedBy: " OR ").count, 4)
        XCTAssertEqual(expression,
                       "(mesurer AND chaleur AND degagee) OR "
                       + "(mesurer AND chaleur AND reaction) OR "
                       + "(mesurer AND degagee AND reaction) OR "
                       + "(chaleur AND degagee AND reaction)")
    }

    /// Cinq mots : k = 3, C(5,3) = 10 groupes — et chaque mot est dans six
    /// d'entre eux.
    ///
    /// « comment » ne compte plus depuis le lot MC1 : c'est un mot vide de
    /// question, et une question en langage naturel commence par lui.
    func testFiveWordsGiveTenGroups() throws {
        let words = ["mesurer", "chaleur", "degagee", "reaction", "enthalpie"]
        let expression = try XCTUnwrap(
            QueryParser.quorumFTS(terms: ["comment"] + words))
        let groups = expression.components(separatedBy: " OR ")
        XCTAssertEqual(groups.count, 10)
        XCTAssertFalse(expression.contains("comment"))
        for word in words {
            XCTAssertEqual(groups.filter { $0.contains(word) }.count, 6,
                           "chaque mot apparaît dans C(4,2) = 6 groupes")
        }
    }

    /// LE CAS DE RK-04. « la », « par » et « une » ne sont JAMAIS exigés : ce
    /// sont eux qui font échouer le ET strict, et aucune page ne les porte tous
    /// avec le reste.
    func testShortWordsAreNeverRequired() throws {
        let expression = try XCTUnwrap(QueryParser.quorumFTS(terms: [
            "comment", "mesurer", "la", "chaleur", "degagee", "par", "une",
            "reaction", "enthalpie",
        ]))
        for filler in [" la ", " par ", " une "] {
            XCTAssertFalse(expression.contains(filler),
                           "« \(filler.trimmingCharacters(in: .whitespaces)) » ne "
                           + "doit être exigé par aucun groupe")
        }
        // Restent les cinq mots porteurs (« comment » est un mot vide depuis
        // le lot MC1), donc les mêmes dix groupes qu'au-dessus.
        XCTAssertEqual(expression.components(separatedBy: " OR ").count, 10)
    }

    /// Moins de trois mots LONGS : rien à relâcher. « gaz » et « eau » sont
    /// courts, c'est le prix du seuil de quatre lettres.
    func testFewerThanThreeLongWordsHaveNoQuorum() throws {
        XCTAssertNil(QueryParser.quorumFTS(terms: ["energie", "libre"]))
        XCTAssertNil(QueryParser.quorumFTS(terms: ["le", "gaz", "parfait"]))
    }

    /// Au-delà de six mots longs, ce sont les six PLUS LONGS qui sont exigés
    /// (lot MC1) — et non plus « pas de quorum du tout ». L'énumération reste
    /// bornée à C(6,4) = 15 groupes, et une question de huit mots cesse de
    /// rendre zéro page.
    func testMoreThanSixLongWordsKeepTheLongestSix() throws {
        let six = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta"]
        XCTAssertEqual(QueryParser.quorumFTS(terms: six)?
                        .components(separatedBy: " OR ").count, 15,
                       "six mots, k = 4 : C(6,4) = 15 groupes")
        let expression = try XCTUnwrap(
            QueryParser.quorumFTS(terms: six + ["theta"]))
        XCTAssertEqual(expression.components(separatedBy: " OR ").count, 15,
                       "sept mots : les six plus longs, donc encore 15 groupes")
        XCTAssertFalse(expression.contains("zeta"),
                       "à longueur égale, l'ordre tapé tranche : « beta » "
                       + "précède « zeta », c'est donc « zeta » qui saute")
        for word in ["alpha", "beta", "gamma", "delta", "epsilon", "theta"] {
            XCTAssertTrue(expression.contains(word), word)
        }
    }

    /// LE CAS DU 13/09/2026, huit mots dont quatre vides. Il en reste quatre
    /// porteurs, k = 3 : la question rend enfin des pages.
    func testStopwordsAreNeverRequired() throws {
        let words = ["distribution", "des", "temps", "sejour", "dans",
                     "reacteur", "reel"]
        let expression = try XCTUnwrap(QueryParser.quorumFTS(terms: words))
        XCTAssertFalse(expression.contains("dans"),
                       "« dans » fait quatre lettres et ne dit rien")
        for word in ["distribution", "temps", "sejour", "reacteur"] {
            XCTAssertTrue(expression.contains(word), word)
        }
        // L'accent ne change rien : la comparaison se fait sur la forme
        // repliée, comme le tokenizer (`remove_diacritics 2`).
        let accented = try XCTUnwrap(QueryParser.quorumFTS(
            terms: ["réacteur", "être", "distribution", "séjour"]))
        XCTAssertFalse(accented.contains("être"))
        // Trois mots porteurs au moins : « cette page avec » n'en laisse aucun.
        XCTAssertNil(QueryParser.quorumFTS(terms: ["cette", "avec", "pour", "sans"]))
    }

    /// Un mot à caractère spécial part échappé, comme partout ailleurs.
    func testSpecialCharactersAreEscaped() throws {
        let expression = try XCTUnwrap(
            QueryParser.quorumFTS(terms: ["alpha-beta", "gamma", "delta"]))
        XCTAssertTrue(expression.contains("\"alpha-beta\""))
    }

    // MARK: - Ce qui y a droit

    private func eligible(_ input: String, strictPages: Int = 0,
                          arm: Bool = true) throws -> String? {
        var q = try query(input)
        q.quorum = arm
        return GRDBStore.quorumExpression(for: q, strictPages: strictPages,
                                          negative: nil)
    }

    func testDisarmedByDefault() throws {
        XCTAssertNil(try eligible("chaleur degagee reaction", arm: false))
        XCTAssertNotNil(try eligible("chaleur degagee reaction"))
    }

    /// Au-dessus du seuil, la recherche stricte suffit : rien ne se relâche, et
    /// aucune requête de plus n'est payée.
    func testEnoughStrictPagesMeansNoQuorum() throws {
        XCTAssertNil(try eligible("chaleur degagee reaction",
                                  strictPages: Schema.quorumTrigger))
        XCTAssertNotNil(try eligible("chaleur degagee reaction",
                                     strictPages: Schema.quorumTrigger - 1))
    }

    /// L'utilisateur a dit lui-même ce qu'il voulait : on ne le relâche pas.
    func testExplicitQueriesStayStrict() throws {
        XCTAssertNil(try eligible("\"chaleur degagee\" reaction mesurer"))
        XCTAssertNil(try eligible("chaleur degagee spectro*"))
        XCTAssertNil(try eligible("pres:5 chaleur degagee reaction"))
        XCTAssertNil(try eligible("chaleur degagee"), "deux mots : rien à relâcher")
    }

    /// Une EXCLUSION reste stricte : l'utilisateur a écarté quelque chose, et
    /// relâcher le ET lui rendrait des pages qu'il a refusées.
    func testExclusionStaysStrict() throws {
        let (q, negative) = try QueryParser.searchPlan("chaleur degagee reaction -biologie")
        var armed = q
        armed.quorum = true
        XCTAssertNil(GRDBStore.quorumExpression(for: armed, strictPages: 0,
                                                negative: negative))
    }

    /// UNE REQUÊTE FILTRÉE Y A DROIT depuis le lot MC1 (PM-11). Un filtre
    /// restreint le corpus ; il ne dit rien de l'exigence sur les mots, et
    /// c'est justement dans un dossier que le ET de neuf mots échoue.
    func testFilteredQueriesGetTheQuorumToo() throws {
        for input in ["ext:pdf chaleur degagee reaction",
                      "dossier:Livres chaleur degagee reaction",
                      "chaleur degagee reaction -ext:md"] {
            var filtered = try query(input)
            filtered.quorum = true
            XCTAssertNotNil(GRDBStore.quorumExpression(for: filtered, strictPages: 0,
                                                       negative: nil), input)
        }
        var restricted = try query("chaleur degagee reaction", inDocIDs: [1])
        restricted.quorum = true
        XCTAssertNotNil(GRDBStore.quorumExpression(for: restricted, strictPages: 0,
                                                   negative: nil))
        var dated = try query("chaleur degagee reaction")
        dated.quorum = true
        dated.modifiedAfter = 1_600_000_000
        dated.langs = ["fr"]
        XCTAssertNotNil(GRDBStore.quorumExpression(for: dated, strictPages: 0,
                                                   negative: nil))
    }

    /// DEUX GARDES RESTENT. `nom:` pose une question sur les documents, et un
    /// filtre de PROVENANCE change le sens de la demande.
    func testNameFilterAndSourceFilterStayStrict() throws {
        var named = try query("nom:rapport chaleur degagee reaction")
        named.quorum = true
        XCTAssertNil(GRDBStore.quorumExpression(for: named, strictPages: 0,
                                                negative: nil))
        var scanned = try query("chaleur degagee reaction")
        scanned.quorum = true
        scanned.sources = PageSource.scanned
        XCTAssertNil(GRDBStore.quorumExpression(for: scanned, strictPages: 0,
                                                negative: nil))
    }

    /// LA QUESTION DU 13/09/2026, DE BOUT EN BOUT. Neuf mots, un `dossier:` :
    /// le ET strict ne rend rien, le quorum rend la page qui porte les mots
    /// porteurs — et la recherche l'ANNONCE.
    func testTheFilteredNaturalQuestionReturnsPages() throws {
        let db = try makeDB()
        let livre = try addDoc(db, relPath: "Users/a/Livres/genie.pdf")
        let ailleurs = try addDoc(db, relPath: "Users/a/Cours/notes.pdf",
                                  folder: "Cours")
        try db.store.replacePages(docID: livre, pages: [
            page(1, "le temps de sejour dans un reacteur parfaitement agite"),
        ])
        try db.store.replacePages(docID: ailleurs, pages: [
            page(1, "le temps de sejour dans un reacteur piston"),
        ])
        let question = "distribution des temps de sejour dans un reacteur reel"
        XCTAssertEqual(try db.store.search(try strict(question)).totalPages, 0,
                       "le ET strict exige « distribution » et « reel »")
        let filtered = try db.store.search(try query("dossier:Livres " + question))
        XCTAssertEqual(filtered.hits.map(\.docID), [livre])
        XCTAssertTrue(filtered.quorum, "et la recherche le DIT")
        // Sans filtre, la même question rend les deux documents.
        XCTAssertEqual(try db.store.search(try query(question)).totalDocs, 2)
    }

    /// La même requête, quorum désarmé : le témoin du test ci-dessus.
    private func strict(_ input: String) throws -> SearchQuery {
        var q = try query(input)
        q.quorum = false
        return q
    }

    /// `why` NE DIT JAMAIS « exact » SUR UN HIT DE QUORUM (PM-14) : la page ne
    /// porte pas tous les mots, et l'affirmer était le pire mode de panne — la
    /// réponse plausible et fausse.
    func testWhyNeverClaimsExactOnAQuorumHit() throws {
        let words = HitExplanation.words(
            ofQuery: "distribution temps sejour reacteur")
        let extract = "le temps de sejour dans un reacteur agite"
        let quorum = try XCTUnwrap(HitExplanation(
            words: words, text: extract, textIsWholePage: false, quorum: true))
        guard case .partial(let found, let missing) = quorum else {
            return XCTFail("attendu partial, reçu \(quorum)")
        }
        XCTAssertEqual(found, ["temps", "sejour", "reacteur"])
        XCTAssertTrue(missing.isEmpty, "un extrait ne prouve aucune absence")
        XCTAssertNil(HitExplanation.json(quorum)["terms_missing"])
        XCTAssertEqual(HitExplanation.json(quorum)["kind"] as? String, "partial")
        // Hors quorum, le raisonnement d'avant reste juste : un hit lexical
        // porte tous les mots, l'extrait n'en montre qu'une partie.
        let exact = try XCTUnwrap(HitExplanation(
            words: words, text: extract, textIsWholePage: false))
        XCTAssertEqual(exact.kindLabel, "exact")
    }
}
