// SavedSearches.swift — les recherches qu'on épingle (PR-17). Propriété : A-App.
//
// L'historique retient les quarante dernières requêtes et les oublie ensuite :
// « mes factures 2025 », qu'on rejoue tous les mois, en sort au bout d'une
// après-midi de travail. Une recherche enregistrée porte un NOM et ne bouge
// plus tant qu'on ne la retire pas.
//
// CE QU'ELLE RETIENT : la requête telle qu'elle a été tapée, préfixes compris
// (`dossier:Factures 2025`, `"phrase exacte"`, `-brouillon`). CE QU'ELLE NE
// RETIENT PAS : les facettes cochées dans la barre latérale. Deux raisons —
// elles se lisent à l'écran et se recochent d'un clic, et surtout une facette
// est comptée SUR le corpus du moment : une sélection de dossier enregistrée
// l'an dernier pourrait ne plus désigner aucun document, et la recherche
// rejouée ne rendrait rien sans dire pourquoi. L'aide de la section le dit.
//
// Le fichier est PUR : une liste, quatre opérations, et une persistance JSON.
// Aucune vue, aucun état d'application — c'est ce qui le rend testable.

import Foundation

/// Une recherche épinglée : un nom lisible, et la requête qu'il rejoue.
///
/// La REQUÊTE est l'identité : enregistrer deux fois la même requête sous deux
/// noms ferait deux lignes qui rendent le même résultat, et on ne saurait plus
/// laquelle retirer. Le second nom remplace donc le premier.
struct SavedSearch: Codable, Equatable, Identifiable {
    var name: String
    var query: String
    var id: String { query }
}

enum SavedSearches {

    /// Au-delà, la barre latérale devient une liste qu'on parcourt au lieu
    /// d'une poignée de raccourcis qu'on reconnaît. La plus ANCIENNE sort —
    /// celle qu'on n'a pas retirée soi-même depuis le plus longtemps.
    static let limit = 50

    /// Ajoute, ou renomme si la requête est déjà là — SANS la déplacer : une
    /// liste qui se réordonne toute seule oblige à rechercher des yeux, à
    /// chaque fois, le raccourci qu'on visait.
    static func adding(_ search: SavedSearch,
                       to list: [SavedSearch]) -> [SavedSearch] {
        var out = list
        if let index = out.firstIndex(where: { $0.query == search.query }) {
            out[index] = search
            return out
        }
        out.append(search)
        if out.count > limit { out.removeFirst(out.count - limit) }
        return out
    }

    static func renaming(query: String, to name: String,
                         in list: [SavedSearch]) -> [SavedSearch] {
        var out = list
        guard let index = out.firstIndex(where: { $0.query == query }) else {
            return out
        }
        out[index].name = name
        return out
    }

    static func removing(query: String,
                         from list: [SavedSearch]) -> [SavedSearch] {
        list.filter { $0.query != query }
    }

    /// Réordonner à la main. Les index hors bornes ne font RIEN plutôt que de
    /// lever : cette opération vient d'un glisser-déposer, et une liste qui a
    /// changé sous la souris ne doit pas faire tomber l'application.
    static func moving(from source: Int, to destination: Int,
                       in list: [SavedSearch]) -> [SavedSearch] {
        guard list.indices.contains(source),
              destination >= 0, destination <= list.count,
              source != destination else { return list }
        var out = list
        let item = out.remove(at: source)
        out.insert(item, at: destination > source ? destination - 1 : destination)
        return out
    }

    // MARK: - Persistance

    /// JSON dans les préférences, comme la session de « Reprendre où j'en
    /// étais » : un tableau de dictionnaires `UserDefaults` obligerait à
    /// valider chaque champ à la relecture.
    static func load(_ defaults: UserDefaults = Prefs.defaults) -> [SavedSearch] {
        guard let data = defaults.data(forKey: Prefs.savedSearches),
              let list = try? JSONDecoder().decode([SavedSearch].self, from: data)
        else { return [] }
        // Une liste écrite par une version future peut dépasser le plafond :
        // on garde les plus récentes plutôt que de refuser de tout lire.
        return list.count > limit ? Array(list.suffix(limit)) : list
    }

    static func save(_ list: [SavedSearch],
                     to defaults: UserDefaults = Prefs.defaults) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        defaults.set(data, forKey: Prefs.savedSearches)
    }
}
