// MorphologyTests.swift — singulier et pluriel à la requête (lot R1).
// Propriété : A-Core.
//
// Ce que ces tests prouvent : les règles rendent les formes attendues sur les
// mots du corpus (français et anglais), se taisent sur les pièges connus du
// français (`temps`, `mois`, `corps`), et ne touchent ni aux phrases, ni aux
// préfixes, ni à l'intérieur d'un NEAR dans une chaîne FTS5.

import XCTest
@testable import FouineCore

final class MorphologyTests: XCTestCase {

    // MARK: - Les formes

    func testSingularGetsItsPlural() {
        XCTAssertEqual(Morphology.variants(of: "polymere"), ["polymeres"])
        XCTAssertEqual(Morphology.variants(of: "acide"), ["acides"])
        XCTAssertEqual(Morphology.variants(of: "liaison"), ["liaisons"])
        XCTAssertEqual(Set(Morphology.variants(of: "metal")), ["metaux", "metals"])
        XCTAssertEqual(Set(Morphology.variants(of: "reseau")), ["reseaux", "reseaus"])
        XCTAssertEqual(Set(Morphology.variants(of: "energy")), ["energies", "energys"])
        XCTAssertEqual(Morphology.variants(of: "process"), ["processes"])
    }

    func testPluralGetsItsSingular() {
        XCTAssertEqual(Morphology.variants(of: "polymeres"), ["polymere"])
        XCTAssertEqual(Morphology.variants(of: "liaisons"), ["liaison"])
        XCTAssertEqual(Morphology.variants(of: "phases"), ["phase"],
                       "« phases » → « phase », et surtout pas « phas »")
        XCTAssertEqual(Morphology.variants(of: "acides"), ["acide"],
                       "« acides » ne doit pas devenir l'anglais « acid »")
        XCTAssertTrue(Morphology.variants(of: "metaux").contains("metal"))
        XCTAssertTrue(Morphology.variants(of: "energies").contains("energy"))
        XCTAssertTrue(Morphology.variants(of: "energies").contains("energie"),
                      "« énergies » est aussi un pluriel français")
        XCTAssertTrue(Morphology.variants(of: "processes").contains("process"))
    }

    /// Les singuliers français en -s dont la forme tronquée est un AUTRE mot
    /// (souvent très fréquent) : sous cinq lettres, on ne retire rien ; à cinq,
    /// une liste fermée protège `temps`, `corps`, `cours`, `fonds`.
    func testShortFrenchWordsEndingInSAreLeftAlone() {
        for word in ["temps", "corps", "cours", "fonds", "mois", "fois", "pays", "sens", "bras"] {
            XCTAssertEqual(Morphology.variants(of: word), [],
                           "« \(word) » ne doit produire aucune forme")
        }
    }

    /// AUDIT-R1 I3 : à six lettres, `bases` ne trouvait pas `base` alors que
    /// `base` trouvait `bases`. Le seuil est à cinq ; à quatre (`lois`, `ions`),
    /// la longueur seule protège encore `mois`, `fois`, `pays` — et c'est la
    /// limite écrite dans la doc.
    func testFiveLetterPluralsFindTheirSingular() {
        XCTAssertEqual(Morphology.variants(of: "bases"), ["base"])
        XCTAssertEqual(Morphology.variants(of: "ondes"), ["onde"])
        XCTAssertEqual(Morphology.variants(of: "types"), ["type"])
        XCTAssertEqual(Morphology.variants(of: "zones"), ["zone"])
        XCTAssertEqual(Morphology.variants(of: "pages"), ["page"])
        XCTAssertEqual(Morphology.variants(of: "atoms"), ["atom"])
        XCTAssertEqual(Morphology.variants(of: "lois"), [], "quatre lettres : pas de singulier")
        XCTAssertEqual(Morphology.variants(of: "ions"), [])
    }

    /// AUDIT-R1 M2 : la règle « radical en -x → +es » ne doit pas fabriquer
    /// « metauxes », « deuxes », « prixes » sur des pluriels français en -x.
    func testFrenchPluralsInXGetNoPhantomEs() {
        XCTAssertEqual(Morphology.variants(of: "metaux"), ["metal", "metau"])
        XCTAssertEqual(Morphology.variants(of: "deux"), [])
        XCTAssertEqual(Morphology.variants(of: "prix"), [])
        XCTAssertEqual(Morphology.variants(of: "taux"), [])
        XCTAssertEqual(Morphology.variants(of: "flux"), ["fluxes"], "l'anglais « fluxes » existe")
        XCTAssertEqual(Morphology.variants(of: "complex"), ["complexes"], "et pas « comple »")
        XCTAssertEqual(Morphology.variants(of: "cheveux"), ["cheveu"])
        XCTAssertEqual(Morphology.variants(of: "milieux"), ["milieu"])
        XCTAssertEqual(Morphology.variants(of: "index"), ["indexes"])
    }

    // MARK: - Deux mots tapés qui partagent une forme (AUDIT-R1 B1)

    /// `entropy entropie` : « entropies » est une forme des DEUX mots. La donner
    /// aux deux faisait du ET un OU (une page ne portant que « entropies »
    /// satisfaisait les deux groupes) ; elle ne va à aucun.
    func testAFormSharedByTwoTypedWordsGoesToNeither() {
        let words = ["entropy", "entropie"]
        XCTAssertEqual(Morphology.variants(of: "entropy", among: words), ["entropys"])
        XCTAssertEqual(Morphology.variants(of: "entropie", among: words), [])
        XCTAssertEqual(Morphology.variants(of: "energie", among: ["energy", "energie"]), [])
        XCTAssertEqual(Morphology.variants(of: "theory", among: ["theory", "theorie"]), ["theorys"])
    }

    /// Un mot tapé qui EST la forme d'un autre mot tapé n'est pas absorbé :
    /// `polymere polymeres` reste un vrai ET des deux formes.
    func testATypedWordIsNeverAVariantOfAnotherTypedWord() {
        let words = ["polymere", "polymeres"]
        XCTAssertEqual(Morphology.variants(of: "polymere", among: words), [])
        XCTAssertEqual(Morphology.variants(of: "polymeres", among: words), [])
        XCTAssertEqual(Morphology.forms(of: "polymere", among: words), ["polymere"])
    }

    /// Des mots sans forme commune gardent toutes leurs formes ; un mot tapé
    /// deux fois n'est pas « un autre mot ».
    func testUnrelatedWordsKeepAllTheirForms() {
        XCTAssertEqual(Set(Morphology.variants(of: "metal", among: ["metal", "reseau"])),
                       ["metaux", "metals"])
        XCTAssertEqual(Morphology.variants(of: "acide", among: ["acide", "Acide"]), ["acides"])
        XCTAssertEqual(Morphology.variants(of: "acide", among: []), ["acides"])
    }

    func testExpansionsDropSharedFormsAndTheStoreRewritesAccordingly() {
        XCTAssertEqual(Morphology.expansions(forBareWordsIn: "entropy AND entropie"),
                       ["entropy": ["entropys"]])
        XCTAssertEqual(Morphology.expansions(forBareWordsIn: "polymere AND polymeres"), [:])
        XCTAssertEqual(GRDBStore.effectiveFTS("polymere AND polymeres", morphology: true),
                       "polymere AND polymeres")
        XCTAssertEqual(GRDBStore.effectiveFTS("energie AND energy", morphology: true),
                       "energie AND (\"energy\" OR \"energys\")")
    }

    func testTooShortOrNonAlphabeticWordsHaveNoForm() {
        XCTAssertEqual(Morphology.variants(of: "gaz"), [])
        XCTAssertEqual(Morphology.variants(of: "ion"), [])
        XCTAssertEqual(Morphology.variants(of: "h2o"), [])
        XCTAssertEqual(Morphology.variants(of: ""), [])
        XCTAssertEqual(Morphology.variants(of: "   "), [])
    }

    /// Les formes sont repliées comme les jetons de l'index : accents et casse
    /// n'entrent pas en compte, et le mot tapé vient en tête de `forms`.
    func testFormsAreFoldedAndStartWithTheTypedWord() {
        XCTAssertEqual(Morphology.forms(of: "Polymères"), ["polymeres", "polymere"])
        XCTAssertEqual(Morphology.forms(of: "Énergie"), ["energie", "energies"])
        XCTAssertEqual(Morphology.forms(of: "gaz"), ["gaz"])
    }

    // MARK: - Dans une chaîne FTS5

    func testBareWordsSkipPhrasesPrefixesNearAndOperators() {
        let fts = "polymere AND \"gaz parfait\" AND spectro* AND NEAR(azote reduction, 5) AND Acide"
        XCTAssertEqual(Morphology.bareWords(in: fts), ["polymere", "Acide"])
    }

    func testExpansionsAreKeyedInLowercaseAndOnlyForWordsWithForms() {
        let table = Morphology.expansions(forBareWordsIn: "Polymere AND gaz AND acide")
        XCTAssertEqual(table["polymere"], ["polymeres"])
        XCTAssertEqual(table["acide"], ["acides"])
        XCTAssertNil(table["gaz"], "un mot sans forme n'entre pas dans la table")
        XCTAssertNil(table["Polymere"], "les clés sont en minuscules")
    }

    /// Le store réécrit la chaîne avec `substitute` : le résultat est du FTS5
    /// valide, et une racine de préfixe n'est jamais réécrite.
    func testEffectiveFTSRewritesBareWordsOnly() {
        let fts = "polymere AND \"gaz parfait\" AND spectro* AND NEAR(azote reduction, 5)"
        let expanded = GRDBStore.effectiveFTS(fts, morphology: true)
        XCTAssertEqual(expanded,
                       "(\"polymere\" OR \"polymeres\") AND \"gaz parfait\" AND spectro* AND NEAR(azote reduction, 5)")
        XCTAssertEqual(GRDBStore.effectiveFTS(fts, morphology: false), fts)
    }

    func testAWordUsedBothBareAndAsPrefixKeepsThePrefixIntact() {
        let expanded = GRDBStore.effectiveFTS("spectro AND spectro*", morphology: true)
        XCTAssertEqual(expanded, "(\"spectro\" OR \"spectros\") AND spectro*")
    }

    // MARK: - L'explication connaît les formes

    func testQueryWordCarriesItsVariantsAndTheExplanationAcceptsThem() throws {
        let word = QueryWord("polymere")
        XCTAssertEqual(word.variants, ["polymeres"])
        XCTAssertEqual(QueryWord("gaz parfait", kind: .phrase).variants, [])
        XCTAssertEqual(QueryWord("spectro", kind: .prefix).variants, [])

        let explanation = HitExplanation(words: [word],
                                         text: "Les polymères sont de longues chaînes.")
        XCTAssertEqual(explanation, .exact(terms: ["polymere"]),
                       "la page porte le pluriel : c'est le mot tapé qu'on cite")
        let absent = HitExplanation(words: [word], text: "Rien à voir ici.")
        XCTAssertNil(absent)
    }

    /// Les mots d'une requête analysée portent les formes que le MOTEUR a
    /// cherchées : parmi les autres mots tapés (B1), et aucune pour un membre
    /// de `pres:`, que FTS5 ne décline pas (AUDIT-R1 M1).
    func testWordsOfAQueryFollowTheEngine() {
        let shared = HitExplanation.words(ofQuery: "entropy entropie")
        XCTAssertEqual(shared.map(\.text), ["entropy", "entropie"])
        XCTAssertEqual(shared.map(\.variants), [["entropys"], []])

        let near = HitExplanation.words(ofQuery: "pres:3 azote reduction")
        XCTAssertEqual(near.map(\.text), ["azote", "reduction"])
        XCTAssertTrue(near.allSatisfy { $0.variants.isEmpty },
                      "un membre de pres: n'a pas de forme : le moteur n'en cherche pas")

        let plain = HitExplanation.words(ofQuery: "polymere")
        XCTAssertEqual(plain.map(\.variants), [["polymeres"]])
    }
}
