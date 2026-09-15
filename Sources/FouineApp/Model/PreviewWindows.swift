// PreviewWindows.swift — combien de fenêtres d'aperçu, et laquelle (BU-19).
// Propriété : A-App.
//
// CE QUI A ÉTÉ MESURÉ. `openWindow(id: "preview", value: key)` ouvre une
// fenêtre PAR CLÉ DE PAGE : trois liens vers trois pages du même PDF de 400
// pages donnaient trois fenêtres, donc trois `PDFView` du même fichier, et
// l'instance passait de 55 Mo à 793 Mo (audit BU, 09/09/2026, `ps -o rss`) —
// 766 Mo les fenêtres refermées, 219 Mo plusieurs minutes plus tard. Sur la
// machine de référence, 8 Go, dix citations ouvertes dans la journée sont un
// problème.
//
// LA RÈGLE, DEPUIS : une fenêtre par DOCUMENT, trois au plus.
//   · un lien vers un document déjà ouvert change la page de SA fenêtre et la
//     ramène devant, sans en ouvrir une seconde ;
//   · au-delà de trois, la fenêtre la moins récemment utilisée est réemployée
//     pour le nouveau document.
//
// COMMENT SWIFTUI OBLIGE À S'Y PRENDRE. Une fenêtre de `WindowGroup(for:)` est
// identifiée par la VALEUR qui l'a ouverte, et rouvrir cette même valeur ramène
// la fenêtre existante au premier plan. L'identité d'une fenêtre est donc la
// clé de sa PREMIÈRE ouverture, et elle ne change jamais ; ce qu'elle MONTRE,
// lui, change. Cette table tient les deux : `identity` pour parler à SwiftUI,
// `target` pour ce que la fenêtre affiche.
//
// La décision est PURE — aucune fenêtre, aucun `openWindow` ici —, et c'est ce
// qui la rend testable.

import Foundation
import SwiftUI
import FouineCore

/// Ce qu'une fenêtre d'aperçu doit montrer, et ce qu'elle doit dire en plus.
struct PreviewTarget: Equatable {
    var key: HitKey
    /// Une phrase à afficher au-dessus de l'aperçu — aujourd'hui la seule est
    /// « la page N n'existe plus dans ce document » (BU-18). `nil` d'ordinaire.
    var notice: String?
    /// Le moment, en secondes, où poser la tête de lecture d'un enregistrement
    /// (lot PV1) : un lien `fouine://…&t=` en porte un.
    var time: Int?
}

/// La table des fenêtres détachées. Pure.
struct PreviewWindows: Equatable {

    /// Trois, et pas plus. Deux côte à côte est le geste courant ; la
    /// troisième laisse de la place à qui compare — au-delà, on empile des
    /// documents de plusieurs centaines de pages en mémoire sans que personne
    /// les regarde.
    static let maximum = 3

    struct Slot: Equatable {
        /// La clé de PREMIÈRE ouverture : ce que SwiftUI connaît de la fenêtre.
        let identity: HitKey
        /// Ce que la fenêtre montre en ce moment.
        var showing: HitKey
    }

    /// Ce que l'appelant doit faire : ouvrir (ou ramener devant) la fenêtre
    /// `identity`, qui doit afficher `target`.
    struct Decision: Equatable {
        let identity: HitKey
        let target: HitKey
        /// Vrai quand la fenêtre n'existait pas encore.
        let isNew: Bool
    }

    /// De la plus récemment utilisée à la moins récente.
    private(set) var slots: [Slot] = []

    var count: Int { slots.count }

    mutating func request(docID: Int64, page: Int) -> Decision {
        let target = HitKey(docID: docID, page: page)

        if let index = slots.firstIndex(where: { $0.showing.docID == docID }) {
            var slot = slots.remove(at: index)
            slot.showing = target
            slots.insert(slot, at: 0)
            return Decision(identity: slot.identity, target: target, isNew: false)
        }

        if slots.count < Self.maximum {
            slots.insert(Slot(identity: target, showing: target), at: 0)
            return Decision(identity: target, target: target, isNew: true)
        }

        // Plafond atteint : la moins récemment utilisée change de document.
        var reused = slots.removeLast()
        reused.showing = target
        slots.insert(reused, at: 0)
        return Decision(identity: reused.identity, target: target, isNew: false)
    }

    /// Une fenêtre s'est fermée : sa place se libère.
    mutating func closed(identity: HitKey) {
        slots.removeAll { $0.identity == identity }
    }

    /// Ce que montre la fenêtre d'identité donnée, si elle est ouverte.
    func showing(identity: HitKey) -> HitKey? {
        slots.first { $0.identity == identity }?.showing
    }
}

/// Le peu qui n'est pas pur : la table partagée par les fenêtres, et
/// l'ouverture elle-même.
///
/// UN SINGLETON, ET NON UN OBJET D'ENVIRONNEMENT : trois surfaces ouvrent une
/// fenêtre d'aperçu — le double-clic d'un résultat, ⌘⏎, et un lien `fouine://`
/// reçu par `DeepLinkReceiver` —, et la fenêtre détachée, elle, naît dans une
/// scène qui n'a pas l'environnement de la fenêtre principale. Une table
/// partagée est ce qui fait qu'elles parlent des mêmes fenêtres.
@MainActor
final class PreviewWindowsModel: ObservableObject {

    static let shared = PreviewWindowsModel()

    @Published private(set) var table = PreviewWindows()
    /// Ce que chaque fenêtre ouverte doit montrer, par identité de fenêtre.
    @Published private(set) var targets: [HitKey: PreviewTarget] = [:]

    /// Ouvre — ou réemploie — la fenêtre du document, sur cette page.
    func open(docID: Int64, page: Int, notice: String? = nil, time: Int? = nil,
              using openWindow: OpenWindowAction) {
        let decision = table.request(docID: docID, page: page)
        targets[decision.identity] = PreviewTarget(key: decision.target,
                                                   notice: notice, time: time)
        openWindow(id: "preview", value: decision.identity)
    }

    func open(_ key: HitKey, notice: String? = nil, time: Int? = nil,
              using openWindow: OpenWindowAction) {
        open(docID: key.docID, page: key.page, notice: notice, time: time,
             using: openWindow)
    }

    /// Ce que la fenêtre d'identité donnée doit montrer. Une fenêtre restaurée
    /// par macOS après un redémarrage n'est dans aucune table : elle montre
    /// alors ce que sa propre clé désigne, comme avant.
    func target(for identity: HitKey) -> PreviewTarget {
        targets[identity] ?? PreviewTarget(key: identity, notice: nil, time: nil)
    }

    func closed(identity: HitKey) {
        table.closed(identity: identity)
        targets[identity] = nil
    }
}
