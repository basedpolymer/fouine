// StoredIgnoreRulesStore.swift — ce que le crawl demande à la base pour
// connaître les règles gardées d'une racine (lot IG2). Propriété : A-Ingest.
//
// À part d'`IndexStore` (§4.2, gelé), comme `SourceRootStore` et
// `SpotlightSyncStore` : un mandataire de test n'a pas à le porter, et le
// crawl s'en passe alors — il n'applique que le fichier `.fouineignore`, ce
// qu'il faisait avant ce lot.

import Foundation
import FouineCore

public protocol StoredIgnoreRulesStore {
    /// Le texte JSON de `roots.ignore_rules`, ou `nil`.
    func ignoreRulesJSON(rootID: Int64) throws -> String?
}

extension GRDBStore: StoredIgnoreRulesStore {}
