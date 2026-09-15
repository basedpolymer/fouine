// GRDBStore+FilterValues.swift — les valeurs qu'un filtre peut prendre.
// Propriété : A-Core.
//
// POURQUOI (constat CM-11). Un filtre dont la valeur n'existe pas rend zéro
// résultat, et zéro résultat n'est pas une information : c'est la même réponse
// que « votre corpus ne traite pas de ce sujet ». Un assistant qui pose
// `lang: "xx"` conclut donc à un corpus muet, et le dit à l'utilisateur.
//
// Le projet a déjà tranché ce cas pour les étiquettes de dossier
// (`FolderCheck`, idée 5 de l'audit A1) : on refuse EN NOMMANT ce qui existe.
// Ce fichier donne aux autres filtres de quoi faire la même chose — les valeurs
// réellement présentes, lues sur l'index, sans que l'appelant ait à écrire du
// SQL.
//
// ON NE REFUSE QUE CE QU'ON PEUT CONTREDIRE, comme `FolderCheck` : une liste
// vide (index neuf, langues jamais détectées) ne fonde aucun refus, et c'est à
// l'appelant de le voir — ces deux méthodes rendent ce qu'elles trouvent, elles
// ne jugent rien.

import Foundation
import GRDB

extension GRDBStore {

    /// Les codes de langue présents dans l'index, triés.
    ///
    /// `und` en fait partie quand des documents portent cette valeur : c'est un
    /// filtre légitime (« ceux dont la langue n'a pas été déterminée »), et le
    /// cacher ferait refuser une demande qui aurait marché.
    ///
    /// Prix : un balayage de la colonne `docs.lang`, quelques milliers de lignes
    /// sur un index réel — le coût d'une lecture, payé une fois par appel qui
    /// porte un filtre de langue, jamais sur le chemin d'une recherche ordinaire.
    public func knownLanguages() throws -> [String] {
        try read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT lang FROM docs
                 WHERE lang IS NOT NULL AND lang != ''
                 ORDER BY lang
                """)
        }
    }

    /// Les mêmes, RESTREINTES à ces racines (lot MN1, reste d'IG1).
    ///
    /// `fouine mcp --folders Livres` sert un sous-ensemble de l'index : les
    /// langues qu'il ANNONCE dans son refus (« languages in this index: … »)
    /// devaient être celles des documents servis, sinon la phrase nomme une
    /// langue qui n'existe que hors périmètre — elle ne rend aucun document,
    /// mais elle apprend au modèle qu'il y a autre chose derrière.
    ///
    /// Étiquettes vides = tout l'index, et c'est alors la requête ci-dessus au
    /// caractère près. La comparaison est EXACTE, comme partout où `top_folder`
    /// entre en SQL (`FolderCheck` canonise avant d'arriver ici).
    public func knownLanguages(inFolders folders: [String]) throws -> [String] {
        guard !folders.isEmpty else { return try knownLanguages() }
        let marks = Array(repeating: "?", count: folders.count)
            .joined(separator: ",")
        return try read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT lang FROM docs
                 WHERE lang IS NOT NULL AND lang != ''
                   AND top_folder IN (\(marks))
                 ORDER BY lang
                """, arguments: StatementArguments(folders))
        }
    }

    /// Ceux de ces identifiants qui ne désignent aucun document, dans l'ordre
    /// où ils ont été demandés.
    ///
    /// L'appelant en a besoin pour NOMMER ce qui cloche : « unknown document
    /// id(s): 999999 » vaut mieux qu'une recherche qui porte sur un ensemble
    /// vide. Rend un tableau vide quand tout existe — et quand on ne demande
    /// rien.
    public func unknownDocIDs(_ ids: [Int64]) throws -> [Int64] {
        guard !ids.isEmpty else { return [] }
        // Des `Int64` interpolés, comme `ocrPageCounts` et `vectorisedPageCounts`
        // le font juste à côté : ce sont des entiers, pas du texte, et la liste
        // est bornée par le schéma d'entrée de l'outil (50 éléments).
        let list = ids.map(String.init).joined(separator: ",")
        let known = try read { db in
            Set(try Int64.fetchAll(
                db, sql: "SELECT id FROM docs WHERE id IN (\(list))"))
        }
        // L'ordre est celui de la DEMANDE, sans doublon : le message doit
        // pouvoir se relire à côté de l'appel qui l'a provoqué.
        var seen: Set<Int64> = []
        return ids.filter { known.contains($0) ? false : seen.insert($0).inserted }
    }
}
