// IndexCountsRefresh.swift — quand la fenêtre « Votre index » relit ses comptes
// (lot MN2). Propriété : A-App.
//
// POURQUOI. La fenêtre lisait les comptes une fois, à l'ouverture : pendant une
// mise à jour, ses documents et ses pages restaient figés, et elle mentait
// jusqu'à ce qu'on la rouvre. Elle les relit maintenant AU RYTHME DE LA SONDE
// que le modèle fait déjà tourner (`AppModel.startAgentStatusProbe`, 2 s au
// premier plan, 30 s au fond), qui republie l'état de l'index : aucune
// minuterie de plus. Mais pas à chaque battement — `stats()` compte toute la
// base, balayage des vecteurs compris, et une lecture toutes les deux secondes
// ferait travailler le disque sans répit pendant toute la mise à jour.
//
// Deux règles : pendant un travail, une relecture au plus toutes les
// `interval` secondes ; à la FIN du travail, une relecture tout de suite, pour
// que les derniers nombres affichés soient les bons. Au repos, rien : les
// comptes ne bougent pas.

import Foundation

struct IndexCountsRefresh: Equatable {

    static let interval: TimeInterval = 10

    private(set) var lastRead: Date?
    private(set) var wasWorking = false

    /// À chaque état de l'index publié par la sonde. Vrai : relire maintenant
    /// (et la relecture est comptée).
    mutating func shouldRead(working: Bool, now: Date) -> Bool {
        defer { wasWorking = working }
        let due: Bool
        if working {
            due = lastRead.map { now.timeIntervalSince($0) >= Self.interval } ?? true
        } else {
            due = wasWorking
        }
        if due { lastRead = now }
        return due
    }

    /// La lecture de l'ouverture compte : la première relecture pendant un
    /// travail attend l'intervalle entier.
    mutating func noteRead(at now: Date) {
        lastRead = now
    }
}
