// TableOfContentsProbe.swift — cette page est-elle une TABLE DES MATIÈRES ?
// Propriété : A-Core. Audit AUDIT-RK du 09/09/2026, constat RK-07, lot RK2.
//
// LE CONSTAT. `spectro*` rend un nDCG@10 de 0,213, et huit des dix candidats
// sont des sommaires, des index ou des listes de mots-clés (`445 p.9`,
// `787 p.13`, `121 p.13`, `445 p.10`, `791 p.7`, `804 p.14`, `764 p.177`) ;
// une seule page traite le sujet (`198 p.822`). `thermodyn*` : deux index et
// une page de références sur dix. Les cinq systèmes lexicaux du banc rendent
// EXACTEMENT le même classement sur les requêtes à préfixe (0,690 partout) :
// ni la morphologie, ni la diversité, ni les bonus M1 n'y touchent. La cause
// est mécanique — une table des matières est la page du livre où un préfixe
// apparaît le plus souvent, et un classement par fréquence y mène tout droit.
//
// CE FICHIER NE LIT PAS LA BASE et ne connaît pas la requête : il reçoit le
// TEXTE d'une page et rend un verdict. C'est la condition pour qu'il soit
// testable sur des pages réelles (`TableOfContentsProbeTests` en fixe des
// extraits) et pour qu'il ne coûte rien à l'extraction — aucun changement de
// schéma, le malus se calcule sur les candidats d'une recherche.
//
// TOUTE LA PAGE, JAMAIS UN EXTRAIT. Mesuré sur la base de production le
// 11/09/2026 : `158 p.583` — le sujet Thermochimie d'Atkins, l'une des deux
// bonnes réponses de RK-04, notée 2 au banc — COMMENCE par son propre sommaire
// (« Contents / 57.1 Calorimetry 560 / (a) Conventional calorimetry 561 … »).
// Sur ses 300 premiers caractères la sonde dit « sommaire » ; sur la page
// entière elle dit « non » (0,29 de lignes numérotées contre un seuil de 0,30).
// L'appelant lit donc `page_fts.body`, jamais l'extrait de la recherche.

import Foundation

public enum TableOfContentsProbe {

    // MARK: - Les trois signes, et ce qui les a calibrés
    //
    // Calibrés le 11/09/2026 sur la base de production, en lecture seule : les
    // sept pages nommées par RK-07 d'un côté, vingt-trois pages de prose notées
    // 2 au banc de l'autre (102 p.335, 102 p.792, 104 p.655, 121 p.327/719/769/
    // 771, 1294 p.51/63/89/184, 143 p.36, 145 p.51/126, 150 p.332, 158 p.35/
    // 589/682, 171 p.1065, 192 p.605, 268 p.344, 1520 p.4, 1525 p.16).
    //
    // CE QU'ELLE ATTRAPE, ET CE QU'ELLE LAISSE (mesure du 11/09/2026) : vrai
    // sur `445 p.9`, `121 p.13`, `791 p.7` et `804 p.14` ; FAUX sur les vingt-
    // trois pages de prose, aucune exception. Trois pages du constat lui
    // échappent, et il faut le savoir avant d'armer le malus :
    //   · `787 p.13` (sommaire de fin de manuel) — 0,82 de lignes numérotées,
    //     mais 27 % de lignes courtes et 0,56 de mots uniques : UN seul signe.
    //     Descendre le seuil des lignes courtes à 25 % le rattraperait, au prix
    //     d'un signe qui s'allume sur la majorité des pages de prose.
    //   · `445 p.10` (suite d'un sommaire, dont les lignes sont des phrases
    //     descriptives) — 0,22 de lignes numérotées, aucun signe franc.
    //   · `764 p.177` (liste de mots-clés de fin de chapitre) — aucun nombre,
    //     aucun point de conduite : seul le signe de forme s'allume, et il ne
    //     se distingue pas d'une page de diapositives OCRisée (`1294 p.184`,
    //     87 % de lignes courtes, notée 2).
    // Le malus est livré DÉSARMÉ pour cette raison : c'est le banc jugé qui dit
    // si attraper quatre sommaires sur sept vaut le risque de reculer une page.

    /// Part MINIMALE des lignes non vides qui se terminent par un nombre —
    /// le numéro de page d'une entrée de sommaire. Le signe le plus
    /// discriminant des trois : les sommaires mesurés vont de 0,41 à 0,82, la
    /// prose ne dépasse jamais 0,29.
    public static let numberedLineShare = 0.30

    /// Part MINIMALE des caractères qui sont des points de conduite (suites de
    /// trois points ou plus, `…`) ou des tabulations. Rare dans ce corpus —
    /// l'extraction les retire le plus souvent —, mais franc quand il est là :
    /// `804 p.14` en porte 61 %, aucune page de prose n'en porte plus de 0,3 %.
    public static let leaderCharacterShare = 0.05

    /// Un sommaire répète les mêmes mots (« Chapter », « Spectrometry »,
    /// « Analysis ») : sous ce ratio mots-uniques / mots, la page ne raconte
    /// rien. Ne vaut qu'à partir de `repeatedWordMinimum` mots — sur trente
    /// mots, tout texte a un ratio élevé.
    public static let repeatedWordRatio = 0.5
    public static let repeatedWordMinimum = 80

    /// Une liste d'index est faite de lignes courtes. Part MINIMALE des lignes
    /// non vides qui comptent moins de `shortLineWords` mots.
    public static let shortLineShare = 0.40
    public static let shortLineWords = 6

    /// Les trois signes d'une page, chacun pour ce qu'il vaut. Rendus séparément
    /// pour que les tests les éprouvent un par un : un verdict qui ne dit pas
    /// QUEL signe a parlé ne se calibre pas.
    public struct Signs: Sendable, Equatable {
        /// Les lignes se terminent par un numéro de page.
        public let numberedLines: Bool
        /// Points de conduite ou tabulations.
        public let leaders: Bool
        /// Forme de liste : mots répétés, ou lignes courtes.
        public let listShape: Bool

        public var count: Int {
            (numberedLines ? 1 : 0) + (leaders ? 1 : 0) + (listShape ? 1 : 0)
        }
    }

    /// DEUX SIGNES SUR TROIS. Un seul ne suffit pas : une page d'exercices
    /// numérotés porte des nombres en fin de ligne, une page de diapositives
    /// OCRisée est faite de lignes courtes, et reculer l'une ou l'autre coûterait
    /// une vraie réponse. Deux signes ensemble ne se rencontrent, sur les
    /// vingt-trois pages de prose mesurées, jamais.
    public static func isTableOfContents(_ text: String) -> Bool {
        signs(of: text).count >= 2
    }

    public static func signs(of text: String) -> Signs {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else {
            return Signs(numberedLines: false, leaders: false, listShape: false)
        }
        let total = Double(lines.count)

        let numbered = lines.filter(endsWithNumber).count
        let shortLines = lines.filter { wordCount(of: $0) < shortLineWords }.count

        var words: [String] = []
        for line in lines { words.append(contentsOf: self.words(of: line)) }
        let unique = Set(words).count
        let repeated = words.count >= repeatedWordMinimum
            && Double(unique) / Double(words.count) <= repeatedWordRatio

        return Signs(
            numberedLines: Double(numbered) / total >= numberedLineShare,
            leaders: leaderShare(of: text) >= leaderCharacterShare,
            listShape: repeated || Double(shortLines) / total >= shortLineShare)
    }

    // MARK: - Les mesures

    /// La ligne finit-elle par un NUMÉRO DE PAGE ? Un point final est toléré
    /// (« 141. »), et le nombre doit être un jeton ENTIER, détaché du reste par
    /// une espace : « Questions and Problems 143 » oui, « 284 » seul aussi,
    /// « H2O » non — et « 5.0 » non plus. Ce dernier cas est mesuré : `121
    /// p.771` (un tableau de valeurs, page de prose notée 2 au banc) est faite
    /// de lignes « 5.0 », « 4.0 », « 1.2 », et compter la décimale comme un
    /// numéro de page la faisait reculer.
    static func endsWithNumber(_ line: String) -> Bool {
        var chars = Array(line)
        if chars.last == "." { chars.removeLast() }
        var i = chars.count
        while i > 0, chars[i - 1].isNumber { i -= 1 }
        guard i < chars.count else { return false }        // aucun chiffre final
        return i == 0 || chars[i - 1].isWhitespace
    }

    /// Part des caractères pris par les points de conduite et les tabulations.
    /// TROIS POINTS AU MOINS : « etc. » et une abréviation ne sont pas une
    /// conduite, et compter tous les points ferait monter n'importe quelle prose.
    static func leaderShare(of text: String) -> Double {
        guard !text.isEmpty else { return 0 }
        var leaders = 0
        var run = 0
        for ch in text {
            if ch == "." {
                run += 1
            } else {
                if run >= 3 { leaders += run }
                run = 0
                if ch == "\t" || ch == "…" { leaders += 1 }
            }
        }
        if run >= 3 { leaders += run }
        return Double(leaders) / Double(text.count)
    }

    /// Les mots d'une ligne, aux frontières du tokenizer de l'index (tout ce qui
    /// n'est ni lettre ni chiffre coupe) et en minuscules : « Chapter » et
    /// « chapter » sont le même mot répété.
    static func words(of line: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in line {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                out.append(current.lowercased())
                current = ""
            }
        }
        if !current.isEmpty { out.append(current.lowercased()) }
        return out
    }

    static func wordCount(of line: String) -> Int { words(of: line).count }
}
