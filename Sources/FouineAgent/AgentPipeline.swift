// AgentPipeline.swift — l'adaptateur agent d'`IndexPass` (SPEC §5.7).
// Propriété : A-Pack.
//
// Ce fichier était le pendant d'arrière-plan de `Sources/fouine/Pipeline.swift`,
// « RECODÉ et non importé : la CLI est un exécutable, on n'importe pas un
// exécutable ». La règle était juste, la conséquence l'était moins : trois
// copies, cinq divergences (audit F2). La passe vit désormais dans une
// BIBLIOTHÈQUE, `FouineIndex`, que les trois importent.
//
// Ce que l'agent garde en propre, et qui justifie encore un fichier :
//   · son journal (`AgentLog`) et la forme exacte de ses lignes ;
//   · une passe PAR RACINE, pour rester aligné sur ses salves FSEvents ;
//   · l'absence d'`optimize` : le §5.1 le réserve à « une passe d'indexation
//     complète », et une salve porte deux ou trois fichiers — fusionner les
//     segments d'un index de 1,6 Go coûterait infiniment plus qu'elle ne
//     rapporte. `vocab_tri`, lui, est réalimenté une fois la file de racines
//     vidée (§5.5.2), sans quoi l'expansion floue prendrait du retard.
//
// Ce qu'il a GAGNÉ au passage : la fin du `try? setDocState` (audit X3), qui
// laissait un document bloqué en `.discovered` et le faisait ré-extraire à
// chaque salve, indéfiniment et sans un mot.

import Foundation
import FouineCore
import FouineIndex

struct AgentPipeline {

    let store: GRDBStore
    let log: AgentLog
    /// Réglages relus au démarrage de CHAQUE passe (audit U2) : le nombre de
    /// fils d'extraction était une variable d'environnement figée au lancement
    /// du démon, donc impossible à changer sans redémarrer launchd.
    let settings: Settings
    /// L'état publié dans `agent_status` (audit F7).
    let status: AgentStatusWriter

    init(store: GRDBStore, log: AgentLog, settings: Settings,
         status: AgentStatusWriter) {
        self.store = store
        self.log = log
        self.settings = settings
        self.status = status
    }

    /// Une passe complète sur UNE racine : crawl delta puis extraction.
    ///
    /// Ne lève que sur une erreur fatale (§4.2) — volume démonté, panne de base,
    /// verrou tenu par l'app ou la CLI. Un document en échec reste un document
    /// en échec : `.failed`, `docs.err`, et le lot continue (piège n°13).
    func index(root: RootRecord,
               shouldStop: @escaping @Sendable () -> Bool) throws {
        let observer = Journal(log: log, label: root.label, status: status)
        let jobs = max(1, settings.snapshot().agentExtractJobs)
        let summary = try IndexPass(store: store, observer: observer,
                                    shouldStop: shouldStop)
            .run(roots: [root],
                 options: IndexPassOptions(crawl: .delta, jobs: jobs,
                                           optimize: false,
                                           warmVocabulary: false,
                                           role: .agent))
        let c = summary.counters
        guard c.extracted + c.skipped + c.failed > 0 else { return }
        log.info("extraction [\(root.label)] — extracted \(c.extracted) · "
                 + "pages \(c.pages) · queued for OCR \(c.queued) · "
                 + "skipped \(c.skipped) · failed \(c.failed)")
    }

    /// Réalimentation de `vocab_tri` (§5.5.2). Idempotente et incrémentale.
    func warmVocabulary() {
        do { try store.warmVocabulary() }
        catch { log.warn("vocab_tri: \(AgentText.describe(error))") }
    }

    /// Les lignes du journal, et — depuis F7 — l'état publié dans
    /// `agent_status`.
    ///
    /// `IndexPass` avertit qu'un observateur « ne doit jamais rappeler la
    /// base » : il est appelé depuis les fils d'extraction, au milieu du lot.
    /// L'exception est ASSUMÉE et bornée. `AgentStatusWriter` n'écrit qu'une
    /// fois toutes les deux secondes, sept lignes de quelques octets, et jamais
    /// à l'intérieur d'une transaction de la passe — les événements partent
    /// APRÈS que l'écriture du document soit rendue. Ce que cela coûte : deux
    /// ou trois transactions par minute, sérialisées par le pool derrière celles
    /// de l'extraction. Ce que cela rapporte : une barre de progression pour un
    /// travail de vingt heures.
    ///
    /// Ce chiffre était faux jusqu'à A2-10 : le `.document` ci-dessous publie
    /// un détail DIFFÉRENT à chaque document abouti, et un détail qui change
    /// forçait l'écriture. Une transaction par document, donc. La cadence
    /// s'applique désormais aussi au détail — le nom qui défile n'est pas une
    /// information nouvelle, c'est la même, plus précise.
    private struct Journal: IndexPassObserver {
        let log: AgentLog
        let label: String
        let status: AgentStatusWriter

        func indexPass(_ event: IndexPassEvent) {
            switch event {
            case .willCrawl(let root):
                status.publish(.crawl, detail: root, resetProgress: true)
            case .crawled(_, let s):
                log.info("crawl delta [\(label)] — seen \(s.seen) · added "
                         + "\(s.added) · updated \(s.updated) · removed "
                         + "\(s.removed) · skipped \(s.skipped)")
            case .extractionWillStart(let total):
                status.publish(.extract, detail: label, done: 0, total: total)
            case .document(let outcome):
                // Le dernier document ABOUTI : `IndexPass` n'émet pas de « je
                // commence celui-ci », et il n'y en aurait de toute façon pas un
                // seul — l'extraction tourne à plusieurs fils. C'est ce que
                // l'utilisateur veut voir défiler.
                status.publish(.extract, detail: AgentStatusDetail.document(
                    (outcome.relPath as NSString).lastPathComponent))
            case .progress(let counters):
                status.progress(done: counters.done, total: counters.total)
            case .note(let message):
                log.info(message)
            default:
                break
            }
        }
    }
}

/// Traductions d'erreurs. Le §4.3 veut la MÊME phrase dans les trois outils :
/// elle vient donc d'`IndexText` (FouineIndex), pas d'une quatrième copie du
/// même `switch`. Le nom reste, il est appelé depuis tout l'agent.
enum AgentText {
    static func describe(_ error: Error) -> String { IndexText.describe(error) }
}
