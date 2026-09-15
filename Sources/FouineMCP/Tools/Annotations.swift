// Annotations.swift — ce qu'un client lit AVANT d'appeler (CM-10).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// LES CINQ ENSEMBLE, ET PAS À CÔTÉ DE CHAQUE SCHÉMA : ils disent exactement la
// même chose — ce serveur ne peut rien casser —, et c'est cette UNIFORMITÉ qui
// est le contrat. Un outil ajouté un jour sans sa ligne ici serait le seul du
// catalogue à faire demander une confirmation, et personne ne le verrait :
// `ToolsListTests` le fait rougir.
//
// CE QUE ÇA COÛTE DE NE PAS LES POSER. Un client qui ne voit pas
// `readOnlyHint: true` doit supposer qu'un outil modifie quelque chose et
// demande confirmation à chaque appel — sur un serveur dont tout l'argument est
// l'innocuité. C'est aussi ce qui ferait rejeter l'extension `.mcpb` à
// l'annuaire Claude (PR-11).
//
// La promesse n'est pas déclarative : elle est tenue par les trois ceintures de
// `ReadOnlyStore` (SQLite ouvert en lecture seule, mur de types, aucun outil
// d'écriture déclaré), et `ReadOnlyTests` vérifie qu'après deux cents appels le
// fichier `.db` est identique à l'octet près. Fouine est sans doute le seul
// serveur documentaire de la place à pouvoir écrire `readOnlyHint: true` sans
// mentir.

import Foundation
import FouineMCPKit

extension StatusTool {
    public var annotations: [String: Any] { ToolAnnotations.readOnly(title: title) }
}

extension SearchTool {
    public var annotations: [String: Any] { ToolAnnotations.readOnly(title: title) }
}

extension ReadPageTool {
    public var annotations: [String: Any] { ToolAnnotations.readOnly(title: title) }
}

extension SimilarPagesTool {
    public var annotations: [String: Any] { ToolAnnotations.readOnly(title: title) }
}

extension ListDocumentsTool {
    public var annotations: [String: Any] { ToolAnnotations.readOnly(title: title) }
}
