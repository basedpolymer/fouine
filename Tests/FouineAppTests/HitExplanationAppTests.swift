// HitExplanationAppTests.swift — « pourquoi ce résultat » côté application
// (lot U1, R-06 et R-04). Propriété : A-App.
//
// Deux choses se vérifient ici, et aucune n'est une vue : la PHRASE rendue pour
// chaque cas (c'est du texte, donc de la logique), et le fait que le modèle ne
// laisse jamais traîner la phrase d'une page sous une autre.
//
// LANGUE EN TEST : `swift test` ne tourne pas depuis Fouine.app, `Bundle.main`
// n'a aucun `.lproj`, et `String(localized:)` rend donc la CLÉ — l'anglais
// source. Les assertions portent sur cet anglais-là ; le français se vérifie
// dans le catalogue (`L10nTests`).

import XCTest
import FouineCore
@testable import FouineApp

@MainActor
final class HitExplanationAppTests: XCTestCase {

    // MARK: - La phrase, cas par cas

    func testExactSentenceQuotesTheWordsOfTheUser() {
        let sentence = HitExplanationText.sentence(
            .exact(terms: ["cinétique", "chimie"]))
        XCTAssertTrue(sentence.contains("“cinétique”"), sentence)
        XCTAssertTrue(sentence.contains("“chimie”"), sentence)
        XCTAssertTrue(sentence.hasPrefix("Found because this page contains"),
                      sentence)
    }

    func testPartialSentenceNamesWhatIsMissing() {
        let one = HitExplanationText.sentence(
            .partial(found: ["énergie"], missing: ["libre"]))
        XCTAssertTrue(one.contains("“libre”"), one)
        XCTAssertTrue(one.contains("is not on it"), one)

        // Plusieurs mots absents : le verbe s'accorde. Une variation de pluriel
        // se gouverne par un `%lld`, et il n'y a pas de nombre dans la phrase —
        // d'où deux clés.
        let several = HitExplanationText.sentence(
            .partial(found: ["énergie"], missing: ["libre", "gaz"]))
        XCTAssertTrue(several.contains("are not on it"), several)
    }

    func testFuzzySentenceShowsTheTwoSpellingsAndNoNumber() {
        let sentence = HitExplanationText.sentence(
            .fuzzy(typed: "converslon", found: "conversion", distance: 1))
        XCTAssertTrue(sentence.contains("“converslon”"), sentence)
        XCTAssertTrue(sentence.contains("“conversion”"), sentence)
        XCTAssertFalse(sentence.contains(where: \.isNumber), sentence)
    }

    func testSemanticSentenceSaysNoneOfYourWords() {
        XCTAssertEqual(
            HitExplanationText.sentence(.semanticOnly),
            "None of your words is on this page, but it deals with the same subject.")
    }

    func testBothChannelsSentence() {
        XCTAssertEqual(HitExplanationText.sentence(.both(terms: ["catalyse"])),
                       "Found by your words and by meaning.")
    }

    func testNoSentenceCarriesANumberOrJargon() {
        // La règle de la ligne : aucun nombre (ni distance, ni marge, ni
        // pourcentage), aucun mot d'informaticien. Les infobulles gardent les
        // chiffres pour qui les cherche.
        let sentences = [
            HitExplanationText.sentence(.exact(terms: ["a"])),
            HitExplanationText.sentence(.partial(found: ["a"], missing: ["b"])),
            HitExplanationText.sentence(.fuzzy(typed: "a", found: "b", distance: 2)),
            HitExplanationText.sentence(.semanticOnly),
            HitExplanationText.sentence(.both(terms: ["a"])),
        ]
        for sentence in sentences {
            XCTAssertFalse(sentence.contains(where: \.isNumber), sentence)
            for jargon in ["semantic", "vector", "cosine", "sigma", "score",
                           "rank", "index"] {
                XCTAssertFalse(sentence.lowercased().contains(jargon),
                               "« \(jargon) » dans « \(sentence) »")
            }
        }
    }

    func testVoiceOverReadsTheSentenceWithTheSnippet() {
        let why = HitExplanationText.sentence(.semanticOnly)
        let value = AccessibilityText.hitValue(snippet: "un extrait", why: why)
        XCTAssertTrue(value.contains("un extrait"), value)
        XCTAssertTrue(value.contains(why), value)
        // Sans phrase, la valeur reste exactement celle d'avant.
        XCTAssertEqual(AccessibilityText.hitValue(snippet: "un extrait", why: nil),
                       AccessibilityText.snippetValue("un extrait"))
    }

    // MARK: - Le modèle

    func testTheSentenceDescribesTheSelectedPage() async throws {
        let db = try TempAppDB()
        try db.addDoc(relPath: "cours.txt", pages: [
            "La cinetique de la reaction et la chimie des surfaces.",
            "Une page qui parle de tout autre chose, sans le second mot : cinetique.",
        ])
        let model = SearchModel(service: db.service)
        await run(model, "cinetique chimie")
        // La page 1 porte les deux mots ; c'est la seule appariée par un AND.
        XCTAssertEqual(model.selection?.page, 1)
        await settleExplanation(model)
        XCTAssertEqual(model.selectionExplanation, .exact(terms: ["cinetique", "chimie"]))
    }

    func testTheSentenceIsNotStaleWhenTheSelectionMoves() async throws {
        let db = try TempAppDB()
        try db.addDoc(relPath: "a.txt", pages: [
            "La cinetique des gaz.",
            "La cinetique des solides.",
        ])
        let model = SearchModel(service: db.service)
        await run(model, "cinetique")
        await settleExplanation(model)
        XCTAssertNotNil(model.selectionExplanation)

        // Le changement de sélection efface la phrase IMMÉDIATEMENT : une
        // phrase périmée sous une autre page est pire que pas de phrase.
        model.selection = HitKey(docID: model.hits[1].docID, page: 2)
        XCTAssertNil(model.selectionExplanation)
        await settleExplanation(model)
        XCTAssertNotNil(model.selectionExplanation)
    }

    func testNoSelectionMeansNoSentence() async throws {
        let db = try TempAppDB()
        try db.addDoc(relPath: "a.txt", pages: ["La cinetique des gaz."])
        let model = SearchModel(service: db.service)
        await run(model, "cinetique")
        await settleExplanation(model)
        XCTAssertNotNil(model.selectionExplanation)

        // Champ vidé : plus de résultat, donc plus de phrase.
        model.text = ""
        model.execute(remember: false)
        await settle(model)
        XCTAssertNil(model.selection)
        XCTAssertNil(model.selectionExplanation)
    }

    // MARK: - La phrase honnête (R-04)

    func testNoLexicalMatchIsFalseOnAnOrdinarySearch() async throws {
        let db = try TempAppDB()
        try db.addDoc(relPath: "a.txt", pages: ["La cinetique des gaz."])
        let model = SearchModel(service: db.service)
        await run(model, "cinetique")
        XCTAssertFalse(model.hits.isEmpty)
        // Recherche plein texte : la question ne se pose pas, les résultats
        // portent les mots par construction.
        XCTAssertFalse(model.noLexicalMatch)
    }

    func testNoLexicalMatchNeedsResultsToBeWorthSaying() async throws {
        let db = try TempAppDB()
        try db.addDoc(relPath: "a.txt", pages: ["La cinetique des gaz."])
        let model = SearchModel(service: db.service)
        await run(model, "introuvable")
        XCTAssertTrue(model.hits.isEmpty)
        // Zéro résultat n'a rien à expliquer : la ligne « aucun de vos mots »
        // ferait croire qu'il y a quelque chose à lire.
        XCTAssertFalse(model.noLexicalMatch)
    }

    // MARK: - Outillage

    /// Attend la tâche de lecture de page qui porte la phrase. `settle` ne la
    /// couvre pas : elle part APRÈS que la recherche est retombée au repos.
    private func settleExplanation(_ model: SearchModel,
                                   timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, model.selectionExplanation == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
