// TextDegeneracyTests.swift — les deux règles de vecteur nul ajoutées par SI1
// (MO-01, C2-16). Propriété : A-Embed.
//
// Elles sont PURES : ni base, ni modèle, ni fixture. Ce qui les rend
// éprouvables ligne par ligne, et ce qui rend la contre-épreuve possible — car
// c'est elle qui compte : de la prose ordinaire et une table de nombres ne
// doivent JAMAIS être prises pour du texte dégénéré, sans quoi la règle
// coûterait au corpus ce qu'elle prétend lui faire gagner.

import XCTest
@testable import FouineEmbed

final class TextDegeneracyTests: XCTestCase {

    // MARK: - Ce qui est dégénéré

    func testAWallOfTheSameLetterIsDegenerate() {
        XCTAssertTrue(TextDegeneracy.isDegenerate(String(repeating: "A", count: 4_000)))
        // Le scan d'une page presque blanche rend la même chose, espacée.
        XCTAssertTrue(TextDegeneracy.isDegenerate(
            String(repeating: "A ", count: 2_000)))
    }

    func testAPeriodicPatternIsDegenerate() {
        XCTAssertTrue(TextDegeneracy.isDegenerate(
            String(repeating: "ab", count: 1_000)))
        XCTAssertTrue(TextDegeneracy.isDegenerate(
            String(repeating: "-", count: 300)))
        // Une ligne de points de conduite d'un sommaire.
        XCTAssertTrue(TextDegeneracy.isDegenerate(
            String(repeating: ". ", count: 400)))
    }

    /// Ce que le 4-gramme attrape et que le compte de caractères manque : une
    /// page presque entièrement remplie d'un même motif, avec une vraie ligne de
    /// texte au milieu — la sortie d'un scan dont la bande noire a été
    /// reconnue.
    func testAPageMostlyMadeOfOnePatternIsDegenerateDespiteItsWords() {
        let scanned = String(repeating: "0", count: 1_000)
            + " total des recettes de l'exercice clos le 31 décembre"
        XCTAssertGreaterThan(Set(scanned).count,
                             TextDegeneracy.maxDistinctCharacters,
                             "ce cas doit échapper à la première règle")
        XCTAssertTrue(TextDegeneracy.isDegenerate(scanned))
    }

    // MARK: - Ce qui ne l'est PAS (la contre-épreuve)

    func testOrdinaryProseIsNotDegenerate() {
        let prose = """
        La cristallisation d'un polymère semi-cristallin dépend de la vitesse de
        refroidissement : trop rapide, les chaînes n'ont pas le temps de
        s'organiser et le matériau reste amorphe ; trop lente, les sphérolites
        grossissent et fragilisent la pièce. L'analyse enthalpique différentielle
        donne la température de fusion et le taux de cristallinité.
        """
        XCTAssertFalse(TextDegeneracy.isDegenerate(prose))
    }

    func testATableOfNumbersIsNotDegenerate() {
        let table = (1...200).map { "\($0 * 37 % 991) \($0 * 13 % 877)" }
            .joined(separator: " ")
        XCTAssertFalse(TextDegeneracy.isDegenerate(table))
    }

    func testAVeryShortTextIsNeverJudged() {
        // `minChars` a déjà écarté les fenêtres courtes : les juger ici ferait
        // annuler « OK OK » sans raison.
        XCTAssertFalse(TextDegeneracy.isDegenerate("aaaa"))
        XCTAssertFalse(TextDegeneracy.isDegenerate(""))
    }

    // MARK: - Les tableaux de nombres (lot MC3, constat PM-09)

    /// Une table de mesures ne dit rien au canal sémantique : son vecteur est
    /// proche de tous les autres tableaux du corpus et de rien d'utile.
    func testATableOfMeasurementsIsMostlyNumeric() {
        let table = (1...80)
            .map { "\($0);\($0 * 37 % 991),\($0 * 13 % 877);\($0 * 3 % 97).5" }
            .joined(separator: "\n")
        XCTAssertTrue(TextDegeneracy.isMostlyNumeric(table))
    }

    /// De la prose qui porte des dates et des chiffres reste de la prose :
    /// c'est la contre-épreuve qui compte, puisque la règle coûterait au corpus
    /// ce qu'elle prétend lui faire gagner si elle se trompait ici.
    func testProseWithDatesIsNotMostlyNumeric() {
        let prose = "Le 12 mars 2024, la température de fusion mesurée était de "
            + "178 °C, soit 3 degrés de plus que lors de la campagne du 4 "
            + "janvier 2023 ; le taux de cristallinité passe de 42 % à 47 %."
        XCTAssertFalse(TextDegeneracy.isMostlyNumeric(prose))
    }

    /// Un relevé bancaire porte des libellés : ses lettres font largement plus
    /// d'un cinquième du texte, et il reste vectorisable.
    func testABankStatementWithLabelsIsNotMostlyNumeric() {
        let statement = (1...20).map {
            "VIR SEPA LOYER APPARTEMENT \($0)/03 -750,00 SOLDE 1 240,55"
        }.joined(separator: "\n")
        XCTAssertFalse(TextDegeneracy.isMostlyNumeric(statement))
    }

    // MARK: - Les phrases témoins de la sonde de texte partagé

    func testTwoWitnessPhrasesAreTakenFarApart() throws {
        let words = (1...200).map { "mot\($0)" }.joined(separator: " ")
        let pair = try XCTUnwrap(SharedTextProbe.phrases(of: words))
        XCTAssertEqual(pair.0.split(separator: " ").count, 8)
        XCTAssertEqual(pair.1.split(separator: " ").count, 8)
        XCTAssertNotEqual(pair.0, pair.1)
        // À 25 % et à 75 % : la première phrase vient bien avant la seconde.
        let first = try XCTUnwrap(words.range(of: pair.0))
        let second = try XCTUnwrap(words.range(of: pair.1))
        XCTAssertLessThan(first.lowerBound, second.lowerBound)
    }

    func testAShortWindowIsNeverProbed() {
        XCTAssertNil(SharedTextProbe.phrases(of: "trop court pour être sondé"))
        XCTAssertNil(SharedTextProbe.query(for: String(repeating: "a", count: 399)))
    }

    /// La requête est un ET de deux phrases EXACTES : c'est ce qui distingue
    /// « le même passage recopié » de « deux documents qui parlent du même
    /// sujet ».
    func testTheQueryIsAnAndOfTwoExactPhrases() throws {
        let text = (1...200).map { "mot\($0)" }.joined(separator: " ")
        let query = try XCTUnwrap(SharedTextProbe.query(for: text))
        XCTAssertEqual(query.components(separatedBy: "\"").count - 1, 4)
        XCTAssertTrue(query.contains("\" AND \""), query)
        // La ponctuation n'entre jamais dans la requête : un mot est une suite
        // de lettres ou de chiffres.
        let quoted = "Il a dit : « c'est fini », puis il est parti. "
        let punctuated = String(repeating: quoted, count: 20)
        let second = try XCTUnwrap(SharedTextProbe.query(for: punctuated))
        XCTAssertFalse(second.contains("«"), second)
        XCTAssertFalse(second.contains(":"), second)
    }
}
