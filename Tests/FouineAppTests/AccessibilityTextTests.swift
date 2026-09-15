// AccessibilityTextTests.swift — les phrases que dit VoiceOver (audit U3).
// Propriété : A-App.
//
// Un libellé parlé ne se vérifie autrement qu'en lançant VoiceOver, ce qu'aucun
// test ne peut faire. C'est justement pourquoi la logique est sortie des vues :
// ce qui est ici est ce que l'utilisateur entendra.
//
// LANGUE (palier 3.2, audit U1). `swift test` ne tourne pas depuis Fouine.app :
// `Bundle.main` n'a aucun `.lproj`, `String(localized:)` rend donc la CLÉ,
// c'est-à-dire l'anglais source. Ces assertions portent sur cet anglais-là — la
// STRUCTURE de la phrase, l'ordre de l'information, ce qui est dit et ce qui ne
// l'est pas. Le français se vérifie sur le catalogue (`L10nTests`), qui est ce
// que `xcstringstool` compilera dans `fr.lproj`.
//
// Conséquence visible ici : un compte au singulier se lit « 1 pages ». Ce n'est
// pas ce que voit un utilisateur — les variations de pluriel ne sont dans
// aucun `.stringsdict` tant qu'il n'y a pas de bundle — et c'est justement ce
// que `L10nTests.testPluralKeysCarryBothFormsInBothLanguages` vérifie à part.

import XCTest
import FouineCore
@testable import FouineApp

final class AccessibilityTextTests: XCTestCase {

    private func root(label: String = "Thèse", enabled: Bool = true,
                      mounted: Bool = true, readable: Bool = true,
                      path: String? = "/Users/x/Thèse",
                      reason: String? = nil) -> RootStatus {
        RootStatus(
            record: RootRecord(id: 1, volUUID: "VOL", relPath: "Users/x/Thèse",
                               label: label, enabled: enabled),
            absolutePath: path, mounted: mounted, readable: readable,
            reason: reason)
    }

    // MARK: - Nombres

    /// Le point de la règle : les nombres parlés ne portent AUCUN séparateur de
    /// milliers, quel qu'il soit — le synthétiseur coupe « 1 203 » en deux
    /// nombres, et « 1,203 » ne vaut pas mieux.
    ///
    /// L'affichage, lui, groupe — mais avec le séparateur de `Locale.current`,
    /// et non plus une espace fine insécable imposée à toutes les langues :
    /// l'assertion porte donc sur la locale, pas sur une constante (audit
    /// B1-13). En `en_US` c'est la virgule, en `fr_FR` U+202F.
    func testCompteSansSeparateurDeMilliers() {
        XCTAssertEqual(AccessibilityText.documents(1_203), "1203 documents")
        XCTAssertFalse(AccessibilityText.pages(1_203).contains("\u{202F}"))

        let separator = Locale.current.groupingSeparator ?? ""
        let affiche = Format.integer(1_203)
        XCTAssertEqual(affiche, "1\(separator)203",
                       "le groupement est celui de Locale.current, "
                       + "et non une constante posée dans le code")
    }

    // MARK: - Racines

    func testLibelleDeRacineSelonLEtat() {
        XCTAssertEqual(AccessibilityText.rootLabel(root()),
                       "Folder Thèse, active")
        XCTAssertEqual(AccessibilityText.rootLabel(root(enabled: false)),
                       "Folder Thèse, paused")
        XCTAssertEqual(AccessibilityText.rootLabel(root(mounted: false)),
                       "Folder Thèse, disk not plugged in")
        XCTAssertEqual(AccessibilityText.rootLabel(root(readable: false)),
                       "Folder Thèse, read denied")
    }

    /// Le hint reprend ce que dit le `.help()` — que VoiceOver ne lit jamais —
    /// et le fait précéder de l'effet du clic.
    func testHintDeRacineReprendLInfobulle() {
        let hint = AccessibilityText.rootHint(root(), filtering: false)
        XCTAssertTrue(hint.hasPrefix("Filters results on this folder."), hint)
        XCTAssertTrue(hint.hasSuffix("/Users/x/Thèse"), hint)

        // Le motif est repris TEL QUEL : il vient de `RootProbeText`, déjà
        // localisé. Plus de « TCC » dans aucune des deux langues (audit B1-25).
        let motif = "lecture refusée (Confidentialité et sécurité, ou droits du fichier)"
        let bloque = AccessibilityText.rootHint(
            root(readable: false, reason: motif),
            filtering: true)
        XCTAssertTrue(bloque.hasPrefix("Removes the filter on this folder."),
                      bloque)
        XCTAssertTrue(bloque.contains(motif), bloque)
    }

    // MARK: - Facettes

    func testFacetteLibelleEtValeur() {
        XCTAssertEqual(AccessibilityText.facetLabel("md"), "Facet md")
        XCTAssertEqual(AccessibilityText.facetValue(pages: 12), "12 pages")
        XCTAssertEqual(AccessibilityText.facetHint(.ext, selected: false),
                       "Adds this value to the file types filter.")
        XCTAssertEqual(AccessibilityText.facetHint(.folder, selected: true),
                       "Removes this value from the folders filter.")
    }

    // MARK: - En-têtes de groupe

    /// Le même arbitrage honnête qu'à l'écran (audit A12) : « chargées » tant
    /// que le comptage différé n'a pas répondu, jamais un total inventé.
    func testValeurDeGroupeDitChargeesPuisTouchees() {
        XCTAssertEqual(AccessibilityText.groupValue(loaded: 200, matched: nil),
                       "200 loaded pages")
        XCTAssertEqual(AccessibilityText.groupValue(loaded: 200, matched: 400),
                       "200 loaded pages of 400 matched pages")
        XCTAssertEqual(AccessibilityText.groupValue(loaded: 3, matched: 3),
                       "3 matched pages")
    }

    // MARK: - Lignes de résultat

    /// L'insigne « ≈ » et le pictogramme de provenance étaient purement
    /// visuels : ce sont ces trois phrases qui les remplacent.
    func testLibelleDeResultatSelonLeCanal() {
        let exact = AccessibilityText.hitLabel(
            fileName: "Clayden.pdf", page: 247, source: .native, engine: .none,
            semanticOnly: false, fuzzyDistance: 0)
        XCTAssertEqual(exact,
                       "Clayden.pdf, page 247, typed text, "
                       + "found by exact search")

        let flou = AccessibilityText.hitLabel(
            fileName: "scan.pdf", page: 12, source: .ocrAccurate,
            engine: .vision, semanticOnly: false, fuzzyDistance: 2)
        XCTAssertEqual(flou,
                       "scan.pdf, page 12, scanned, recognised by Fouine, "
                       + "approximate result, close spelling, 2 letters apart")

        // Sémantique pur : la provenance n'est PAS connue sans un balayage de
        // page_src — on ne l'invente pas, exactement comme la vue qui affiche
        // l'insigne du canal à la place du pictogramme.
        let semantique = AccessibilityText.hitLabel(
            fileName: "notes.md", page: 3, source: .native, engine: .none,
            semanticOnly: true, fuzzyDistance: 0)
        XCTAssertEqual(semantique,
                       "notes.md, page 3, approximate result, "
                       + "found by meaning")
    }

    // MARK: - AP-03 : une seule table des provenances

    /// LES QUATRE SURFACES DISENT LA MÊME CHOSE. La facette « Origine du
    /// texte » disait « texte tapé » quand l'en-tête de l'aperçu, le
    /// pictogramme d'une ligne de résultat et ce libellé parlé disaient
    /// « texte natif » — pour la même page, sur le même écran (capture
    /// `20-facettes-origine.png`). Le pictogramme n'étant qu'un appel à
    /// `LanguageNames.sourceLabel`, ce sont bien les quatre qui sont ici.
    func testLesQuatreSurfacesNommentUneProvenanceDeLaMemeFacon() {
        let cases: [(PageSource, OCREngineID, String)] = [
            (.native, .none, "native"),
            (.ocrAccurate, .vision, "ocr_accurate"),
            (.transcript, .none, "transcript"),
        ]
        for (source, engine, raw) in cases {
            let facet = LanguageNames.sourceLabel(raw)
            let preview = Provenance(source: source, engine: engine).label
            let spoken = AccessibilityText.textSource(source, engine: engine)
            let icon = LanguageNames.sourceLabel(source, engine: engine)
            XCTAssertEqual(preview, facet, "aperçu vs facette (\(raw))")
            XCTAssertEqual(spoken, facet, "VoiceOver vs facette (\(raw))")
            XCTAssertEqual(icon, facet, "ligne de résultat vs facette (\(raw))")
        }
    }

    /// Une couche texte VENUE AVEC LE FICHIER : « OCR importé » d'un côté,
    /// « texte OCR importé » de l'autre. Un seul libellé, désormais.
    func testLeTexteReconnuAvantFouineNAQuUnSeulNom() {
        let preview = Provenance(source: .ocrAccurate, engine: .external).label
        let spoken = AccessibilityText.textSource(.ocrAccurate, engine: .external)
        XCTAssertEqual(preview, spoken)
        XCTAssertEqual(preview, String(localized: "scanned, recognised before Fouine"))
    }

    /// Les marqueurs « » du snippet FTS5 se prononcent : ils sautent.
    func testExtraitSansLesMarqueursFTS5() {
        XCTAssertEqual(
            AccessibilityText.snippetValue("…la «thermodynamique» des «gaz»…"),
            "snippet: …la thermodynamique des gaz…")
        XCTAssertEqual(AccessibilityText.snippetValue("deux\nlignes"),
                       "snippet: deux lignes")
        XCTAssertEqual(AccessibilityText.snippetValue("   "), "empty snippet")
    }

    // MARK: - Compteurs

    func testCompteursDeLaLigneDEtat() {
        XCTAssertEqual(
            AccessibilityText.resultCounts(pages: 1_203, docs: 12, hybrid: false),
            "1203 pages found in 12 documents")
        XCTAssertEqual(
            AccessibilityText.resultCounts(pages: 4, docs: 2, hybrid: true),
            "4 merged pages in 2 documents")
    }
}

// MARK: - Carte « Index » (UX-03, épurée par IX2)

extension AccessibilityTextTests {

    /// La carte se lit en UNE phrase, et elle dit ce qu'elle montre — ni plus,
    /// ni moins. En travail, le nom du document et « 1 203 / 4 000 pages » ont
    /// quitté la carte (IX2) : VoiceOver ne doit pas lire une autre carte que
    /// celle qu'on voit.
    func testCarteEnTravailSeLitEnUnePhrase() {
        let status = IndexStatus.working(
            activity: .readingScans,
            progress: IndexProgress(done: 1_203, total: 4_000,
                                    remainingSeconds: 7_200),
            detail: "Clayden.pdf", stoppable: false)
        let spoken = AccessibilityText.indexCard(
            IndexCardSummary(status: status, disk: .silent))
        XCTAssertTrue(spoken.contains("Reading scanned pages"), spoken)
        XCTAssertTrue(spoken.contains("2 h"), spoken)
        XCTAssertFalse(spoken.contains("Clayden.pdf"), spoken)
        XCTAssertFalse(spoken.contains("/"), spoken)
    }

    /// Sans temps restant connu, la carte montre un titre et une barre : la
    /// phrase ne doit pas inventer d'avancement.
    func testCarteSansTotalNAnnoncePasDAvancement() {
        let status = IndexStatus.working(activity: .updating, progress: nil,
                                         detail: nil, stoppable: true)
        let spoken = AccessibilityText.indexCard(
            IndexCardSummary(status: status, disk: .silent))
        XCTAssertEqual(spoken, IndexStatusText.headline(status))
        XCTAssertFalse(spoken.contains("/"), spoken)
    }

    /// La ligne d'avancement de la fenêtre « Votre index » se dit en nombres
    /// NUS : « 1 203 / 4 000 » groupé à l'espace fine se prononce « un, deux
    /// cent trois ».
    func testLigneDAvancementDeLaFenetreEnNombresNus() {
        let spoken = AccessibilityText.progressLine(
            IndexProgress(done: 1_203, total: 4_000, remainingSeconds: nil))
        XCTAssertTrue(spoken.contains("1203 / 4000"), spoken)
    }
}
