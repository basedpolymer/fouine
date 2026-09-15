// IndexFault.swift — fatale, ignorée, ou propre à un document. Audit F2.
// Propriété : A-Core.
//
// C'est la divergence n°1 de l'audit, et la plus coûteuse : l'app n'avait qu'un
// `catch`. Un volume débranché en cours de passe lui faisait marquer CHAQUE
// document `.failed` — 1 330 documents à ré-extraire pour un câble USB —, là où
// la CLI et l'agent arrêtaient le lot sur la première erreur de volume ou de
// base. Le tri était fait, correctement, à DEUX endroits sur trois ; il est
// désormais fait à un seul, et c'est un type, pas une convention.
//
// La règle, du §4.2 :
//   · `.volumeNotMounted` et `.databaseFailure` (verrou occupé compris)
//     concernent la PASSE : les mêmes causes vaudront pour tous les documents
//     suivants, continuer ne produirait que du bruit. Sortie 2 et 3 (§4.3).
//   · `.unsupported` et `.fileTooLarge` sont des refus normaux : `.skipped`
//     avec un motif (A11.3 — `fileTooLarge` tombait en `.failed`).
//   · tout le reste est un accident de CE document : `.failed` + `docs.err`,
//     et le lot continue (piège n°13).

import Foundation
import FouineCore
import FouineExtract

public enum IndexFault: Sendable {
    /// Arrête la passe et remonte telle quelle (les codes du §4.3 en dépendent).
    case fatal(FouineError)
    /// `docs.state = .skipped`, `docs.err` = le motif.
    case skipped(reason: String)
    /// `docs.state = .failed`, `docs.err` = la description de l'erreur.
    case perDocument

    public static func classify(_ error: Error) -> IndexFault {
        guard let fouine = error as? FouineError else { return .perDocument }
        switch fouine {
        case .volumeNotMounted, .databaseFailure:
            return .fatal(fouine)
        default:
            if let reason = ExtractOutcome.skipReason(for: fouine) {
                return .skipped(reason: reason)
            }
            return .perDocument
        }
    }

    /// Une erreur survenue là où il n'y a plus de rattrapage possible (écriture
    /// de l'état d'un document) : elle arrête la passe, quelle qu'elle soit.
    public static func asFatal(_ error: Error) -> FouineError {
        if let fouine = error as? FouineError { return fouine }
        return .databaseFailure(IndexText.describe(error))
    }
}

/// La phrase ANGLAISE d'une erreur, UNE fois pour les trois pipelines (§4.3 :
/// « l'utilisateur doit lire la même phrase dans les trois outils »).
///
/// C'est ce qui part dans `docs.err` : sans source unique, la même panne
/// s'écrivait dans la base avec trois libellés selon le pipeline qui l'avait
/// rencontrée, et une requête sur `docs.err` devenait ininterprétable.
///
/// ANGLAIS depuis le palier 3.5 (audit U1). La ligne de commande, l'agent et
/// `docs.err` parlent la langue de base du projet ; le français ne vit plus que
/// dans l'application, via le catalogue (`ErrorText`, qui ne lit AUCUNE phrase
/// d'ici — il repart des cas). Les `docs.err` déjà écrits en français restent
/// tels quels : `fouine index --force`, ou toute ré-extraction du document, les
/// réécrit en anglais.
public enum IndexText {
    public static func describe(_ error: Error) -> String {
        if let f = error as? FouineError {
            switch f {
            case .volumeNotMounted(let uuid):
                return "volume not mounted (UUID \(uuid)) — plug it back in and try again"
            case .rootUnreadable(let path, let raw):
                // Le motif est un enregistrement sans langue depuis le palier
                // 3.5 (`RootProbe.Reason`) : la phrase se refait ici.
                let reason = RootProbe.reason(raw)
                let text = reason?.english ?? raw
                // Le geste TCC n'accompagne QUE le refus de lecture ; un dossier
                // disparu dit « déplacé ou supprimé » sans parler de TCC
                // (recette tranche A, observation 5).
                if reason == .permissionDenied,
                   !text.contains(RootProbe.tccGuidance) {
                    return "unreadable root: \(path) — \(text). "
                        + RootProbe.tccGuidance
                }
                return "unreadable root: \(path) — \(text)"
            case .databaseFailure(let m):
                // Le verrou occupé n'est plus une phrase mais un
                // enregistrement (`WriteLock.busyToken`, palier 3.2) : c'est
                // ICI qu'il redevient la phrase du §4.3, celle que lisent la
                // CLI, l'agent et `docs.err` — au mot près.
                if let busy = WriteLock.busy(f) { return busyPhrase(busy) }
                return "database: \(m)"
            case .budgetExhausted(let remaining):
                return "budget exhausted, \(remaining) item(s) left in the queue"
            case .unsupported(let ext): return "unsupported format: .\(ext)"
            case .fileTooLarge(let bytes): return "file too large (\(bytes) B)"
            case .extraction(let m): return "extraction: \(m)"
            case .ocr(let m): return "OCR: \(m)"
            // Jamais écrite dans `docs.err` (ST1) : le document reste à faire.
            // La phrase n'existe que pour les journaux.
            case .cancelled: return "stopped before this document was read"
            }
        }
        if let q = error as? QueryError { return q.errorDescription ?? "\(q)" }
        return (error as NSError).localizedDescription
    }

    /// La phrase d'un verrou occupé (audit F3), reconstruite depuis les données.
    /// Elle nomme son détenteur et se suffit à elle-même : la préfixer de
    /// « database: » donnerait « database: database locked… ».
    static func busyPhrase(_ busy: WriteLock.Busy) -> String {
        guard let holder = busy.holder else {
            return "database locked by another process — holder not named in "
                + "\(busy.path); try again in a moment"
        }
        return "database locked by another process — " + holder.phrase
            + "; try again when that write is finished"
    }
}
