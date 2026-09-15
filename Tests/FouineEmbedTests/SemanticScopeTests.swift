// SemanticScopeTests.swift — ce que le canal du sens VOIT du périmètre demandé
// (lot MC2, constat PM-06). Propriété : A-Embed.
//
// LE FAIT MESURÉ le 13/09/2026 sur la base de production : une recherche
// hybride sur `dossier:M2SU` chargeait le modèle (2,3 s) et l'index vectoriel
// (1,9 s) pour comparer ZÉRO vecteur — le dossier n'en porte pas un seul — puis
// annonçait `semantic_coverage_pct: 67.85`, la couverture GLOBALE, comme si
// elle décrivait le dossier demandé. Le périmètre se lit donc AVANT, et ces
// tests prouvent qu'il est juste et qu'il ne coûte rien quand il ne peut rien
// apprendre.

import XCTest
import FouineCore
@testable import FouineEmbed

final class SemanticScopeTests: XCTestCase {

    /// Deux dossiers : `Livres` vectorisé, `M2SU` pas du tout — la forme exacte
    /// du corpus mesuré.
    private func corpus() throws -> (db: TempDB, livre: Int64, cours: Int64) {
        let db = try makeDB()
        let livre = try addDoc(db, relPath: "Users/a/Livres/manuel.pdf")
        let cours = try addDoc(db, relPath: "Users/a/M2SU/cours.pdf", folder: "M2SU")
        try db.store.replacePages(docID: livre, pages: [
            page(1, "enthalpie libre"), page(2, "energie interne"),
        ])
        try db.store.replacePages(docID: cours, pages: [
            page(1, "bilan de matiere"), page(2, "reacteur piston"),
            page(3, "distribution des temps de sejour"),
        ])
        // Le livre seul est vectorisé : fenêtre 0 réelle, sentinelle vide.
        try db.store.upsertVectors([
            (vecRow(livre, 1, chunk: 0), Data(repeating: 6, count: 384)),
            (vecRow(livre, 1, chunk: Schema.vecWindowMax - 1), Data()),
            (vecRow(livre, 2, chunk: 0), Data(repeating: 6, count: 384)),
            (vecRow(livre, 2, chunk: Schema.vecWindowMax - 1), Data()),
        ])
        return (db, livre, cours)
    }

    private func scope(_ db: TempDB, _ text: String) throws -> SemanticScope {
        let plan = try QueryParser.searchPlan(text)
        return try HybridSearch.scope(store: db.store, query: plan.query,
                                      excludingDocsMatching: plan.negative,
                                      vectors: try db.store.vectorisedPageCount(),
                                      pagesIndexed: try db.store.indexedPageCount())
    }

    func testSansFiltreLePerimetreEstLIndexEntier() throws {
        let c = try corpus()
        let scope = try scope(c.db, "reacteur")
        XCTAssertFalse(scope.filtered)
        XCTAssertEqual(scope.pagesIndexed, 5)
        XCTAssertEqual(scope.vectors, 2)
        XCTAssertEqual(scope.coveragePct, 40, accuracy: 0.001)
    }

    /// LE CAS DU CONSTAT : le dossier filtré n'a aucun vecteur, et la couverture
    /// du périmètre le dit — 0 %, quand la globale en annonçait 40.
    func testUnDossierSansVecteurEstAZeroEtNonALaCouvertureGlobale() throws {
        let c = try corpus()
        let scope = try scope(c.db, "dossier:M2SU reacteur")
        XCTAssertTrue(scope.filtered)
        XCTAssertEqual(scope.vectors, 0)
        XCTAssertEqual(scope.pagesIndexed, 3, "les trois pages du dossier")
        XCTAssertEqual(scope.coveragePct, 0)
    }

    func testUnDossierVectoriseEstComplet() throws {
        let c = try corpus()
        let scope = try scope(c.db, "dossier:Livres enthalpie")
        XCTAssertTrue(scope.filtered)
        XCTAssertEqual(scope.vectors, 2)
        XCTAssertEqual(scope.pagesIndexed, 2)
        XCTAssertEqual(scope.coveragePct, 100)
    }

    /// Le périmètre passe par TOUS les filtres de document, `nom:`, `chemin:` et
    /// les exclusions du lot MC1 comprises : c'est le point unique que le canal
    /// vectoriel de la fusion consulte lui aussi.
    func testLesAutresFiltresDeDocumentComptentAussi() throws {
        let c = try corpus()
        XCTAssertEqual(try scope(c.db, "-dossier:M2SU reacteur").vectors, 2)
        XCTAssertEqual(try scope(c.db, "chemin:M2SU reacteur").vectors, 0)
        XCTAssertEqual(try scope(c.db, "nom:manuel enthalpie").vectors, 2)
    }

    func testLEnsembleAutoriseEstNulSansFiltre() throws {
        let c = try corpus()
        let plan = try QueryParser.searchPlan("reacteur")
        XCTAssertNil(try HybridSearch.scopeDocIDs(store: c.db.store,
                                                  query: plan.query,
                                                  excludingDocsMatching: plan.negative),
                     "sans filtre, il n'y a pas d'ensemble à intersecter — et "
                     + "donc rien à recompter")
        let filtre = try QueryParser.searchPlan("dossier:M2SU reacteur")
        XCTAssertEqual(try HybridSearch.scopeDocIDs(
            store: c.db.store, query: filtre.query,
            excludingDocsMatching: filtre.negative), [c.cours])
    }

    // MARK: - La phrase du périmètre vide (lot MN1)

    /// Elle vit AUPRÈS DE LA RAISON depuis ce lot : la ligne de commande et le
    /// serveur MCP en portaient chacun une copie au mot près, et deux copies
    /// d'une phrase chiffrée finissent par donner deux chiffres. Le texte est
    /// celui du 13/09, au caractère près — c'est un contrat de sortie.
    func testLaPhraseDuPerimetreVideViteAupresDeLaRaison() {
        let un = SemanticScope(vectors: 0, pagesIndexed: 31_986, filtered: true)
        XCTAssertEqual(SemanticDisarmReason.noVectorsInScopeNote(un, folders: ["M2SU"]),
                       "no vectorised page in this scope (folder M2SU: 0 of "
                       + "31986) — `fouine embed --folder M2SU` prepares it")
        // Plusieurs dossiers, ou aucun (un filtre d'extension, de nom, de
        // date) : on parle du « périmètre », faute d'un mot plus vrai, et la
        // campagne proposée est celle qui couvre tout.
        for folders in [[], ["M2SU", "Livres"]] {
            XCTAssertEqual(
                SemanticDisarmReason.noVectorsInScopeNote(un, folders: folders),
                "no vectorised page in this scope (this scope: 0 of 31986) — "
                + "`fouine embed` prepares it", folders.description)
        }
        // La raison, elle, dit le FAIT et rien de plus : les deux phrases ne se
        // publient jamais ensemble.
        XCTAssertEqual(SemanticDisarmReason.noVectorsInScope.advice,
                       "meaning search not used: no page in this scope carries "
                       + "a vector")
    }
}
