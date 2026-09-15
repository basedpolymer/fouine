// DiversityMorphologyTests.swift — le classement du lot R1 dans le store :
// un document ne prend pas tout l'écran, et un mot vaut pour son pluriel.
// Propriété : A-Core.
//
// Même discipline que `RankingBoostTests` pour la diversité : elle ne change
// QUE L'ORDRE — mêmes pages, mêmes totaux, mêmes facettes. La morphologie,
// elle, change ce qui est TROUVÉ, et les tests le disent en comptant.

import XCTest
@testable import FouineCore

final class DiversityMorphologyTests: XCTestCase {

    private func pages(_ db: TempDB, _ input: String,
                       diversity: Bool = true, morphology: Bool = true,
                       inDocIDs: [Int64] = []) throws -> [(Int64, Int)] {
        var q = try query(input, inDocIDs: inDocIDs)
        q.diversifyDocuments = diversity
        q.morphology = morphology
        return try db.store.search(q).hits.map { ($0.docID, $0.page) }
    }

    // MARK: - Diversité

    /// Un livre dont six pages répondent fort, une note dont une page répond
    /// moins fort. Sans diversité, la note vient APRÈS les six pages du livre ;
    /// avec, elle passe devant sa quatrième page.
    func testTheFourthPageOfADocumentLetsAnotherDocumentIn() throws {
        let db = try makeDB()
        let book = try addDoc(db, relPath: "Users/alice/Livres/traite.pdf")
        let note = try addDoc(db, relPath: "Users/alice/Cours/note.pdf")
        let filler = Array(repeating: "remplissage", count: 12).joined(separator: " ")
        try db.store.replacePages(docID: book, pages: (1...6).map {
            page($0, "cinetique cinetique cinetique \(filler)")
        })
        try db.store.replacePages(docID: note, pages: [
            page(1, "cinetique cinetique \(filler) \(filler)"),
        ])

        let before = try pages(db, "cinetique", diversity: false)
        XCTAssertEqual(before.last?.0, note, "sans diversité, la note est dernière")
        XCTAssertEqual(before.prefix(6).map(\.0), Array(repeating: book, count: 6))

        let after = try pages(db, "cinetique")
        XCTAssertEqual(after.prefix(3).map(\.0), Array(repeating: book, count: 3),
                       "les trois meilleures pages du livre gardent leur place")
        XCTAssertEqual(after[3].0, note,
                       "la quatrième place revient à l'autre document")
        XCTAssertEqual(after.suffix(3).map(\.0), Array(repeating: book, count: 3),
                       "les pages rétrogradées suivent, dans leur ordre")
        XCTAssertEqual(Set(before.map { "\($0.0)/\($0.1)" }),
                       Set(after.map { "\($0.0)/\($0.1)" }),
                       "la diversité ne change QUE l'ordre")
    }

    /// Le palier est DOUX : une quatrième page très pertinente reste devant la
    /// page d'un document qui n'effleure le sujet (score plus de deux fois
    /// plus faible).
    func testAStrongFourthPageStillBeatsAMarginalDocument() throws {
        let db = try makeDB()
        let book = try addDoc(db, relPath: "Users/alice/Livres/traite.pdf")
        let marginal = try addDoc(db, relPath: "Users/alice/Divers/marginal.pdf")
        try db.store.replacePages(docID: book, pages: (1...4).map {
            page($0, Array(repeating: "cinetique", count: 8).joined(separator: " "))
        })
        let filler = Array(repeating: "remplissage", count: 120).joined(separator: " ")
        try db.store.replacePages(docID: marginal, pages: [page(1, "cinetique \(filler)")])

        let after = try pages(db, "cinetique")
        XCTAssertEqual(after.map(\.0), [book, book, book, book, marginal],
                       "le score rétrogradé (× 0,5) reste meilleur que celui d'une mention isolée")
    }

    func testDiversityIsDisarmedWhenSearchingInsideOneDocument() throws {
        let db = try makeDB()
        let book = try addDoc(db, relPath: "Users/alice/Livres/traite.pdf")
        try db.store.replacePages(docID: book, pages: (1...5).map {
            page($0, "cinetique " + Array(repeating: "mot", count: $0).joined(separator: " "))
        })
        var q = try query("cinetique", inDocIDs: [book])
        let scores = try db.store.search(q).hits.map(\.score)
        q.diversifyDocuments = false
        let plain = try db.store.search(q).hits.map(\.score)
        XCTAssertEqual(scores, plain,
                       "dans un seul document, aucun score n'est rétrogradé (le pourcentage resterait lisible)")
    }

    func testDiversityDoesNotTouchTotalsNorFacets() throws {
        let db = try makeDB()
        let book = try addDoc(db, relPath: "Users/alice/Livres/traite.pdf", folder: "Livres")
        let note = try addDoc(db, relPath: "Users/alice/Cours/note.pdf", folder: "Cours")
        try db.store.replacePages(docID: book, pages: (1...5).map { page($0, "cinetique chimique") })
        try db.store.replacePages(docID: note, pages: [page(1, "cinetique")])
        var q = try query("cinetique")
        let with = try db.store.search(q)
        q.diversifyDocuments = false
        let without = try db.store.search(q)
        XCTAssertEqual(with.totalPages, without.totalPages)
        XCTAssertEqual(with.totalDocs, without.totalDocs)
        XCTAssertEqual(try db.store.facets(q, by: .folder).map(\.1).sorted(), [1, 5])
    }

    /// La pagination reste disjointe et complète avec la couche de diversité :
    /// deux tranches de trois rendent les six pages, chacune une fois.
    func testPaginationStaysDisjointWithDiversity() throws {
        let db = try makeDB()
        let book = try addDoc(db, relPath: "Users/alice/Livres/traite.pdf")
        let note = try addDoc(db, relPath: "Users/alice/Cours/note.pdf")
        try db.store.replacePages(docID: book, pages: (1...5).map { page($0, "cinetique cinetique") })
        try db.store.replacePages(docID: note, pages: [page(1, "cinetique")])
        var q = try query("cinetique", limit: 3)
        let first = try db.store.search(q).hits.map { "\($0.docID)/\($0.page)" }
        q.offset = 3
        let second = try db.store.search(q).hits.map { "\($0.docID)/\($0.page)" }
        XCTAssertEqual(first.count, 3)
        XCTAssertEqual(second.count, 3)
        XCTAssertEqual(Set(first).intersection(second), [], "aucune page en double")
        XCTAssertEqual(Set(first).union(second).count, 6, "aucune page perdue")
    }

    /// La pagination reste disjointe et complète sur le chemin FLOU aussi
    /// (AUDIT-R1 I5 : seul le chemin exact était couvert) : pages OCR, une
    /// coquille, deux tranches, sept pages chacune une fois.
    func testPaginationStaysDisjointWithDiversityOnTheFuzzyPath() throws {
        let db = try makeDB()
        let book = try addDoc(db, relPath: "Users/alice/Scans/traite.pdf")
        let note = try addDoc(db, relPath: "Users/alice/Scans/note.pdf")
        // Vingt caractères au moins par page : en deçà, une page OCR n'est pas
        // indexée du tout (`GRDBStore.minIndexedCharacters`).
        for n in 1...4 {
            try db.store.completeOCR(docID: book, page: n,
                                     result: ocrPage("la cinetique des reactions, cinetique encore"))
        }
        try db.store.completeOCR(docID: book, page: 5, result: ocrPage("la cinetlque des gaz rares"))
        try db.store.completeOCR(docID: book, page: 6, result: ocrPage("la cinetlque encore une fois"))
        try db.store.completeOCR(docID: note, page: 1, result: ocrPage("une note sur la cinetique"))
        try TrigramExpander(store: db.store).warm()

        var q = try query("cinetique", limit: 4, fuzzy: .on)
        let all = try db.store.search(q)
        XCTAssertEqual(all.totalPages, 7, "quatre exactes, deux floues, une de la note")
        XCTAssertTrue(all.hits.contains { $0.fuzzyDistance == 1 }, "le chemin flou est bien pris")
        let first = all.hits.map { "\($0.docID)/\($0.page)" }
        q.offset = 4
        let second = try db.store.search(q).hits.map { "\($0.docID)/\($0.page)" }
        XCTAssertEqual(first.count, 4)
        XCTAssertEqual(second.count, 3)
        XCTAssertEqual(Set(first).intersection(second), [], "aucune page en double")
        XCTAssertEqual(Set(first).union(second).count, 7, "aucune page perdue")
    }

    /// Restreinte à DEUX documents, la recherche diversifie encore : c'est le
    /// seul document (« Rechercher dans ce document… ») qui désarme.
    func testDiversityAppliesWhenSearchingInsideTwoDocuments() throws {
        let db = try makeDB()
        let book = try addDoc(db, relPath: "Users/alice/Livres/traite.pdf")
        let note = try addDoc(db, relPath: "Users/alice/Cours/note.pdf")
        let other = try addDoc(db, relPath: "Users/alice/Cours/autre.pdf")
        let filler = Array(repeating: "remplissage", count: 12).joined(separator: " ")
        try db.store.replacePages(docID: book, pages: (1...6).map {
            page($0, "cinetique cinetique cinetique \(filler)")
        })
        try db.store.replacePages(docID: note, pages: [page(1, "cinetique cinetique \(filler) \(filler)")])
        try db.store.replacePages(docID: other, pages: [page(1, "cinetique cinetique \(filler) \(filler)")])

        let two = try pages(db, "cinetique", inDocIDs: [book, note])
        XCTAssertEqual(Set(two.map(\.0)), [book, note], "le troisième document est bien exclu")
        XCTAssertEqual(two[3].0, note, "la quatrième place revient à la note, comme sans restriction")
        let one = try pages(db, "cinetique", inDocIDs: [book])
        XCTAssertEqual(one.map(\.1), [1, 2, 3, 4, 5, 6], "un seul document : rien à diversifier")
    }

    // MARK: - Morphologie

    /// AUDIT-R1 B1 : `entropy entropie` devenait `(entropy OR entropies) AND
    /// (entropie OR entropies)`, qu'une page ne portant QUE « entropies »
    /// satisfait — sur la base réelle, 77 pages devenaient 943. La forme
    /// commune ne va à aucun des deux mots : le ET est un ET.
    func testTwoWordsSharingAFormKeepTheirAND() throws {
        let db = try makeDB()
        let onlyShared = try addDoc(db, relPath: "Users/alice/Livres/atkins.pdf")
        let both = try addDoc(db, relPath: "Users/alice/Cours/cours.pdf")
        try db.store.replacePages(docID: onlyShared, pages: [
            page(1, "the entropies of mixing are tabulated here"),
        ])
        try db.store.replacePages(docID: both, pages: [
            page(1, "entropy, en francais entropie"),
        ])
        let hits = try pages(db, "entropy entropie")
        XCTAssertEqual(hits.map { "\($0.0)/\($0.1)" }, ["\(both)/1"],
                       "la page qui ne dit que « entropies » ne porte aucun des deux mots")
        let q = try query("entropy entropie")
        XCTAssertEqual(try db.store.search(q).totalPages, 1)

        // Chaque mot seul décline toujours : c'est bien la forme COMMUNE qui
        // est retirée, pas la morphologie.
        XCTAssertEqual(Set(try pages(db, "entropy").map(\.0)), [onlyShared, both])
        XCTAssertEqual(Set(try pages(db, "entropie").map(\.0)), [onlyShared, both])
    }

    /// `polymere polymeres` : le second mot n'est pas absorbé comme forme du
    /// premier — une page qui ne dit que « polymère » ne sort pas.
    func testATypedPluralIsNotAbsorbedByItsSingular() throws {
        let db = try makeDB()
        let singular = try addDoc(db, relPath: "Users/alice/Cours/un.pdf")
        let bothForms = try addDoc(db, relPath: "Users/alice/Cours/deux.pdf")
        try db.store.replacePages(docID: singular, pages: [page(1, "le polymere seul")])
        try db.store.replacePages(docID: bothForms, pages: [page(1, "un polymere, des polymeres")])
        XCTAssertEqual(try pages(db, "polymere polymeres").map(\.0), [bothForms])
        XCTAssertEqual(Set(try pages(db, "polymere").map(\.0)), [singular, bothForms],
                       "seul, « polymere » trouve toujours le pluriel")
    }

    /// AUDIT-R1 I1 : une chaîne FTS5 BRUTE (`--raw-fts`, sans terme analysé)
    /// n'est jamais réécrite — `body:polymere` restait valide avec
    /// `--no-morphology` et cassait sans.
    func testARawFTSStringIsNeverRewritten() throws {
        let db = try makeDB()
        let doc = try addDoc(db, relPath: "Users/alice/Cours/un.pdf")
        try db.store.replacePages(docID: doc, pages: [
            page(1, "le polymere"), page(2, "les polymeres"),
        ])
        let raw = SearchQuery(terms: [], fts: "polymere", fuzzy: .off)
        XCTAssertTrue(raw.morphology, "le drapeau reste vrai : c'est l'absence de terme qui protège")
        XCTAssertEqual(try db.store.search(raw).hits.map(\.page), [1],
                       "la chaîne brute part telle quelle : pas de pluriel")
        let column = SearchQuery(terms: [], fts: "body:polymere", fuzzy: .off)
        XCTAssertEqual(try db.store.search(column).hits.map(\.page), [1])
        let anchored = SearchQuery(terms: [], fts: "^les", fuzzy: .off)
        XCTAssertEqual(try db.store.search(anchored).hits.map(\.page), [2],
                       "« ^ » ancre au premier jeton de la page : du FTS5 que l'analyseur ignore")
        let parsed = try query("polymere")
        XCTAssertEqual(try db.store.search(parsed).hits.map(\.page).sorted(), [1, 2],
                       "la même requête analysée décline")
    }

    func testASingularFindsThePluralAndCountsIt() throws {
        let db = try makeDB()
        let doc = try addDoc(db, relPath: "Users/alice/Livres/polymeres.pdf")
        try db.store.replacePages(docID: doc, pages: [
            page(1, "les polymères sont de longues chaînes"),
            page(2, "le polymere est une macromolécule"),
            page(3, "rien de tout cela"),
        ])
        var q = try query("polymere")
        let with = try db.store.search(q)
        XCTAssertEqual(with.hits.map(\.page).sorted(), [1, 2])
        XCTAssertEqual(with.totalPages, 2, "le total compte le pluriel")
        XCTAssertEqual(try db.store.matchedPageCounts(q, excludingDocsMatching: nil)[doc], 2)

        q.morphology = false
        let without = try db.store.search(q)
        XCTAssertEqual(without.hits.map(\.page), [2])
        XCTAssertEqual(without.totalPages, 1)
    }

    func testThePluralFindsTheSingularToo() throws {
        let db = try makeDB()
        let doc = try addDoc(db, relPath: "Users/alice/Livres/notes.pdf")
        try db.store.replacePages(docID: doc, pages: [
            page(1, "une liaison hydrogene"),
            page(2, "des liaisons covalentes"),
        ])
        XCTAssertEqual(try pages(db, "liaisons").map(\.1).sorted(), [1, 2])
    }

    func testTheExclusionAppliesToThePluralAsWell() throws {
        let db = try makeDB()
        let bio = try addDoc(db, relPath: "Users/alice/Livres/bio.pdf")
        let chem = try addDoc(db, relPath: "Users/alice/Livres/chem.pdf")
        try db.store.replacePages(docID: bio, pages: [page(1, "chimie des biologies")])
        try db.store.replacePages(docID: chem, pages: [page(1, "chimie pure")])
        let (q, negative) = try QueryParser.searchPlan("chimie -biologie")
        let hits = try db.store.search(q, excludingDocsMatching: negative)
        XCTAssertEqual(hits.hits.map(\.docID), [chem],
                       "« -biologie » écarte aussi le document qui dit « biologies »")
    }

    /// La sonde de phrase accepte les formes : « polymeres reticules » est la
    /// phrase « polymere reticule ».
    func testThePhraseBonusRecognisesInflectedForms() throws {
        let db = try makeDB()
        let doc = try addDoc(db, relPath: "Users/alice/Cours/notes.pdf")
        let filler = Array(repeating: "remplissage", count: 30).joined(separator: " ")
        try db.store.replacePages(docID: doc, pages: [
            page(1, "polymere \(filler) reticule"),
            page(2, "polymeres reticules \(filler)"),
        ])
        var q = try query("polymere reticule")
        XCTAssertEqual(try db.store.search(q).hits.map(\.page), [2, 1],
                       "la page qui porte l'expression au pluriel passe devant")
        q.rankingBoosts = false
        XCTAssertEqual(try db.store.search(q).hits.map(\.page), [1, 2],
                       "sans bonus, l'ordre est celui du rowid (scores voisins)")
    }

    /// Le nom du document aussi : « Polymères.pdf » porte le mot « polymere ».
    func testTheNameBonusRecognisesInflectedForms() throws {
        let db = try makeDB()
        let named = try addDoc(db, relPath: "Users/alice/Livres/Polymères réticulés.pdf")
        let other = try addDoc(db, relPath: "Users/alice/Livres/divers.pdf")
        try db.store.replacePages(docID: named, pages: [page(1, "remplissage polymere ici reticule")])
        try db.store.replacePages(docID: other, pages: [page(1, "remplissage polymere ici reticule")])
        var q = try query("polymere reticule")
        XCTAssertEqual(try db.store.search(q).hits.map(\.docID), [named, other])
        q.rankingBoosts = false
        XCTAssertEqual(try db.store.search(q).hits.map(\.docID), [named, other].sorted(),
                       "sans bonus, l'ordre est celui du rowid")
    }

    func testFuzzyAndMorphologyCombineOnTheSameWord() throws {
        let db = try makeDB()
        let doc = try addDoc(db, relPath: "Users/alice/Scans/scan.pdf")
        try db.store.completeOCR(docID: doc, page: 1,
                                 result: ocrPage("les thermodynamiques sont"))
        try db.store.completeOCR(docID: doc, page: 2,
                                 result: ocrPage("la thermodynamlque est"))
        try TrigramExpander(store: db.store).warm()
        var q = try query("thermodynamique", fuzzy: .on)
        let hits = try db.store.search(q).hits
        XCTAssertEqual(hits.map(\.page).sorted(), [1, 2])
        XCTAssertEqual(hits.first { $0.page == 1 }?.fuzzyDistance, 0,
                       "le pluriel est une forme exacte, pas une variante floue")
        XCTAssertEqual(hits.first { $0.page == 2 }?.fuzzyDistance, 1)
        q.fuzzy = .off
        XCTAssertEqual(try db.store.search(q).hits.map(\.page), [1])
    }
}
