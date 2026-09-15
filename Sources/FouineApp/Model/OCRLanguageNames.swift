// OCRLanguageNames.swift — le nom des langues de reconnaissance, tel qu'on le
// lit (audit AP-23, BU-08, BU-09 ; lot UX3). Propriété : A-App.
//
// TROIS DÉFAUTS MESURÉS DANS LA MÊME LISTE (09/09/2026, Réglages ▸ Indexation) :
//
//   · « vi-VT  vi-VT » — Vision rend cet identifiant tel quel (le code du
//     Viêt Nam est `VN` ; `VT` n'existe pas). `Locale` ne sait pas le nommer
//     et rendait `nil`, donc l'identifiant brut, deux fois : une ligne qui ne
//     dit rien à personne. On replie alors sur la langue SEULE — « vietnamien »
//     est vrai, et c'est tout ce que l'utilisateur a besoin de savoir.
//
//   · « Corée Du Sud », « Chinois Simplifié » — `capitalized(with:)` met une
//     capitale à CHAQUE mot. En français on écrit « Corée du Sud » et
//     « chinois simplifié » : seule la première lettre change, le reste est
//     celui d'ICU, qui connaît l'usage de chaque langue.
//
//   · Le code BCP-47 était affiché à côté du nom. Il ne sert à rien à qui
//     coche une case ; il part en info-bulle, où le dépanneur le retrouve.
//
// Le tri, lui, appartient à la vue : elle range par `localizedStandardCompare`
// du nom AFFICHÉ (« Allemand » avant « Anglais »), et non par code, qui donnait
// une liste de dix-huit cases apparemment non triée.

import Foundation

enum OCRLanguageNames {

    /// Le nom lisible d'un identifiant de reconnaissance.
    ///
    /// - Parameter identifier: ce que Vision rend — « fr-FR », « zh-Hans »,
    ///   « vi-VT »… Rendu tel quel si `Locale` n'en connaît même pas la langue.
    /// - Parameter locale: la langue de l'utilisateur.
    static func display(identifier: String,
                        locale: Locale = .autoupdatingCurrent) -> String {
        // `localizedString(forIdentifier:)` rend `nil` dès qu'une sous-balise
        // lui est inconnue — c'est exactement le cas « vi-VT », et c'est ce
        // qui rend le repli sur la langue seule à la fois simple et sûr.
        if let full = locale.localizedString(forIdentifier: identifier) {
            return capitalizingFirstLetter(full, locale: locale)
        }
        let language = identifier.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first.map(String.init) ?? identifier
        guard let name = locale.localizedString(forLanguageCode: language) else {
            return identifier
        }
        return capitalizingFirstLetter(name, locale: locale)
    }

    /// La première lettre en capitale, et elle seule : « chinois simplifié »
    /// devient « Chinois simplifié », jamais « Chinois Simplifié ».
    private static func capitalizingFirstLetter(_ text: String,
                                                locale: Locale) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased(with: locale) + text.dropFirst()
    }
}
