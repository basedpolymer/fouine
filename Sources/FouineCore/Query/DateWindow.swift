// DateWindow.swift — les bornes de date que `SearchQuery.modifiedAfter` attend.
// Propriété : A-Core. Lot U2 (R-07).
//
// POURQUOI DANS LE CŒUR, et pas dans l'application ni dans la CLI : les deux
// surfaces expriment la MÊME chose — « modifié depuis » — et devaient sinon la
// calculer chacune de leur côté. Les puces « Cette année » et « 5 dernières
// années » de l'application et l'option `fouine search --since` doivent rendre
// exactement la même liste sur la même base, sans quoi l'une des deux ment.
//
// ANNÉES CIVILES, HEURE LOCALE. C'est déjà la convention de la facette
// « Années » (`strftime('%Y', mtime, 'unixepoch', 'localtime')`) : « cette
// année » veut dire « depuis le 1ᵉʳ janvier », pas « depuis douze mois ». Les
// deux se défendent ; le même mot doit désigner la même chose aux deux endroits
// de l'interface, et c'est la facette qui était là la première.

import Foundation

public enum DateWindow {

    /// Instant qui ouvre l'année civile de `date`, reculée de `yearsBack`
    /// années — 0 = le 1ᵉʳ janvier de cette année, 4 = celui d'il y a quatre
    /// ans, donc « les cinq dernières années » celle-ci comprise.
    ///
    /// `nil` seulement si le calendrier ne sait pas construire la date, ce qui
    /// n'arrive pas avec un calendrier grégorien : l'appelant retombe alors sur
    /// « aucune borne », jamais sur une borne fausse.
    public static func startOfYear(_ date: Date, yearsBack: Int = 0,
                                   calendar: Calendar = .current) -> Double? {
        var components = DateComponents()
        components.year = calendar.component(.year, from: date) - yearsBack
        components.month = 1
        components.day = 1
        return calendar.date(from: components)?.timeIntervalSince1970
    }

    /// Instant qui ouvre le jour d'une date écrite `AAAA-MM-JJ`, en heure
    /// locale. `nil` si la chaîne n'a pas cette forme ou ne nomme pas un jour
    /// réel (`2025-02-30`).
    ///
    /// Sans `DateFormatter` : celui-ci accepte des entrées surprenantes selon la
    /// locale et le fuseau du Mac, et une borne de date silencieusement décalée
    /// d'un jour est exactement le genre de faute qu'un utilisateur ne peut pas
    /// voir. Trois entiers, un `DateComponents`, et la validation par
    /// l'aller-retour.
    public static func startOfDay(iso8601 text: String,
                                  calendar: Calendar = .current) -> Double? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]),
              let day = Int(parts[2])
        else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components),
              // `2025-02-30` donne le 2 mars : l'aller-retour l'attrape.
              calendar.component(.day, from: date) == day,
              calendar.component(.month, from: date) == month
        else { return nil }
        return date.timeIntervalSince1970
    }
}
