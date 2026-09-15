// FolderCheck.swift — `dossier:Xyz` confronté aux étiquettes qui existent.
// Propriété : A-Core. Audit A1, idée 5 (le pendant d'A1m-04 côté ergonomie).
//
// LE PROBLÈME. `top_folder` est comparé en SQL par une égalité exacte
// (`GRDBStore+Search`, `top_folder IN (…)`), et SQLite compare le TEXTE
// caractère par caractère. Une étiquette mal recopiée — « Cour » pour
// « Cours », « livres » pour « Livres » — ne filtrait donc rien du tout : la
// requête rendait **zéro résultat, sans un mot**, exactement comme si le corpus
// ne contenait pas le terme cherché. C'est le même piège qu'A1m-04 (un
// dossier dont l'étiquette porte une espace était infiltrable), vu de l'autre
// côté : là, la syntaxe échouait ; ici, elle réussit et ment.
//
// CE QUE FAIT `resolve`. Deux choses, dans cet ordre :
//   1. une étiquette qui ne diffère que par la casse est CANONISÉE (« livres »
//      devient « Livres ») — le filtre marche alors comme l'utilisateur
//      l'attendait, sans message ;
//   2. une étiquette qui ne correspond à rien lève `QueryError.unknownFolder`
//      EN NOMMANT celles qui existent. Le public de Fouine ne connaît pas la
//      liste de ses racines par cœur, et la facette « Dossiers » ne s'affiche
//      qu'APRÈS une recherche qui a rendu quelque chose.
//
// La casse est le seul écart toléré : accepter aussi les accents ou une
// distance d'édition ferait filtrer sur un dossier que l'utilisateur n'a pas
// nommé — un résultat faux vaut moins qu'un refus qui dit quoi taper.

import Foundation

public enum FolderCheck {

    /// Les étiquettes demandées, ramenées à leur écriture réelle.
    ///
    /// - Throws: `QueryError.unknownFolder` à la PREMIÈRE inconnue, avec la
    ///   liste des étiquettes existantes triée — l'ordre de `roots()` est celui
    ///   des identifiants, qui ne veut rien dire pour qui lit le message.
    public static func resolve(_ asked: [String], known: [String]) throws -> [String] {
        // ON NE REFUSE QUE CE QU'ON PEUT CONTREDIRE. Sans liste d'étiquettes —
        // une base neuve, une application dont les racines ne sont pas encore
        // relues, un outil qui interroge un index sans racine enregistrée —, il
        // n'y a rien à confronter : le filtre part tel quel, comme avant. Un
        // refus fondé sur une liste vide serait un faux positif, c'est-à-dire
        // exactement le défaut qu'on répare.
        guard !asked.isEmpty, !known.isEmpty else { return asked }
        let byFold = Dictionary(known.map { (fold($0), $0) },
                                uniquingKeysWith: { first, _ in first })
        return try asked.map { label in
            if let exact = byFold[fold(label)] { return exact }
            throw QueryError.unknownFolder(label, known: known.sorted())
        }
    }

    /// La comparaison : casse ignorée, rien d'autre. `lowercased()` d'un
    /// `String` Swift suit l'Unicode complet — « ÉCOLE » et « école » se
    /// rejoignent, « Ecole » non, et c'est voulu (voir l'en-tête).
    private static func fold(_ s: String) -> String {
        s.lowercased()
    }
}
