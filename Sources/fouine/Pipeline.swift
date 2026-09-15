// Pipeline.swift — l'adaptateur CLI d'`IndexPass` (SPEC §4.3, §5.3, §6.1).
// Propriété : A-Core.
//
// Il ne reste ici que ce qui est PROPRE à la ligne de commande : la résolution
// de `--root`, les lignes imprimées, et les codes de sortie du §4.3 — dont la
// sortie 4, que seule la CLI produit (`--budget-minutes`). Le parcours,
// l'extraction, la mise en file OCR, le verrou et le tri des erreurs sont dans
// `FouineIndex` (audit F2), partagés mot pour mot avec l'app et l'agent.

import Foundation
import FouineCore
import FouineIndex

enum Pipeline {

    /// Les lignes que la CLI imprime. Rien d'autre ne sort de la passe.
    private struct Printer: IndexPassObserver {
        func indexPass(_ event: IndexPassEvent) {
            switch event {
            case .crawled(let root, let s):
                // `moved` n'apparaît QUE s'il y en a : sur une passe ordinaire
                // il vaut 0, et une colonne toujours nulle n'apprend rien.
                print("[\(root)] seen \(s.seen) · added \(s.added) "
                      + "· updated \(s.updated) · removed \(s.removed) "
                      + "· skipped \(s.skipped)"
                      + (s.moved > 0 ? " · moved \(s.moved)" : ""))
            case .extractionWillStart(let total) where total == 0:
                // Imprimé AVANT la consolidation (`optimize` + `vocab_tri`,
                // 18-25 s) : c'est l'ordre qu'un second `fouine index` donnait.
                print("no document to extract")
            case .note(let message):
                // Troncature de `--jobs`, reprise d'un verrou périmé : sur la
                // sortie standard, comme le faisait `JobsCap.clampExtract`.
                print(message)
            default:
                break
            }
        }
    }

    private static func pass(store: GRDBStore) -> IndexPass {
        IndexPass(store: store, observer: Printer(),
                  crawler: makeCrawler(store: store),
                  registry: makeExtractorRegistry(store: store))
    }

    // MARK: - crawl

    static func crawl(store: GRDBStore, rootSelector: String?, mode: CrawlMode) throws {
        let roots: [RootRecord]
        if let selector = rootSelector {
            roots = [try CLI.resolveRoot(store, selector: selector)]
        } else {
            let all = try store.roots()
            // Base neuve : plus aucune racine implicite depuis D1. Sans ce
            // message, `fouine index` affichait « aucun document à extraire » et
            // sortait en 0 — l'utilisateur concluait que son corpus était vide.
            if all.isEmpty { CLI.dieNoRoots() }
            roots = all.filter(\.enabled)
        }
        if roots.isEmpty { print("no active root"); return }
        // Pas de consolidation ici : `fouine crawl` n'écrit aucune page, il n'y
        // a ni segment FTS5 à fusionner ni vocabulaire à réalimenter.
        try pass(store: store).run(
            roots: roots,
            options: IndexPassOptions(crawl: mode, extract: false,
                                      optimize: false, warmVocabulary: false,
                                      role: .cli))
    }

    // MARK: - extract

    static func extract(store: GRDBStore, jobs: Int, budgetMinutes: Int?,
                        only: String?) throws {
        let roots = try store.roots().filter(\.enabled)
        let summary = try pass(store: store).run(
            roots: roots,
            options: IndexPassOptions(crawl: nil, extract: true, only: only,
                                      jobs: jobs,
                                      budget: .minutes(budgetMinutes),
                                      role: .cli))
        let s = summary.counters
        if s.total > 0 {
            print("extracted \(s.extracted) · pages \(s.pages) "
                  + "· queued for OCR \(s.queued) · skipped \(s.skipped) "
                  + "· failed \(s.failed)")
        }
        // Sortie 4 (§4.3) : le budget est le seul arrêt que la CLI signale par
        // un code. Les erreurs fatales ont déjà remonté depuis `run`.
        if s.budgetSkipped > 0 {
            throw FouineError.budgetExhausted(remaining: s.budgetSkipped)
        }
    }
}
