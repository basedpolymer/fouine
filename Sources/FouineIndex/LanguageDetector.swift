// LanguageDetector.swift — la langue dominante d'un document. A-Core, audit X2.
//
// `docs.lang` (`Schema.swift`) existe depuis la vague 0 et n'a jamais été
// alimentée : `DocRecord.lang = nil`, partout (audit F8). La colonne était donc
// une promesse morte — et la seule chose qui permettrait un jour de choisir les
// langues d'OCR par document plutôt que globalement (X2).
//
// `NLLanguageRecognizer` est un framework SYSTÈME (NaturalLanguage) : aucune
// dépendance SPM nouvelle, aucun modèle à télécharger, rien qui sorte de la
// machine.
//
// OÙ L'ON REGARDE COMPTE PLUS QUE CE QU'ON DEMANDE (constat C2-01, 09/09/2026).
// L'échantillon était les 4 000 PREMIERS caractères, dans l'ordre des pages. Or
// le début d'un vrai document n'est presque jamais de la prose : c'est une
// licence Gutenberg (mille mots d'anglais devant un roman de Maupassant), une
// page de garde d'éditeur, un en-tête `From:/Subject:/Message-ID:`, ou le bruit
// d'un scan. Mesuré sur la base de production : 62 documents rangés en hongrois,
// danois, finnois ou polonais sur un fonds franco-anglais, 269 sans langue — et
// « Le Horla », en français, introuvable avec le filtre « Français ».
//
// L'échantillon est donc pris en TROIS TRANCHES (10 %, 50 %, 90 % de la matière)
// qui VOTENT, et les en-têtes de courriel sont retirés de la tête du document
// avant tout. Le rattrapage `fouine maintain --redetect-languages` rejoue la
// détection sur un fonds déjà indexé.
//
// TROIS PRÉCAUTIONS, chacune payée par une observation :
//
//   1. ÉCHANTILLON BORNÉ à 4 000 caractères. Le reconnaisseur est linéaire dans
//      la taille du texte, et un ouvrage de 1 570 pages en fait plusieurs
//      millions ; au-delà de quelques milliers de caractères, l'hypothèse ne
//      bouge plus. C'est aussi la taille d'une « page » des formats non paginés
//      (`ExtractLimits.pageSplitChars`), donc l'ordre de grandeur naturel ici.
//      Les décalages des tranches se calculent sur les LONGUEURS de pages :
//      seules les pages traversées par une tranche sont lues, jamais les 1 570.
//
//   2. SEUIL DE CONFIANCE. `dominantLanguage` répond TOUJOURS quelque chose,
//      même sur trois mots de charabia : sans seuil, `docs.lang` se remplirait
//      de langues inventées, ce qui est pire que la colonne vide d'aujourd'hui.
//      On exige donc une hypothèse dominante à 0,50 et un minimum de matière.
//
//   3. ISO 639-1 STRICT. `NLLanguage.rawValue` rend « zh-Hans » ou « zh-Hant »
//      pour le chinois : on ne garde que la sous-étiquette principale, sans
//      quoi `docs.lang` mélangerait deux conventions dans la même colonne.
//
// HORS PÉRIMÈTRE, assumé : aucune facette « Langue » n'est ajoutée à
// l'interface. Les facettes vivent dans `SearchModel`, `ResultsView` et
// `SidebarView`, qui appartiennent à un autre agent sur ce palier ; la colonne
// est désormais REMPLIE, l'exposer est un geste d'interface à part entière.

import Foundation
import NaturalLanguage
import FouineCore

public enum LanguageDetector {

    /// Caractères examinés au maximum. Voir précaution n°1.
    public static let sampleCharacters = 4_000

    /// En deçà, on ne se prononce pas : « Merci. » n'est pas un échantillon.
    public static let minimumCharacters = 40

    /// Probabilité minimale de l'hypothèse dominante. Voir précaution n°2.
    public static let minimumConfidence = 0.50

    /// Nombre de tranches quand le document en a la matière (C2-01).
    public static let sliceCount = 3

    /// Longueur d'une tranche quand il y en a plusieurs.
    static var sliceCharacters: Int { max(1, sampleCharacters / sliceCount) }

    /// Lignes de tête examinées à la recherche d'un en-tête de courriel.
    static let headerLinesExamined = 40

    // MARK: - Décision

    /// Code ISO 639-1 de la langue dominante, ou `nil` si indéterminée.
    ///
    /// Chaque tranche vote : elle donne son hypothèse dominante si elle atteint
    /// `minimumConfidence`, et la langue majoritaire l'emporte. Une seule
    /// tranche valide suffit ; une ÉGALITÉ ne tranche rien — deux tranches qui
    /// se contredisent valent « je ne sais pas », jamais une troisième langue.
    public static func detect(_ slices: [String]) -> String? {
        var votes: [String: Int] = [:]
        for slice in slices {
            guard let lang = hypothesis(slice) else { continue }
            votes[lang, default: 0] += 1
        }
        guard let best = votes.max(by: { $0.value < $1.value }) else { return nil }
        guard votes.values.filter({ $0 == best.value }).count == 1 else { return nil }
        return best.key
    }

    /// Raccourci sur UNE tranche : un texte déjà choisi, déjà borné.
    ///
    /// - Parameter text: le texte à examiner. Seuls les `sampleCharacters`
    ///   premiers caractères le sont.
    public static func detect(_ text: String) -> String? {
        hypothesis(text)
    }

    /// L'hypothèse d'une tranche, ou `nil` : trop courte, ou trop incertaine.
    static func hypothesis(_ text: String) -> String? {
        let sample = String(text.prefix(sampleCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard sample.count >= minimumCharacters else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let dominant = recognizer.dominantLanguage,
              dominant != .undetermined else { return nil }
        let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
        guard let confidence = hypotheses[dominant],
              confidence >= minimumConfidence else { return nil }
        return iso639_1(dominant.rawValue)
    }

    // MARK: - Échantillon

    /// Les tranches à soumettre au vote, tirées des pages extraites.
    ///
    /// DEUX RÉGIMES, et le second existe pour l'appelant qui a DÉJÀ choisi où
    /// regarder :
    ///
    ///   · les pages forment DEUX ou TROIS groupes séparés (numéros de page non
    ///     consécutifs) : le rattrapage de langue (`GRDBStore.languageSample`)
    ///     ne lit que trois régions du document, réparties sur sa longueur. Un
    ///     groupe = une tranche, prise en son MILIEU ;
    ///   · sinon — un seul bloc, ou un document si troué qu'aucun découpage n'a
    ///     de sens — les tranches se calculent sur les décalages : trois
    ///     tranches à 10 %, 50 % et 90 % quand le texte dépasse trois fois
    ///     l'échantillon, une tranche au milieu quand il dépasse l'échantillon,
    ///     tout le texte sinon.
    ///
    /// Chaque tranche commence et finit sur une frontière de mot, et les
    /// en-têtes de courriel sont retirés de la tête du document (C2-01).
    public static func sample(pages: [PageText]) -> [String] {
        let ordered = pages.sorted { $0.page < $1.page }
        guard !ordered.isEmpty else { return [] }

        // Groupes de pages consécutives.
        var groups: [[PageText]] = []
        for page in ordered {
            if let last = groups.last?.last, last.page + 1 == page.page {
                groups[groups.count - 1].append(page)
            } else {
                groups.append([page])
            }
        }
        var texts = groups.map { $0.map(\.text).joined(separator: "\n") }
        texts[0] = strippingMailHeaders(texts[0])

        if (2...sliceCount).contains(texts.count) {
            return texts.compactMap { text -> String? in
                let count = text.count
                let want = min(count, sliceCharacters)
                let slice = window(in: [text], lengths: [count],
                                   start: (count - want) / 2, length: want,
                                   total: count)
                return slice.isEmpty ? nil : slice
            }
        }

        let lengths = texts.map(\.count)
        // Le « \n » virtuel entre deux groupes compte dans les décalages :
        // c'est lui qui fait que `window` n'a rien à recoller.
        let total = lengths.reduce(0, +) + max(0, lengths.count - 1)
        if total <= sampleCharacters {
            let whole = window(in: texts, lengths: lengths, start: 0,
                               length: total, total: total)
            return whole.isEmpty ? [] : [whole]
        }
        if total <= sliceCount * sampleCharacters {
            let want = sampleCharacters
            return [window(in: texts, lengths: lengths,
                           start: (total - want) / 2, length: want, total: total)]
        }
        let want = sliceCharacters
        return [0.10, 0.50, 0.90].map { ratio in
            let start = min(total - want, max(0, Int(Double(total) * ratio)))
            return window(in: texts, lengths: lengths, start: start,
                          length: want, total: total)
        }.filter { !$0.isEmpty }
    }

    /// `length` caractères à partir du décalage GLOBAL `start`, en ne traversant
    /// que les pages concernées — un ouvrage de 1 570 pages ne se concatène pas
    /// pour reconnaître sa langue.
    ///
    /// La tranche est ramenée sur des frontières de mot : un échantillon qui
    /// commence par « tásha » et finit par « polym » donne au reconnaisseur des
    /// mots qui n'existent dans aucune langue.
    static func window(in texts: [String], lengths: [Int],
                       start: Int, length: Int, total: Int) -> String {
        guard length > 0 else { return "" }
        let end = min(total, start + length)
        var out = ""
        out.reserveCapacity(length)
        var cursor = 0
        for (index, count) in lengths.enumerated() {
            let pageStart = cursor
            cursor += count + 1                     // le « \n » entre deux pages
            guard pageStart + count > start else { continue }
            guard pageStart < end else { break }
            let text = texts[index]
            let from = max(0, start - pageStart)
            let to = min(count, end - pageStart)
            guard from < to else { continue }
            if !out.isEmpty { out += "\n" }
            out += text[text.index(text.startIndex, offsetBy: from)
                        ..< text.index(text.startIndex, offsetBy: to)]
        }
        return alignToWords(out, dropLeading: start > 0, dropTrailing: end < total)
    }

    /// Retire le mot coupé au début et celui coupé à la fin.
    static func alignToWords(_ text: String, dropLeading: Bool,
                             dropTrailing: Bool) -> String {
        var slice = Substring(text)
        if dropLeading, let space = slice.firstIndex(where: { $0.isWhitespace }) {
            slice = slice[slice.index(after: space)...]
        }
        if dropTrailing, let space = slice.lastIndex(where: { $0.isWhitespace }) {
            slice = slice[..<space]
        }
        return String(slice).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Retire les en-têtes RFC 822 des premières lignes du document.
    ///
    /// `From:`, `Subject:`, `Message-ID:` ne sont la langue de personne — le
    /// courriel français `courriel-rendez-vous-ravalement.eml` était rangé en
    /// islandais à cause d'eux (C2-01). On ne regarde que les
    /// `headerLinesExamined` premières lignes : plus loin, « Article: » est une
    /// phrase, pas un en-tête.
    static func strippingMailHeaders(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard lines.count > 1 else { return text }
        let window = min(headerLinesExamined, lines.count)
        var kept: [String] = []
        kept.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() {
            if index < window, looksLikeMailHeader(line) { continue }
            kept.append(line)
        }
        return kept.joined(separator: "\n")
    }

    /// `^[A-Za-z][A-Za-z0-9-]{1,30}: ` — un nom d'en-tête, deux points, une
    /// espace. Le nom sans espace est ce qui distingue `Message-ID: 4` d'une
    /// phrase française à deux points.
    static func looksLikeMailHeader(_ line: String) -> Bool {
        guard let colon = line.firstIndex(of: ":") else { return false }
        let name = line[line.startIndex..<colon]
        guard (2...31).contains(name.count), let first = name.first,
              first.isASCII, first.isLetter else { return false }
        guard name.allSatisfy({
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-")
        }) else { return false }
        let after = line.index(after: colon)
        return after < line.endIndex && line[after] == " "
    }

    /// « zh-Hans » -> « zh », « fr » -> « fr ». Vide -> `nil`.
    static func iso639_1(_ raw: String) -> String? {
        let primary = raw.split(separator: "-").first.map(String.init)?.lowercased()
        guard let primary, !primary.isEmpty else { return nil }
        return primary
    }
}
