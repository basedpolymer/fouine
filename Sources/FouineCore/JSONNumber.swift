// JSONNumber.swift — nombres décimaux lisibles et stables pour la sérialisation JSON (audit H4, palier 5).
// Propriété : A-Core. SPEC §4.3.

import Foundation

public enum JSONNumber {
    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    /// Arrondit un nombre à `places` décimales sous forme de `NSDecimalNumber`,
    /// sérialisé proprement par `JSONSerialization` sans l'effet flottant
    /// binaire IEEE 754 (ex. 16.63 au lieu de 16.629999999999999).
    public static func rounded(_ value: Double, places: Int = 2) -> NSDecimalNumber {
        guard value.isFinite else { return NSDecimalNumber.zero }
        let str = String(format: "%.\(places)f", locale: posixLocale, value)
        return NSDecimalNumber(string: str, locale: posixLocale)
    }

    /// Raccourci pour un pourcentage entre 0 et 100 à 2 décimales.
    public static func percentage(_ value: Double, places: Int = 2) -> NSDecimalNumber {
        rounded(value, places: places)
    }
}
