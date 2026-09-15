// AgentStatusWriter.swift — l'agent cesse d'être une boîte noire. A-Pack, F7.
//
// « Seul diagnostic : `tail -f` du journal ; `agentStatusText` ne dit jamais ce
//   que l'agent fait ni où en est la file ; aucune notification. Pour un travail
//   de vingt heures, c'est le point d'abandon le plus probable. » (audit F7)
//
// L'agent publie donc son état dans `agent_status` (schéma v4), et l'app le lit.
// Trois précautions, chacune motivée :
//
//   1. ÉCRITURE MENUE ET RARE. Une transaction de sept `UPSERT` sur une table de
//      sept lignes, au plus toutes les 2 s pendant un lot — et immédiatement à
//      chaque CHANGEMENT DE PHASE, parce que c'est le seul moment où l'attente
//      de l'utilisateur est réellement suspendue à l'information. Un lot d'OCR
//      de dix minutes coûte ainsi ~300 écritures de quelques centaines d'octets,
//      contre plusieurs centaines de pages écrites dans le même temps.
//
//      Cet invariant a longtemps été FAUX (A2-10). Un changement de DÉTAIL
//      comptait comme un changement de phase, et `AgentPipeline` publie le nom
//      du document à chaque document abouti : c'était UNE TRANSACTION PAR
//      DOCUMENT — 1 329 sur le corpus de recette, 30 000 sur un corpus neuf,
//      sérialisées par le même pool que les écritures d'extraction. Le nom qui
//      défile est un raffinement de la même information, pas une information
//      nouvelle : il suit désormais la cadence. La phase, elle, passe toujours
//      outre.
//
//   2. PAS DE `fouine.lock`. Voir l'en-tête de `GRDBStore+Settings.swift` : le
//      verrou est réservé aux écritures d'indexation. Pendant une passe, l'agent
//      le tient déjà et l'écriture passe par le même pool ; au repos, il l'a
//      rendu, et une transaction courte suffit. Vérifié contre `EmbedRun` : sa
//      boucle `patiently` ne réessaie que sur `WriteLock.isBusy`, c'est-à-dire
//      sur le message de `flock` — qu'une écriture d'état ne produit jamais.
//
//   3. UNE PANNE D'ÉTAT N'ARRÊTE RIEN. `agent_status` est de la télémétrie : si
//      la base refuse l'écriture, on le dit UNE fois dans le journal et l'agent
//      continue son travail. L'inverse — un agent qui s'arrête parce qu'il n'a
//      pas pu dire ce qu'il faisait — serait une régression franche.

import Foundation
import FouineCore

final class AgentStatusWriter: @unchecked Sendable {

    /// Cadence maximale en régime de travail. Deux secondes : c'est aussi la
    /// période de lecture de l'app quand sa fenêtre est visible, donc au pire
    /// un battement de retard.
    static let minimumInterval: TimeInterval = 2

    private let store: GRDBStore
    private let log: AgentLog
    private let mutex = NSLock()

    private var current: AgentStatusRecord
    private var lastWrite = Date.distantPast
    /// L'échec d'écriture n'est journalisé qu'une fois par épisode : une base
    /// qui refuse l'état la refusera aussi aux 300 écritures suivantes.
    private var complained = false

    init(store: GRDBStore, log: AgentLog) {
        self.store = store
        self.log = log
        self.current = AgentStatusRecord(phase: .idle, startedAt: Date())
    }

    /// Publie une phase. Écrit TOUT DE SUITE si la PHASE change, sinon au plus
    /// une fois toutes les `minimumInterval` secondes — un détail qui change
    /// (le document qui défile) est lissé comme la progression (A2-10).
    ///
    /// - Parameter resetProgress: remet `done`/`total` à zéro. Une phase qui
    ///   n'a pas de progression (attente, repos) ne doit pas garder à l'écran
    ///   la barre du lot précédent.
    func publish(_ phase: AgentStatusRecord.Phase, detail: String = "",
                 done: Int? = nil, total: Int? = nil,
                 resetProgress: Bool = false) {
        mutex.lock()
        var status = current
        let changedPhase = status.phase != phase
        if changedPhase { status.startedAt = Date() }
        status.phase = phase
        status.detail = detail
        if resetProgress {
            status.done = 0
            status.total = 0
        }
        if let done { status.done = done }
        if let total { status.total = total }
        status.updatedAt = Date()
        current = status

        let due = changedPhase
            || Date().timeIntervalSince(lastWrite) >= Self.minimumInterval
        if due { lastWrite = Date() }
        mutex.unlock()

        guard due else { return }
        write(status)
    }

    /// Progression seule, sans changement de phase (extraction, lot d'OCR).
    func progress(done: Int, total: Int, detail: String? = nil) {
        mutex.lock()
        let phase = current.phase
        let text = detail ?? current.detail
        mutex.unlock()
        publish(phase, detail: text, done: done, total: total)
    }

    /// Dernier état avant `exit(0)`. Écrit SANS attendre la cadence : c'est
    /// exactement l'information qui manquerait ensuite, et l'app n'aurait plus
    /// que les cinq minutes de péremption pour deviner que l'agent est parti.
    func stopped(_ reason: String) {
        mutex.lock()
        var status = current
        status.phase = .stopped
        status.detail = reason
        status.done = 0
        status.total = 0
        status.updatedAt = Date()
        current = status
        lastWrite = Date()
        mutex.unlock()
        write(status)
    }

    private func write(_ status: AgentStatusRecord) {
        do {
            try store.writeAgentStatus(status)
            mutex.lock(); complained = false; mutex.unlock()
        } catch {
            mutex.lock()
            let first = !complained
            complained = true
            mutex.unlock()
            if first {
                log.warn("agent state not published (agent_status): "
                         + AgentText.describe(error)
                         + " — the work goes on, only the app's progress bar is "
                         + "blind")
            }
        }
    }
}
