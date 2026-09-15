// HitExplanationTests.swift — le noyau de « pourquoi ce résultat » (lot U1, R-06).
//
// Aucune base : `HitExplanation` est une fonction pure, et c'est ce qui la rend
// vérifiable au cas près. Ce qui est éprouvé ici est ce que l'utilisateur lira :
// quels mots sont cités, lesquels ne le sont jamais, et quand on préfère se
// taire.

import XCTest
import FouineCore

final class HitExplanationTests: XCTestCase {

    private func words(_ query: String) -> [QueryWord] {
        HitExplanation.words(ofQuery: query)
    }

    private func explain(_ query: String, text: String, fuzzyDistance: Int = 0,
                         lexRank: Int? = nil, vecRank: Int? = nil)
        -> HitExplanation? {
        HitExplanation(words: words(query), text: text,
                       fuzzyDistance: fuzzyDistance,
                       lexRank: lexRank, vecRank: vecRank)
    }

    // MARK: - Les cinq cas

    func testAllWordsPresent() {
        XCTAssertEqual(explain("cinetique chimie",
                               text: "La cinetique de la chimie des surfaces."),
                       .exact(terms: ["cinetique", "chimie"]))
    }

    func testSomeWordsMissing() {
        XCTAssertEqual(explain("energie libre",
                               text: "L'energie d'activation de la reaction."),
                       .partial(found: ["energie"], missing: ["libre"]))
    }

    func testCloseSpelling() {
        // « converslon » (faute de frappe / OCR) trouve « conversion » : une
        // lettre d'écart, et c'est le mot de la PAGE qui est cité.
        XCTAssertEqual(explain("converslon", text: "Taux de conversion mesure.",
                               fuzzyDistance: 1),
                       .fuzzy(typed: "converslon", found: "conversion",
                              distance: 1))
    }

    func testSemanticOnlyWhenTheLexicalChannelDidNotFindThePage() {
        XCTAssertEqual(explain("tarte aux pommes",
                               text: "Chapitre 3 — thermodynamique.",
                               lexRank: nil, vecRank: 4),
                       .semanticOnly)
    }

    func testBothChannels() {
        XCTAssertEqual(explain("catalyse",
                               text: "La catalyse heterogene.",
                               lexRank: 2, vecRank: 7),
                       .both(terms: ["catalyse"]))
    }

    // MARK: - Accents, casse, frontières de mot

    func testAccentsAndCaseAreFoldedLikeTheTokenizer() {
        // `remove_diacritics 2` : « énergie » tapé trouve « energie » écrit, et
        // l'inverse ; la casse ne compte pas non plus.
        XCTAssertEqual(explain("énergie", text: "Bilan d'energie du systeme."),
                       .exact(terms: ["énergie"]))
        XCTAssertEqual(explain("energie", text: "Bilan d'Énergie du systeme."),
                       .exact(terms: ["energie"]))
    }

    func testTheWordIsCitedAsTyped() {
        // On cite les mots de l'UTILISATEUR, pas leur forme repliée.
        guard case .exact(let terms)? = explain("Énergie",
                                                text: "energie totale") else {
            return XCTFail("cas attendu : exact")
        }
        XCTAssertEqual(terms, ["Énergie"])
    }

    func testWordBoundaries() {
        // « or » ne compte pas dans « sort » : le moteur compte des jetons, pas
        // des sous-chaînes (le piège de l'audit A2-17).
        XCTAssertNil(explain("or", text: "Il sort du corps, d'abord."))
        XCTAssertEqual(explain("or", text: "L'or et le platine."),
                       .exact(terms: ["or"]))
    }

    func testApostropheSplitsTokensLikeFTS5() {
        XCTAssertEqual(explain("enthalpie", text: "L'enthalpie libre."),
                       .exact(terms: ["enthalpie"]))
    }

    // MARK: - Phrases, préfixes, exclusions

    func testPhraseNeedsContiguousTokens() {
        XCTAssertEqual(explain("\"gaz parfait\"",
                               text: "Le gaz parfait monoatomique."),
                       .exact(terms: ["gaz parfait"]))
        // Les deux mots sont là, mais pas côte à côte : la phrase n'y est pas.
        XCTAssertNil(explain("\"gaz parfait\"",
                             text: "Ce gaz est un fluide parfait."))
    }

    func testPrefixMatchesTheStartOfAToken() {
        XCTAssertEqual(explain("spectro*", text: "La spectroscopie infrarouge."),
                       .exact(terms: ["spectro"]))
        XCTAssertNil(explain("spectro*", text: "Analyse par diffraction."))
    }

    func testExcludedTermIsNeverListed() {
        // `-biologie` a écarté des documents ; le citer désignerait à
        // l'utilisateur exactement ce qu'il a demandé d'écarter (audit F1).
        let explanation = explain("azote -biologie",
                                  text: "L'azote et la biologie des sols.")
        XCTAssertEqual(explanation, .exact(terms: ["azote"]))
        XCTAssertFalse(HitExplanation.words(ofQuery: "azote -biologie")
            .contains { $0.text == "biologie" })
    }

    func testNearMembersAreListed() {
        XCTAssertEqual(explain("pres:5 azote reduction",
                               text: "La reduction de l'azote atmospherique."),
                       .exact(terms: ["azote", "reduction"]))
    }

    // MARK: - Rien à dire

    func testEmptyQuerySaysNothing() {
        XCTAssertTrue(HitExplanation.words(ofQuery: "").isEmpty)
        XCTAssertNil(explain("", text: "Un texte quelconque."))
        XCTAssertNil(HitExplanation(words: [], text: "Un texte quelconque."))
    }

    func testNoWordFoundAndNoSemanticChannelSaysNothing() {
        // L'appelant a pu ne donner qu'un extrait, qui ne porte pas le terme :
        // pas de phrase vaut mieux qu'une phrase fausse.
        XCTAssertNil(explain("polymere", text: "…suite du paragraphe…"))
    }

    func testRepeatedWordIsCitedOnce() {
        XCTAssertEqual(explain("azote azote", text: "L'azote liquide."),
                       .exact(terms: ["azote"]))
    }

    // MARK: - Orthographe proche : les garde-fous

    func testShortWordsNeverGetACloseSpelling() {
        // Sous six lettres l'index n'expanse rien (§5.5.2) : annoncer
        // « “sort” → “sord” » serait une invention.
        XCTAssertNil(explain("sord", text: "Il sort de la piece.",
                             fuzzyDistance: 1))
    }

    func testCloseSpellingKeepsTheNearestWordOfThePage() {
        // Deux candidats, l'un à 2 lettres, l'autre à 1 : c'est le plus proche
        // qui est cité.
        guard case .fuzzy(_, let found, let distance)?
                = explain("catalyseur",
                          text: "Le calalyseur et le cotolyseur du reacteur.",
                          fuzzyDistance: 2) else {
            return XCTFail("cas attendu : fuzzy")
        }
        XCTAssertEqual(found, "calalyseur")
        XCTAssertEqual(distance, 1)
    }

    func testExactWordWinsOverAFuzzyVariantOnTheSamePage() {
        // La page porte le mot exact : le résultat n'a rien d'approché à dire,
        // même si la requête a été expansée pour d'autres pages.
        XCTAssertEqual(explain("catalyseur",
                               text: "Le catalyseur et le calalyseur.",
                               fuzzyDistance: 1),
                       .exact(terms: ["catalyseur"]))
    }

    // MARK: - Extrait contre page entière

    func testAnExcerptNeverClaimsAWordIsMissing() {
        // `fouine search 'cinetique reticulation' --json` annonçait
        // « “cinetique” manque » pour une page que FTS5 avait appariée sur les
        // DEUX mots : l'extrait n'en montrait qu'un (mesuré le 05/09/2026 sur
        // une copie de la base de production). Un hit lexical les porte tous.
        XCTAssertEqual(
            HitExplanation(words: words("cinetique reticulation"),
                           text: "…taux de «reticulation» du reseau…",
                           textIsWholePage: false),
            .exact(terms: ["cinetique", "reticulation"]))
    }

    func testTheWholePageCanStillSayAWordIsMissing() {
        XCTAssertEqual(
            HitExplanation(words: words("cinetique reticulation"),
                           text: "Taux de reticulation du reseau.",
                           textIsWholePage: true),
            .partial(found: ["reticulation"], missing: ["cinetique"]))
    }

    func testAnExcerptSaysNothingWhenTheMatchWasApproximateAndUnnamable() {
        // La requête a été expansée mais l'extrait ne montre aucune variante :
        // on ne peut pas dire laquelle, et affirmer que le mot tapé est là
        // serait faux.
        XCTAssertNil(HitExplanation(words: words("catalyseur"),
                                    text: "…suite du paragraphe…",
                                    fuzzyDistance: 1, textIsWholePage: false))
    }

    func testAnExcerptOfAHybridHitFoundByBothChannels() {
        XCTAssertEqual(
            HitExplanation(words: words("catalyse"), text: "…du reacteur…",
                           lexRank: 3, vecRank: 8, textIsWholePage: false),
            .both(terms: ["catalyse"]))
    }

    // MARK: - L'objet `why` du JSON

    func testJSONShape() {
        let exact = HitExplanation.json(.exact(terms: ["azote"]))
        XCTAssertEqual(exact["kind"] as? String, "exact")
        XCTAssertEqual(exact["terms_found"] as? [String], ["azote"])
        XCTAssertNil(exact["terms_missing"])

        let partial = HitExplanation.json(.partial(found: ["a"], missing: ["b"]))
        XCTAssertEqual(partial["kind"] as? String, "partial")
        XCTAssertEqual(partial["terms_missing"] as? [String], ["b"])

        let fuzzy = HitExplanation.json(
            .fuzzy(typed: "converslon", found: "conversion", distance: 1))
        XCTAssertEqual(fuzzy["kind"] as? String, "fuzzy")
        XCTAssertEqual(fuzzy["typed"] as? String, "converslon")
        XCTAssertEqual(fuzzy["found"] as? String, "conversion")
        XCTAssertEqual(fuzzy["distance"] as? Int, 1)

        let semantic = HitExplanation.json(.semanticOnly)
        XCTAssertEqual(semantic["kind"] as? String, "semantic")
        XCTAssertEqual(semantic.count, 1)

        XCTAssertEqual(HitExplanation.json(.both(terms: ["x"]))["kind"] as? String,
                       "both")
    }

    // MARK: - Le conseil du cœur

    func testNoLexicalMatchAdviceHasNoJargonAndNoNumber() {
        let advice = SearchAdvice.noLexicalMatch
        XCTAssertFalse(advice.isEmpty)
        XCTAssertFalse(advice.contains(where: \.isNumber))
        for jargon in ["cosine", "vector", "semantic", "z ", "sigma"] {
            XCTAssertFalse(advice.lowercased().contains(jargon),
                           "le conseil ne doit pas dire « \(jargon) »")
        }
    }
}
