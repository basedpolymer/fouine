// SpotlightSync.swift — remettre à Spotlight ce qui a changé (lot INT-S1).
// Propriété : A-Core.
//
// LE MARQUEUR EST TOUT LE MÉCANISME. `docs.indexed_at` dit quand un document a
// été indexé pour la dernière fois ; `spotlight.synced_at` dit jusqu'où on a
// donné. La remise lit l'intervalle entre les deux, donne, puis avance le
// marqueur — et comme les TROIS exécutables partagent la table `settings`,
// l'application reprend là où l'agent s'est arrêté, sans se concerter avec lui.
//
// CE QUE LA BASE NE SAIT PAS DIRE : LES SUPPRESSIONS. `purgeDoc` efface la
// ligne ; aucune trace ne reste, et une remise incrémentale ne peut donc pas
// savoir qu'un document a disparu. D'où la REMISE COMPLÈTE, qui efface le
// domaine de Fouine puis redonne tout : elle a lieu quand le marqueur vaut 0
// — première fois, désinstallation, ou bouton « Mettre Spotlight à jour »,
// qui remet justement le marqueur à zéro. C'est le seul geste qui nettoie les
// documents supprimés, et c'est écrit dans `docs/app.md` plutôt que caché.
//
// LE MARQUEUR N'AVANCE PAS JUSQU'À `now` QUAND LE LOT EST PLEIN. Une passe ne
// donne qu'un nombre borné de documents (`maxDocumentsPerRun`) : écrire
// l'heure courante ferait passer à la trappe tout ce qui n'a pas tenu dans le
// lot. On écrit alors la date du DERNIER document donné, et la passe suivante
// reprend là — quelques documents seront redonnés, ce qui est une écriture
// idempotente, là où en oublier serait définitif.
//
// UNE ERREUR DE SPOTLIGHT N'EST PAS UNE ERREUR D'INDEXATION. Elle remonte à
// l'appelant, qui en fait une note de journal : le texte est en base, la
// recherche de Fouine marche, et seule la remise est à refaire. Le marqueur
// n'ayant pas avancé, la passe suivante la refait toute seule.

import Foundation
import FouineCore

/// Ce que la remise demande à la base. `GRDBStore` s'y conforme ; le protocole
/// existe pour que les tests éprouvent la mécanique sans base ni bundle.
public protocol SpotlightSyncStore: Sendable {
    func settingsRows() throws -> [String: String]
    func writeSetting(_ key: String, _ value: String) throws
    func documentsChanged(since: Double, limit: Int) throws -> [DocumentChange]
    /// Les pages de texte à partir de `fromPage` (incluse), dans l'ordre.
    func pageTexts(docID: Int64, limit: Int, fromPage: Int) throws -> [IndexedPage]
}

extension GRDBStore: SpotlightSyncStore {}

public enum SpotlightSync {

    /// Documents traités par remise. Au-delà, on s'arrête et la passe suivante
    /// reprend : une fin de passe ne doit pas devenir un travail de fond.
    public static let maxDocumentsPerRun = 5_000

    /// Pages lues d'un coup pour un document. Le texte est lu par tranches
    /// jusqu'au plafond : un livre de trois mille pages ne doit pas être
    /// chargé en entier pour n'en donner qu'un mégaoctet.
    public static let pageChunk = 32

    /// Pourquoi une remise n'a rien fait.
    public enum Skip: Sendable, Equatable {
        /// `spotlight.enabled` est éteint.
        case disabled
        /// Pas de bundle (CLI, `swift run`, agent) : le système refuserait.
        case unavailable
    }

    /// Ce qu'une remise a fait.
    public struct Report: Sendable, Equatable {
        public var skipped: Skip?
        /// Remise complète : le domaine a été effacé d'abord.
        public var full = false
        /// Documents examinés.
        public var scanned = 0
        /// Documents donnés.
        public var indexed = 0
        /// Documents retirés (sortis de la portée).
        public var deleted = 0
        /// Octets de texte remis. Sert aux mesures, et à rien d'autre.
        public var textBytes = 0

        public var didSomething: Bool { indexed > 0 || deleted > 0 }

        /// Une ligne de journal, en anglais comme tout ce que la CLI imprime.
        public var summary: String {
            switch skipped {
            case .disabled:    return "Spotlight: skipped, turned off"
            case .unavailable: return "Spotlight: skipped, no bundle"
            case .none:
                return "Spotlight: \(indexed) document(s) handed over, "
                     + "\(deleted) removed\(full ? " (full refresh)" : "")"
            }
        }
    }

    /// Donne à Spotlight ce qui a changé depuis la dernière fois.
    ///
    /// - Parameter now: l'instant de la remise. Capturé AVANT la lecture : un
    ///   document écrit pendant la remise porte une date postérieure et sera
    ///   donné à la suivante, plutôt que d'être sauté.
    /// - Parameter fullRebuild: repartir de zéro — effacer le domaine de
    ///   Fouine, puis tout redonner. C'est le bouton « Mettre Spotlight à
    ///   jour », et le seul geste qui retire les documents supprimés.
    @discardableResult
    public static func run(store: any SpotlightSyncStore,
                           policy: SpotlightPolicy,
                           donor: any SpotlightDonating,
                           now: Date = Date(),
                           fullRebuild: Bool = false,
                           limit: Int = maxDocumentsPerRun) throws -> Report {
        var report = Report()
        guard policy.enabled else {
            report.skipped = .disabled
            return report
        }
        guard donor.isAvailable else {
            report.skipped = .unavailable
            return report
        }

        let since = fullRebuild ? 0 : (try marker(of: store))
        report.full = since <= 0
        if report.full { try donor.deleteAll() }

        let changed = try store.documentsChanged(since: max(0, since), limit: limit)
        report.scanned = changed.count

        var items: [SpotlightItem] = []
        var obsolete: [String] = []
        for document in changed {
            guard policy.includes(document) else {
                // Sur une remise COMPLÈTE, le domaine vient d'être effacé : il
                // n'y a rien à retirer, et demander la suppression de milliers
                // d'identifiants inexistants ne ferait que du travail.
                if !report.full {
                    obsolete.append(SpotlightItemBuilder.identifier(docID: document.id))
                }
                continue
            }
            let pages = try text(of: document.id, store: store,
                                 limitBytes: policy.textLimitBytes)
            guard let item = SpotlightItemBuilder.item(
                document: document,
                absolutePath: absolutePath(of: document),
                pages: pages,
                limitBytes: policy.textLimitBytes,
                title: SourceDocumentLocator.standard
                    .document(relPath: document.relPath)?.title)
            else {
                // Aucun texte en base : rien à donner, et rien à retirer non
                // plus tant qu'on n'a jamais rien donné pour ce document.
                if !report.full {
                    obsolete.append(SpotlightItemBuilder.identifier(docID: document.id))
                }
                continue
            }
            items.append(item)
            report.textBytes += item.textContent.utf8.count
        }

        try donor.index(items)
        try donor.delete(identifiers: obsolete)
        report.indexed = items.count
        report.deleted = obsolete.count

        // Le marqueur n'avance qu'APRÈS la remise : une erreur laisse tout à
        // refaire, ce qui est le comportement voulu.
        try write(marker: nextMarker(changed: changed, limit: limit, now: now),
                  to: store)
        // Ce que la fenêtre de réglages montre à l'utilisateur (BU-26). Écrit
        // seulement quand la remise a DONNÉ quelque chose : une passe qui ne
        // trouve rien de neuf ne doit pas remplacer « 1 527 documents » par
        // « 0 document » à la première ouverture de Fouine qui suit.
        if report.indexed > 0 {
            try store.writeSetting(SettingKeys.spotlightSyncedCount.key,
                                   String(report.indexed))
        }
        return report
    }

    /// La remise telle qu'une FIN DE PASSE l'appelle : réglages lus dans la
    /// base, donateur réel, et pas la moindre erreur qui remonte.
    ///
    /// Une remise ratée ne doit jamais faire échouer une indexation : le texte
    /// est en base, la recherche de Fouine marche, et le marqueur n'ayant pas
    /// avancé, la passe suivante refera la remise toute seule. Elle ne laisse
    /// donc qu'une ligne de journal — et seulement quand il y a quelque chose
    /// à dire : « rien à donner » n'est pas une nouvelle.
    ///
    /// - Parameter announceUnavailable: dire « pas de bundle » quand le
    ///   processus ne peut pas donner. Vrai pour la CLI, qui imprime le bilan
    ///   d'UNE commande et doit expliquer pourquoi Spotlight ne bouge pas ;
    ///   faux pour l'agent, qui passe toutes les minutes et dont le journal
    ///   serait noyé par une ligne qui ne change jamais.
    public static func afterPass(store: any SpotlightSyncStore,
                                 donor: any SpotlightDonating = SpotlightDonor(),
                                 announceUnavailable: Bool = false,
                                 log: (String) -> Void) {
        let policy = SpotlightPolicy(SettingsSnapshot(
            rows: (try? store.settingsRows()) ?? [:]))
        do {
            let report = try run(store: store, policy: policy, donor: donor)
            if (report.skipped == .unavailable && announceUnavailable)
                || report.didSomething {
                log(report.summary)
            }
        } catch {
            log("Spotlight: " + IndexText.describe(error))
        }
    }

    /// Repart de zéro à la remise suivante : le marqueur à 0 vaut « efface
    /// tout et redonne ». Sert au bouton des réglages et à un changement de
    /// portée, qui rend périmé tout ce qui a été donné.
    public static func requestFullRebuild(store: any SpotlightSyncStore) throws {
        try write(marker: 0, to: store)
        // Le compte repart avec lui : après « Retirer les documents de Fouine
        // de Spotlight », plus rien n'a été remis, et la fenêtre doit le dire.
        try store.writeSetting(SettingKeys.spotlightSyncedCount.key, "0")
    }

    // MARK: - Marqueur

    static func marker(of store: any SpotlightSyncStore) throws -> Double {
        let rows = try store.settingsRows()
        guard let raw = rows[SettingKeys.spotlightSyncedAt.key],
              let seconds = Double(raw) else { return 0 }
        return seconds
    }

    private static func write(marker: Double, to store: any SpotlightSyncStore) throws {
        try store.writeSetting(SettingKeys.spotlightSyncedAt.key,
                               String(Int(max(0, marker))))
    }

    /// Où s'arrête cette remise. Voir l'en-tête : un lot PLEIN ne fait avancer
    /// le marqueur que jusqu'au dernier document donné.
    static func nextMarker(changed: [DocumentChange], limit: Int,
                           now: Date) -> Double {
        guard changed.count >= limit, let last = changed.last else {
            return now.timeIntervalSince1970
        }
        return last.indexedAt
    }

    // MARK: - Lectures

    /// Le texte d'un document, par tranches, jusqu'au plafond. Une page de
    /// plus est lue exprès : c'est elle qui prouve au constructeur qu'il faut
    /// couper, et elle coûte une lecture, pas un mégaoctet.
    static func text(of docID: Int64, store: any SpotlightSyncStore,
                     limitBytes: Int) throws -> [IndexedPage] {
        var pages: [IndexedPage] = []
        var used = 0
        var next = 0
        while used <= limitBytes {
            let chunk = try store.pageTexts(docID: docID, limit: pageChunk,
                                            fromPage: next)
            guard !chunk.isEmpty else { break }
            for page in chunk {
                pages.append(page)
                used += page.text.utf8.count
                    + SpotlightItemBuilder.pageSeparator.utf8.count
            }
            // Par CURSEUR de page, jamais par `OFFSET` : voir `pageTexts`, où
            // la mesure est écrite. Une page sans successeur arrête la boucle.
            guard let last = chunk.last?.page, last < Schema.maxPage else { break }
            next = last + 1
            if chunk.count < pageChunk { break }
        }
        return pages
    }

    /// Le chemin absolu du document, ou `nil` si son volume n'est pas monté —
    /// auquel cas l'élément est donné SANS `contentURL` : le texte reste
    /// cherchable, et le clic passe par l'identifiant, qui ne dépend d'aucun
    /// point de montage.
    private static func absolutePath(of document: DocumentChange) -> String? {
        try? VolumeResolver.absolutePath(volUUID: document.volUUID,
                                         relPath: document.relPath).path
    }
}
