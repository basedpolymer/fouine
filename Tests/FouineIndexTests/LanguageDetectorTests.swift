// LanguageDetectorTests.swift — `docs.lang`, enfin alimentée (audit X2, F8).
// Propriété : A-Core.
//
// La colonne existait depuis la vague 0 et n'a JAMAIS reçu de valeur
// (`DocRecord.lang = nil`, partout). Ces cas fixent les trois choses qui
// comptent : un texte français rend « fr », un texte anglais « en », et tout ce
// qui ne permet pas de trancher rend `nil` — parce qu'une colonne remplie de
// langues inventées serait pire que la colonne vide d'hier.

import Foundation
import XCTest
import FouineCore
@testable import FouineIndex

final class LanguageDetectorTests: XCTestCase {

    /// Un paragraphe, pas une phrase : c'est l'ordre de grandeur qu'une page de
    /// document fournit, et le seuil de confiance exige de la matière.
    private let french = """
        La chimie organique étudie les composés du carbone et les réactions qui
        les transforment. Une réaction d'oxydation retire des électrons à une
        molécule, tandis qu'une réduction lui en apporte. Le catalyseur, lui,
        abaisse l'énergie d'activation sans être consommé par la réaction : on
        le retrouve intact à la fin, ce qui le distingue d'un réactif ordinaire.
        """

    private let english = """
        Organic chemistry studies the compounds of carbon and the reactions that
        transform them. An oxidation reaction removes electrons from a molecule,
        while a reduction adds them. The catalyst lowers the activation energy
        without being consumed by the reaction: it is found intact at the end,
        which is what distinguishes it from an ordinary reagent.
        """

    func testFrenchTextIsDetectedAsFR() {
        XCTAssertEqual(LanguageDetector.detect(french), "fr")
    }

    func testEnglishTextIsDetectedAsEN() {
        XCTAssertEqual(LanguageDetector.detect(english), "en")
    }

    /// Rien à analyser : `nil`, et surtout pas une langue par défaut.
    func testEmptyOrWhitespaceTextIsUndetermined() {
        XCTAssertNil(LanguageDetector.detect(""))
        XCTAssertNil(LanguageDetector.detect("   \n\t  "))
    }

    /// Trop court pour trancher. `NLLanguageRecognizer` répond TOUJOURS quelque
    /// chose : sans le plancher de `minimumCharacters`, « Merci. » suffirait à
    /// écrire une langue en base.
    func testTooShortIsUndetermined() {
        XCTAssertNil(LanguageDetector.detect("Merci."))
        XCTAssertNil(LanguageDetector.detect("Page 12"))
        // Une suite de chiffres et de ponctuation — le cas d'une page de table
        // des matières mal extraite.
        XCTAssertNil(LanguageDetector.detect("12 . 34 . 56 . 78 . 90 . 12 . 34 ."))
    }

    /// L'échantillon est BORNÉ : au-delà de `sampleCharacters`, on n'examine
    /// plus rien. Un ouvrage français de 1 570 pages ne doit pas coûter une
    /// analyse de plusieurs millions de caractères.
    func testOnlyThePrefixIsExamined() {
        let padding = String(repeating: french + " ", count: 40)
        XCTAssertGreaterThan(padding.count, LanguageDetector.sampleCharacters)
        // La queue anglaise est hors de l'échantillon : la réponse reste « fr ».
        XCTAssertEqual(LanguageDetector.detect(padding + english), "fr")
    }

    /// L'échantillon se construit dans l'ordre des pages, et un document court
    /// tient en UNE tranche : il n'y a rien à répartir sur trois feuillets.
    func testSampleFollowsPageOrderOnAShortDocument() {
        let pages = [
            PageText(page: 3, text: "troisième " + french, source: .native),
            PageText(page: 1, text: "première " + french, source: .native),
            PageText(page: 2, text: "deuxième " + french, source: .native),
        ]
        let slices = LanguageDetector.sample(pages: pages)
        XCTAssertEqual(slices.count, 1)
        XCTAssertTrue(slices[0].hasPrefix("première"),
                      "les pages doivent être assemblées dans l'ordre : \(slices[0])")
        XCTAssertTrue(slices[0].contains("troisième"))
    }

    // MARK: - C2-01 : on ne juge plus sur la tête du document

    /// LE CAS DE L'AUDIT. Un roman français précédé du préambule Gutenberg
    /// (≈ 1 200 mots d'anglais) était rangé en « en » : les 4 000 premiers
    /// caractères ne parlaient que de licence. « Le Horla » était introuvable
    /// avec le filtre « Français ».
    func testAnEnglishPreambleDoesNotDecideTheLanguageOfAFrenchBook() {
        let preamble = String(repeating: english + " ", count: 12)   // ≈ 4 800 car.
        let body = String(repeating: french + " ", count: 60)        // ≈ 21 000 car.
        XCTAssertGreaterThan(preamble.count, LanguageDetector.sampleCharacters)

        let pages = [PageText(page: 1, text: preamble + body, source: .native)]
        let slices = LanguageDetector.sample(pages: pages)
        XCTAssertEqual(slices.count, 3, "trois tranches quand il y a la matière")
        XCTAssertEqual(LanguageDetector.detect(slices), "fr")
    }

    /// Les en-têtes RFC 822 ne sont la langue de personne : le courriel de
    /// l'audit (`courriel-rendez-vous-ravalement.eml`) partait en islandais.
    func testMailHeadersAreLeftOutOfTheSample() {
        let mail = """
            From: Syndic Rénov'Est <contact@renovest.example>
            To: Madame Durand <durand@example.org>
            Subject: Rendez-vous pour le ravalement
            Message-ID: <20260904.144512.9812@renovest.example>
            Date: Fri, 04 Sep 2026 14:45:12 +0200
            Content-Type: text/plain; charset=utf-8

            \(french)
            """
        let pages = [PageText(page: 1, text: mail, source: .native)]
        let slices = LanguageDetector.sample(pages: pages)
        XCTAssertEqual(slices.count, 1)
        XCTAssertFalse(slices[0].contains("Message-ID"),
                       "les en-têtes doivent être retirés : \(slices[0])")
        XCTAssertTrue(slices[0].contains("catalyseur"),
                      "le corps du message, lui, reste")
        XCTAssertEqual(LanguageDetector.detect(slices), "fr")
    }

    /// Une ligne à deux points n'est pas un en-tête : le nom d'un en-tête ne
    /// porte ni espace ni accent.
    func testAFrenchSentenceWithAColonIsNotAHeader() {
        XCTAssertTrue(LanguageDetector.looksLikeMailHeader("Subject: Bonjour"))
        XCTAssertTrue(LanguageDetector.looksLikeMailHeader("Message-ID: <1@a>"))
        XCTAssertFalse(LanguageDetector.looksLikeMailHeader(
            "Article 3 : le locataire paie"))
        XCTAssertFalse(LanguageDetector.looksLikeMailHeader("Élément: valeur"))
        XCTAssertFalse(LanguageDetector.looksLikeMailHeader("14:45"))
    }

    /// Du bruit reste du bruit, quelle qu'en soit la quantité : aucune tranche
    /// ne vote, donc aucune langue n'est écrite.
    func testFiveHundredCharactersOfNoiseStayUndetermined() {
        let noise = String(repeating: "12 . 34 . 56 . 78 . 90 . ", count: 20)
        XCTAssertGreaterThanOrEqual(noise.count, 500)
        let pages = [PageText(page: 1, text: noise, source: .native)]
        XCTAssertNil(LanguageDetector.detect(LanguageDetector.sample(pages: pages)))
    }

    /// Un document mêlé moitié-moitié rend la majorité, ou rien — JAMAIS une
    /// troisième langue tirée d'une frontière entre deux.
    func testAHalfAndHalfDocumentNeverInventsAThirdLanguage() {
        let half = String(repeating: french + " ", count: 25)
            + String(repeating: english + " ", count: 25)
        let pages = [PageText(page: 1, text: half, source: .native)]
        let answer = LanguageDetector.detect(LanguageDetector.sample(pages: pages))
        XCTAssertTrue(answer == nil || answer == "fr" || answer == "en",
                      "obtenu « \(answer ?? "nil") »")
    }

    /// Le vote lui-même, sur des tranches choisies : la majorité l'emporte, une
    /// seule tranche valide suffit, une égalité ne tranche rien.
    func testTheVote() {
        XCTAssertEqual(LanguageDetector.detect([french, french, english]), "fr")
        XCTAssertEqual(LanguageDetector.detect([english, "12 34", "?"]), "en",
                       "une seule tranche valide suffit")
        XCTAssertNil(LanguageDetector.detect([french, english]),
                     "une égalité vaut « je ne sais pas »")
        XCTAssertNil(LanguageDetector.detect([]))
    }

    /// Trois groupes de pages NON consécutives = trois tranches : c'est ainsi
    /// que le rattrapage (`GRDBStore.languageSample`) lit trois régions du
    /// document sans en traverser le texte entier.
    func testThreeSeparatedPageGroupsGiveThreeSlices() {
        let pages = [
            PageText(page: 1, text: english, source: .native),
            PageText(page: 50, text: french, source: .native),
            PageText(page: 99, text: french, source: .native),
        ]
        let slices = LanguageDetector.sample(pages: pages)
        XCTAssertEqual(slices.count, 3)
        XCTAssertEqual(LanguageDetector.detect(slices), "fr")
    }

    /// ISO 639-1 STRICT : `NLLanguage.rawValue` rend « zh-Hans » pour le
    /// chinois simplifié, et mélanger deux conventions dans la même colonne la
    /// rendrait inexploitable.
    func testISO639_1KeepsOnlyThePrimarySubtag() {
        XCTAssertEqual(LanguageDetector.iso639_1("zh-Hans"), "zh")
        XCTAssertEqual(LanguageDetector.iso639_1("fr"), "fr")
        XCTAssertEqual(LanguageDetector.iso639_1("EN"), "en")
        XCTAssertNil(LanguageDetector.iso639_1(""))
    }

    // MARK: - Bout en bout : la colonne est réellement écrite

    /// Le test qui compte : après une passe d'indexation, `docs.lang` n'est plus
    /// vide. Le piège que ce cas garde fermé est `upsertDoc`, qui est un no-op
    /// STRICT quand (size, mtime) n'ont pas bougé — c'est-à-dire entre le crawl
    /// et l'extraction de la MÊME passe, le seul moment où l'on connaît le
    /// texte. Écrire la langue via `upsertDoc` ne produirait donc rien du tout.
    func testIndexPassWritesTheLanguageIntoDocs() throws {
        let scratch = try IndexScratch("langue", documents: 0)
        try french.write(to: scratch.root.appendingPathComponent("fr.txt"),
                         atomically: true, encoding: .utf8)
        try english.write(to: scratch.root.appendingPathComponent("en.txt"),
                          atomically: true, encoding: .utf8)
        try "ok.".write(to: scratch.root.appendingPathComponent("court.txt"),
                        atomically: true, encoding: .utf8)

        try IndexPass(store: scratch.store)
            .run(roots: [scratch.rootRecord],
                 options: IndexPassOptions(crawl: .full, warmVocabulary: false))

        var langs: [String: String?] = [:]
        for row in try scratch.documents() {
            langs[(row.record.relPath as NSString).lastPathComponent] = row.record.lang
        }
        XCTAssertEqual(langs["fr.txt"] ?? nil, "fr")
        XCTAssertEqual(langs["en.txt"] ?? nil, "en")
        // Depuis le lot U3, la fin de passe rattrape les documents sans langue
        // et écrit « und » quand la détection ne conclut pas : la colonne n'est
        // plus jamais laissée à NULL sur un document extrait, sinon il serait
        // recandidat au rattrapage à CHAQUE passe, pour la même réponse.
        XCTAssertEqual(langs["court.txt"] ?? nil, FacetKey.undeterminedLanguage,
                       "un texte trop court reçoit le jeton « indéterminé »")
    }
}
