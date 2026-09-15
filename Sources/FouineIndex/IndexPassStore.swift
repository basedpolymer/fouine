// IndexPassStore.swift — ce qu'une passe demande à la base. Propriété : A-Core.
//
// `IndexStore` (§4.2, gelé) porte déjà tout ce qu'écrit l'extraction. Il lui
// manque trois choses que la passe doit pouvoir appeler, et qui n'ont pas leur
// place dans un contrat gelé : la fin de passe (§5.1), et les deux bouts du
// verrou d'écriture (audit F3).
//
// Le protocole n'existe pas pour le plaisir de l'abstraction : c'est le point
// d'INJECTION des tests. `FouineIndexTests` enveloppe un vrai `GRDBStore` dans
// un mandataire qui échoue à la Nième écriture, et vérifie ainsi qu'une panne
// de base ARRÊTE la passe et rend le verrou — ce qu'aucun test ne pouvait
// vérifier tant que les trois pipelines parlaient à un `GRDBStore` concret.

import Foundation
import FouineCore

public protocol IndexPassStore: IndexStore, SettingsReadableStore {
    /// Nombre de pages, connu seulement APRÈS extraction. Hors protocole gelé :
    /// `upsertDoc` est un no-op strict quand (size, mtime) n'ont pas bougé —
    /// c'est-à-dire dans le cas normal, entre le crawl et l'extraction de la
    /// même passe —, il ne peut donc pas porter cette mise à jour.
    func setPageCount(_ id: Int64, _ n: Int) throws
    /// `INSERT INTO page_fts(page_fts) VALUES('optimize')` (§5.1). L'agent ne
    /// l'appelle jamais : une salve FSEvents porte deux ou trois fichiers, et
    /// fusionner les segments d'un index de 1,6 Go coûterait infiniment plus
    /// que ce que la salve rapporte.
    func optimize() throws
    /// Réalimentation de `vocab_tri` (§5.5.2), idempotente et incrémentale.
    func warmVocabulary() throws
    /// Prend le verrou d'écriture en se nommant (audit F3).
    func acquireWriteLock(as role: LockRole) throws
    /// Rend le verrou. Idempotent.
    func releaseWriteLock()
    /// Où écrire la reprise d'un verrou périmé.
    func setWriteLockLog(_ log: @escaping @Sendable (String) -> Void)
    /// Langue dominante du document, détectée à l'extraction (audit X2).
    /// Hors protocole gelé pour la même raison que `setPageCount` : `upsertDoc`
    /// est un no-op strict quand (size, mtime) n'ont pas bougé.
    func setDocLanguage(_ id: Int64, _ lang: String?) throws
    /// Date INSCRITE DANS LE DOCUMENT, lue dans ses métadonnées à l'extraction
    /// (schéma v9, constat PR-07). Même raison que `setDocLanguage` d'être hors
    /// du protocole gelé, et même forme : la valeur est déjà analysée.
    func setDocDate(_ id: Int64, _ date: Double?) throws
    /// La table `settings` (schéma v4). La passe la lit UNE fois, à son
    /// démarrage, pour connaître les racines épinglées (audit U2, F4).
    func settingsRows() throws -> [String: String]
    /// Rattrapage de `docs.lang` sur le texte DÉJÀ indexé (lot U3, R-10).
    /// La détection arrive en paramètre : elle vit ici, dans FouineIndex, et le
    /// cœur ne peut pas l'appeler sans un cycle de dépendances.
    func backfillLanguages(limit: Int, sampleCharacters: Int,
                           chunk: Int,
                           detect: ([PageText]) -> String?)
        throws -> LanguageBackfillReport
}

public extension IndexPassStore {
    /// Défaut : aucune table de réglages. Ce qui vaut pour les mandataires de
    /// test, qui n'ont aucune raison d'en porter une, et pour tout futur
    /// implémenteur : une passe sans réglages se comporte comme avant le
    /// palier 2.3, priorités intrinsèques comprises.
    func settingsRows() throws -> [String: String] { [:] }
}

extension GRDBStore: IndexPassStore {
    public func warmVocabulary() throws {
        try TrigramExpander(store: self).warm()
    }
}
