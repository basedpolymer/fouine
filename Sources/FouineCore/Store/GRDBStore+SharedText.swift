// GRDBStore+SharedText.swift — combien de DOCUMENTS portent le même passage ?
// Propriété : A-Core.
//
// POURQUOI CETTE QUESTION SE POSE (constat C2-16). Sur une recherche par le
// sens, quatre des cinq premiers résultats étaient la même page de licence du
// Projet Gutenberg, recopiée dans quatre livres différents. La règle de
// diversité ne les rétrograde pas — ce sont bien des documents distincts — et
// le vecteur, lui, ne peut pas savoir qu'il a déjà vu ce texte. Dans un fonds
// ordinaire, l'équivalent est le pied de page d'un cabinet, les conditions
// générales recopiées dans vingt devis, l'en-tête d'un modèle de lettre.
//
// LA SONDE, ET SON PRIX. `fouine embed` demande, AVANT d'inférer une fenêtre
// qui en vaut la peine, combien de documents portent deux phrases prises dans
// cette fenêtre. Au-delà du seuil, il pose un vecteur nul : la page reste
// trouvable au mot près par le canal lexical, elle cesse de polluer le sens.
//
// La requête s'arrête TÔT : le `LIMIT` de la sous-requête vaut le seuil, donc
// SQLite cesse de collecter dès qu'il a vu assez de documents distincts. Sans
// lui, un pied de page présent dans dix mille documents ferait balayer dix
// mille lignes pour rendre un chiffre dont on n'avait besoin qu'à quatre près.

import Foundation
import GRDB

extension GRDBStore {

    /// Nombre de documents DISTINCTS dont une page satisfait la requête FTS5
    /// BRUTE donnée, plafonné à `atLeast`.
    ///
    /// `rawFTS` est passé tel quel à `page_fts MATCH` : c'est l'appelant qui le
    /// compose (des phrases entre guillemets, jointes par `AND`), et lui seul
    /// qui sait ce qu'il cherche. Le doc_id se dérive du rowid structuré comme
    /// partout (§4.1) — aucune jointure sur `docs`, la sonde doit rester au prix
    /// de l'index FTS5 seul.
    ///
    /// Rend `0` plutôt que de lever quand la requête est refusée par FTS5 : la
    /// sonde est une OPTIMISATION de qualité, jamais une raison de faire échouer
    /// une campagne de vingt heures.
    public func documentsSharing(rawFTS: String, atLeast: Int) throws -> Int {
        guard atLeast > 0, !rawFTS.isEmpty else { return 0 }
        return try read { db in
            (try? Int.fetchOne(db, sql: """
                SELECT count(*) FROM (
                  SELECT DISTINCT rowid / \(Schema.pagesPerDocLimit)
                  FROM page_fts WHERE page_fts MATCH ? LIMIT ?
                )
                """, arguments: [rawFTS, atLeast])) ?? 0
        }
    }
}
