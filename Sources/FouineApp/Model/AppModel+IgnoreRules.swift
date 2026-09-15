// AppModel+IgnoreRules.swift — lire et garder les règles d'exclusion d'une
// racine pour la feuille « Ce que Fouine ignore… » (lot IG2). Propriété : A-App.
//
// Lectures et écriture HORS du fil principal, comme les autres gestes sur les
// racines (`renameRoot`, `setRootEnabled`). Rien n'est jamais écrit dans le
// dossier de l'utilisateur : les règles vont dans la base, le fichier
// `.fouineignore` n'est que lu.

import Foundation
import FouineCore
import FouineCrawl

extension AppModel {

    /// Ce que la feuille montre à son ouverture. Lève si la base ne répond
    /// pas : la feuille le dit plutôt que de montrer une liste vide qui ferait
    /// croire qu'aucune règle n'existe.
    func ignoreRulesSnapshot(for root: RootStatus) async throws -> IgnoreRulesDraft.Snapshot {
        let store = service.store
        let id = root.id
        let path = root.absolutePath
        return try await Task.detached(priority: .userInitiated) {
            let decoded = IgnoreRuleSet.decode(try store.ignoreRulesJSON(rootID: id))
            let file = path.flatMap {
                IgnoreRules.loadFile(root: URL(fileURLWithPath: $0, isDirectory: true))
            }
            // Les documents servent au compte et au menu des types : sans eux
            // la feuille marche encore, elle dit « des documents » sans nombre.
            let docs = try? store.docs(underRoot: id)
            return IgnoreRulesDraft.Snapshot(stored: decoded.set, file: file, docs: docs)
        }.value
    }

    /// Garde les règles de la racine. `nil` au JSON quand il n'en reste aucune.
    func saveIgnoreRules(_ rules: IgnoreRuleSet, for root: RootStatus) async throws {
        let store = service.store
        let id = root.id
        let json = rules.json
        try await Task.detached(priority: .userInitiated) {
            try store.setIgnoreRulesJSON(rootID: id, json)
        }.value
    }
}
