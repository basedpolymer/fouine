// NameMatchText.swift — la phrase du bandeau des noms de fichier (PR-02).
// Propriété : A-App.
//
// POURQUOI DEUX CHAÎNES ET NON UNE. Un PLURIEL ne peut pas porter de `%@` —
// `xcstringstool` le refuse (convention du dépôt, déjà rencontrée par le lot
// UX3 pour la phrase de Spotlight). Le compte et la requête sont donc deux
// clés : le pluriel `%lld document(s)`, qui existait déjà, puis la suite de la
// phrase avec la requête entre les guillemets de la langue (« … » en
// français, “…” en anglais — la coupure est mise là pour cela).
//
// PURE ET TESTÉE, comme toute la logique de texte de l'application : une vue
// SwiftUI ne se teste pas.

import Foundation

enum NameMatchText {

    /// « 3 documents dont le nom contient « IP2022 » ».
    static func banner(count: Int, query: String) -> String {
        String(localized: "\(count) document(s)") + " "
            + String(localized: "whose name contains “\(query)”")
    }
}
