// OCRPass.swift — la pompe OCR, verrou rendu. Propriété : A-Core, audit F3.
//
// `OCRRun` (FouineOCR) prend le verrou d'écriture PARESSEUSEMENT, à sa première
// page terminée, et ne le rend jamais : c'est à l'appelant de le faire à ses
// points de repos. L'agent le faisait (`Agent.ocrTick`, `defer`), la CLI le
// rendait en sortant du processus — l'app, non. Un « OCRiser ce document » lancé
// depuis l'app confisquait donc `fouine.lock` jusqu'à la fermeture de la
// fenêtre, et l'agent voyait sa condition « verrou disponible » (§5.7) fausse à
// vie, avec pour seul diagnostic « arrêtez l'indexation en cours ».
//
// Le même contrat que `IndexPass`, donc : pris en se nommant, rendu en `defer`.
// Le prendre d'emblée fait aussi échouer AVANT les 8,5 s de préchauffage de
// Vision quand un autre processus écrit — et avec le nom de ce processus.

import Foundation
import FouineCore
import FouineOCR

public enum OCRPass {

    /// Une passe OCR bornée par le budget et interruptible (§6.3).
    ///
    /// - Parameter role: qui écrit, pour `fouine.lock` (audit F3).
    /// - Parameter languageBackfillLimit: nombre maximal de documents relus en fin
    ///   de passe pour rattrapage de langue (lot U3, R-10, PERSP-5). 300 par défaut.
    @discardableResult
    public static func run(store: GRDBStore, role: LockRole,
                           jobs: Int = OCRRun.defaultJobs,
                           budgetMinutes: Int?, prioFolder: String? = nil,
                           only: String? = nil,
                           languageBackfillLimit: Int = 300,
                           log: @escaping @Sendable (String) -> Void = { print($0) },
                           shouldStop: @escaping ShouldStop = { false })
        throws -> OCRRunOutcome {

        store.setWriteLockLog(log)
        try store.acquireWriteLock(as: role)
        defer { store.releaseWriteLock() }
        let outcome = try OCRRun.run(store: store, jobs: jobs,
                                     budgetMinutes: budgetMinutes,
                                     prioFolder: prioFolder, only: only,
                                     log: log, shouldStop: shouldStop)
        if outcome == .completed, !shouldStop() {
            backfillLanguages(store: store, limit: languageBackfillLimit,
                              log: log, shouldStop: shouldStop)
        }
        // Spotlight (lot INT-S1). ICI et pas ailleurs : un lot d'OCR est le
        // SEUL moment où le texte d'un document scanné apparaît, et c'est
        // exactement ce que Spotlight ne sait pas lire. Ne rien donner ici
        // ferait attendre la prochaine passe d'indexation — c'est-à-dire, pour
        // un corpus stable, la prochaine modification d'un fichier.
        if !shouldStop() {
            SpotlightSync.afterPass(store: store,
                                    announceUnavailable: role == .cli, log: log)
        }
        return outcome
    }

    /// Rattrapage de `docs.lang` (lot U3, R-10, PERSP-5), en fin de passe OCR et BORNÉ.
    ///
    /// Quand l'OCR a écrit le texte d'une page d'un document dont la langue
    /// était indéterminée (« und » ou vide), `completeOCR` a remis `docs.lang` à NULL.
    /// Ce rattrapage relit l'échantillon depuis `page_fts` (au plus 300 documents par défaut)
    /// pour lui attribuer sa langue maintenant que son texte existe.
    ///
    /// Un document dont le texte OCR reste trop court ou indéterminable redevient
    /// « und » et ne sera plus relu aux passes suivantes — c'est le comportement
    /// voulu pour ne pas tourner en boucle sur du bruit ou du charabia.
    ///
    /// Même règle que pour `IndexPass` : si le budget est épuisé ou si
    /// l'utilisateur a demandé l'arrêt (`shouldStop`), on ne rattrape rien.
    private static func backfillLanguages(
        store: GRDBStore,
        limit: Int,
        log: (String) -> Void,
        shouldStop: () -> Bool
    ) {
        guard limit > 0, !shouldStop() else { return }
        do {
            let report = try store.backfillLanguages(
                limit: limit,
                sampleCharacters: LanguageDetector.sampleCharacters,
                chunk: GRDBStore.languageBackfillChunk,
                detect: { LanguageDetector.detect(LanguageDetector.sample(pages: $0)) })
            guard report.scanned > 0 else { return }
            log("language detected for \(report.scanned) document(s), \(report.remaining) left")
        } catch {
            log("language backfill skipped: " + IndexText.describe(error))
        }
    }
}
