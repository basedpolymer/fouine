// DocumentDate.swift — LA DATE DU DOCUMENT, et non celle du fichier (lot DD1,
// constat PR-07). Propriété : A-Core.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// LE CONSTAT (audit du 09/09/2026, § PR-07). La seule date que Fouine
// connaissait était `docs.mtime` : la date à laquelle le FICHIER a changé sur
// le disque. Sur le fonds réel, la facette « Modifié en » ne rendait que cinq
// valeurs, toutes postérieures à 2021, pour 1 527 documents dont la majorité
// sont des ouvrages publiés entre 1960 et 2020 — recopier un livre de 2003 sur
// un Mac en 2024 le range sous 2024. Les extracteurs traversaient pourtant
// déjà la métadonnée : PDF `CreationDate`, EPUB `dc:date`, OOXML
// `dcterms:created`, EXIF `DateTimeOriginal`, en-tête `Date:` d'un courriel.
//
// TROIS DÉCISIONS, toutes vérifiables par `DocumentDateTests` :
//
//   1. UN JOUR, PAS UN INSTANT. « Ce livre est de 2003 » n'a pas d'heure et
//      n'a pas de fuseau. La valeur écrite en base est donc le jour civil de
//      la métadonnée, ramené à MIDI UTC : `strftime('%Y', doc_date,
//      'unixepoch')` — sans `'localtime'`, contrairement à la facette des
//      `mtime` — rend alors la bonne année sur tout le globe, de Honolulu à
//      Auckland. Une heure de nuit tombée d'un fuseau à l'autre aurait décalé
//      l'année d'un cran pour une partie des acheteurs.
//
//   2. ON NE DEVINE RIEN. « 12/04/2003 » n'est pas analysé : c'est le 12 avril
//      pour un Français et le 4 décembre pour un Américain, et rien dans la
//      chaîne ne dit lequel. Une date fausse est pire qu'une date absente —
//      elle range le document sous une année qui n'existe pas pour lui, sans
//      que personne puisse s'en apercevoir.
//
//   3. LES BORNES SONT SERRÉES. Les producteurs de PDF écrivent n'importe
//      quoi : `D:19000101000000` pour « pas de date », des années 2099 quand
//      l'horloge de la machine était fausse. Le 1ᵉʳ janvier 1900, ce qui le
//      précède et tout ce qui suit demain sont REFUSÉS — la colonne reste vide, et le document sort sous la
//      clé « sans date » plutôt que sous une année absurde qui polluerait la
//      facette.
//
// Ce fichier est PUR : aucune entrée-sortie, aucun `DateFormatter` (donc
// aucune dépendance à la locale ni au fuseau de la machine), aucun accès à la
// base. C'est ce qui permet de l'éprouver format par format.

import Foundation

public enum DocumentDate {

    /// Premier jour REFUSÉ par le bas : le 1ᵉʳ janvier 1900. Refusé et non
    /// accepté, parce que c'est LA valeur de remplissage des producteurs de
    /// PDF (`D:19000101000000` = « je n'ai pas de date »). Un document
    /// réellement daté de ce jour-là existe en théorie ; dans un fonds réel, la
    /// chaîne signifie toujours l'absence de date, et un ouvrage du 2 janvier
    /// 1900 reste accepté.
    public static let earliestRefusedDay = (year: 1900, month: 1, day: 1)

    /// Marge sur l'avenir, en JOURS : un document daté de demain reste
    /// plausible (fuseau en avance, horloge de quelques heures) ; après-demain,
    /// non. En jours et non en secondes, sinon un document daté de demain à
    /// midi UTC serait refusé le matin même.
    public static let futureToleranceDays = 1

    /// Analyse une date de métadonnée. Rend le jour civil à MIDI UTC, ou `nil`
    /// si la chaîne n'est pas reconnue ou si la date sort des bornes.
    ///
    /// Formats acceptés, dans l'ordre où ils sont essayés :
    ///   · ISO 8601 : `2003`, `2003-04`, `2003-04-12`, `2003-04-12T10:30:00Z` ;
    ///   · PDF : `D:20030412103000+02'00'` (le préfixe `D:` est facultatif) ;
    ///   · RFC 5322 (courriel) : `Sat, 12 Apr 2003 10:30:00 +0200` ;
    ///   · EXIF : `2003:04:12 10:30:00`.
    ///
    /// L'heure et le fuseau sont LUS mais jetés : seule la date civile écrite
    /// dans la métadonnée est retenue (décision n°1).
    public static func parse(_ raw: String, now: Date = Date()) -> Double? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard let civil = civilDate(text) else { return nil }
        guard let seconds = noonUTC(year: civil.year, month: civil.month,
                                    day: civil.day) else { return nil }
        // Les bornes se comparent en JOURS : c'est l'unité de la valeur.
        let day = Int(floor(seconds / 86_400.0))
        let floorDay = daysFromCivil(year: earliestRefusedDay.year,
                                     month: earliestRefusedDay.month,
                                     day: earliestRefusedDay.day)
        let today = Int(floor(now.timeIntervalSince1970 / 86_400.0))
        guard day > floorDay, day <= today + futureToleranceDays else { return nil }
        return seconds
    }

    /// Le jour civil d'une valeur écrite par `parse` : l'inverse exact, pour
    /// l'affichage (« daté du 12 avril 2003 ») et pour les tests.
    public static func civil(_ seconds: Double) -> (year: Int, month: Int, day: Int) {
        civilFromDays(Int(floor(seconds / 86_400.0)))
    }

    /// L'année, telle que la facette `doc_year` la rend (`strftime('%Y')` sans
    /// `'localtime'`). Point unique : l'interface et le SQL doivent dire le
    /// même millésime.
    public static func year(_ seconds: Double) -> Int { civil(seconds).year }

    /// Le jour civil d'un `Date`, en `YYYY-MM-DD` — ce que les extracteurs
    /// déposent dans `meta["date"]` quand l'API leur rend un INSTANT plutôt
    /// qu'une chaîne (PDFKit : `creationDateAttribute` est un `Date`).
    ///
    /// Le fuseau est celui de la MACHINE par défaut, et non UTC : PDFKit a déjà
    /// absorbé le décalage écrit dans le fichier (`+02'00'`), et il ne reste
    /// aucun moyen de retrouver le jour tel que le producteur l'a écrit. Le
    /// jour local est le plus proche pour un document fabriqué là où on le lit,
    /// et l'écart possible est d'UN jour sur une date fabriquée à l'autre bout
    /// du monde à minuit — sans conséquence sur l'année, seul niveau que la
    /// facette expose.
    public static func isoDay(_ date: Date, timeZone: TimeZone = .current) -> String {
        let shifted = date.timeIntervalSince1970
            + Double(timeZone.secondsFromGMT(for: date))
        let civil = civilFromDays(Int(floor(shifted / 86_400.0)))
        return String(format: "%04d-%02d-%02d", civil.year, civil.month, civil.day)
    }

    // MARK: - Reconnaissance des formats

    private static func civilDate(_ text: String) -> (year: Int, month: Int, day: Int)? {
        if let d = rfc5322(text) { return d }
        if let d = compact(text) { return d }         // PDF : D:YYYYMMDD…
        return separated(text)                        // ISO et EXIF
    }

    /// ISO 8601 (`-`) et EXIF (`:`) : les deux ne diffèrent que par le
    /// séparateur de la partie DATE, et l'un comme l'autre écrit l'année en
    /// tête sur quatre chiffres. Un seul analyseur, donc — c'est le fait
    /// d'écrire l'année d'abord qui rend la chaîne non ambiguë, pas le tiret.
    private static func separated(_ text: String) -> (year: Int, month: Int, day: Int)? {
        // La partie date s'arrête au premier séparateur d'heure.
        let head = text.prefix { $0 != "T" && $0 != "t" && $0 != " " }
        let parts = head.split(separator: "-", omittingEmptySubsequences: false)
        let fields: [Substring]
        if parts.count > 1 {
            fields = parts
        } else {
            fields = head.split(separator: ":", omittingEmptySubsequences: false)
        }
        guard (1...3).contains(fields.count) else { return nil }
        guard fields[0].count == 4, let year = digits(fields[0]) else { return nil }
        // « 2003 » seul : le 1ᵉʳ janvier (voir `PreviewSubtitle`, qui n'affiche
        // alors que l'année plutôt que d'inventer un jour).
        guard fields.count > 1 else { return (year, 1, 1) }
        guard fields[1].count == 2, let month = digits(fields[1]) else { return nil }
        guard fields.count > 2 else { return (year, month, 1) }
        guard fields[2].count == 2, let day = digits(fields[2]) else { return nil }
        return (year, month, day)
    }

    /// PDF : `D:YYYYMMDDHHmmSSOHH'mm'`, le préfixe et tout ce qui suit le jour
    /// étant facultatifs (§7.9.4 de la spécification PDF).
    private static func compact(_ text: String) -> (year: Int, month: Int, day: Int)? {
        var body = Substring(text)
        if body.hasPrefix("D:") || body.hasPrefix("d:") { body = body.dropFirst(2) }
        let head = body.prefix(while: { $0.isNumber })
        // Il faut au moins l'année, et une chaîne de 4 chiffres sans préfixe
        // `D:` a déjà été traitée par `separated`. On exige donc le jour :
        // c'est la forme qu'écrivent réellement les producteurs de PDF.
        guard head.count >= 8 else { return nil }
        guard let year = digits(head.prefix(4)),
              let month = digits(head.dropFirst(4).prefix(2)),
              let day = digits(head.dropFirst(6).prefix(2))
        else { return nil }
        return (year, month, day)
    }

    /// RFC 5322 : `[jour, ]12 Apr 2003[ 10:30:00 +0200]`. Le nom du mois est
    /// ANGLAIS par la norme — un en-tête localisé est un en-tête hors norme, et
    /// on ne le devine pas.
    private static func rfc5322(_ text: String) -> (year: Int, month: Int, day: Int)? {
        var body = Substring(text)
        if let comma = body.firstIndex(of: ",") { body = body[body.index(after: comma)...] }
        let fields = body.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 3 else { return nil }
        guard (1...2).contains(fields[0].count), let day = digits(fields[0]),
              let month = monthNames[fields[1].lowercased()],
              (2...4).contains(fields[2].count), let rawYear = digits(fields[2])
        else { return nil }
        // Années à deux chiffres de la RFC 822 : la RFC 5322 impose de les lire
        // dans [1950, 2049]. Un courriel de 1994 existe ; un de 2094, non.
        let year = fields[2].count <= 2 ? (rawYear < 50 ? 2000 + rawYear : 1900 + rawYear)
                                        : rawYear
        return (year, month, day)
    }

    private static let monthNames: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
        "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
    ]

    /// Un entier fait UNIQUEMENT de chiffres ASCII. `Int("٤٢")` accepte les
    /// chiffres arabes-indiens et `Int(" 42")` les espaces : ni l'un ni l'autre
    /// n'est une date de métadonnée.
    private static func digits(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber })
        else { return nil }
        return Int(text)
    }

    // MARK: - Calendrier grégorien, à la main

    /// Midi UTC du jour civil, ou `nil` si le jour n'existe pas (31 février,
    /// mois 13, jour 0 : ce que les métadonnées cassées produisent).
    static func noonUTC(year: Int, month: Int, day: Int) -> Double? {
        guard (1...12).contains(month),
              (1...daysInMonth(year: year, month: month)).contains(day)
        else { return nil }
        return Double(daysFromCivil(year: year, month: month, day: day)) * 86_400.0
            + 43_200.0
    }

    static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2: return isLeap(year) ? 29 : 28
        default: return 0
        }
    }

    static func isLeap(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    /// Jours depuis 1970-01-01 (algorithme de Howard Hinnant, `days_from_civil`).
    /// Écrit à la main plutôt que confié à `Calendar` : `Calendar.current` porte
    /// le fuseau ET le calendrier de la machine, et une date de document ne doit
    /// dépendre ni de l'un ni de l'autre.
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400                                   // [0, 399]
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy           // [0, 146096]
        return era * 146_097 + doe - 719_468
    }

    /// L'inverse (`civil_from_days` du même auteur).
    static func civilFromDays(_ days: Int) -> (year: Int, month: Int, day: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp + (mp < 10 ? 3 : -9)
        return (y + (m <= 2 ? 1 : 0), m, d)
    }
}
