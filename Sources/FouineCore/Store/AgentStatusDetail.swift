// AgentStatusDetail.swift — ce que l'agent DIT qu'il fait, sans le dire dans
// une langue. Propriété : A-Core. Audit A1m-10.
//
// ═══ LE DÉFAUT QU'ON RÉPARE ══════════════════════════════════════════════════
//
// `agent_status.detail` était du TEXTE LIBRE, écrit par l'agent et ressorti tel
// quel par trois contrats : la sortie texte de `fouine status`, `status --json`
// et le serveur MCP. Deux fuites, relevées le 04/09/2026 sur la machine du
// mainteneur, l'une dans chaque sens :
//
//   · vers l'ANGLAIS. `fouine status` affichait « stopped · SIGTERM reçu » —
//     du français au milieu d'une sortie anglaise contractuelle. La phrase
//     venait d'un agent d'une version antérieure encore installé : la donnée
//     survit à la version qui l'a écrite, et n'importe quelle version passée ou
//     future peut déposer une phrase dans une autre langue.
//   · vers le FRANÇAIS de l'application. `AgentDetailText` ne savait traduire
//     que `queue-drained` ; tout le reste — « starting up », « 20226 page(s)
//     queued », « 315 page(s) left » — s'affichait EN ANGLAIS dans une barre
//     latérale française. La leçon d'`AgentStatusDetail` (« un JETON sans
//     langue, pas une phrase ») n'avait été appliquée qu'à un seul cas.
//
// ═══ LA FORME ════════════════════════════════════════════════════════════════
//
//   jeton                 `starting`, `queue-drained`
//   jeton(charge utile)   `pages-queued(20226)`, `signal-received(SIGTERM)`,
//                         `document(Cours de chimie.pdf)`
//
// La charge utile est tout ce qui sépare la PREMIÈRE parenthèse ouvrante de la
// DERNIÈRE fermante : un nom de document peut lui-même porter des parenthèses,
// et c'est le seul texte libre qui reste — un nom ne se traduit pas.
//
// ═══ LA COMPATIBILITÉ N'EST PAS OPTIONNELLE ══════════════════════════════════
//
// Une valeur inconnue s'affiche TELLE QUELLE, en anglais comme en français.
// C'est ce qui rend la migration sûre dans les deux sens : un agent d'une
// version antérieure (le cas observé) publie une phrase, une version ultérieure
// publiera peut-être un jeton que celle-ci ne connaît pas, et dans les deux cas
// l'utilisateur lit quelque chose plutôt que rien. Les conditions d'attente du
// §5.7 restent d'ailleurs du texte libre : elles portent des nombres relevés sur
// le système (« CPU_Speed_Limit 33 % ») et n'ont pas de forme close.

import Foundation

extension AgentStatusDetail {

    /// L'agent démarre : rien d'autre à dire pour l'instant.
    public static let starting = "starting"

    /// Un signal d'arrêt est arrivé (`SIGTERM`, `SIGINT`) : le nom du signal
    /// intéresse un dépanneur, jamais l'utilisateur de l'application.
    public static func signalReceived(_ name: String) -> String {
        "signal-received(\(name))"
    }

    /// Pages en file d'OCR au lancement d'un lot.
    public static func pagesQueued(_ count: Int) -> String {
        "pages-queued(\(count))"
    }

    /// Pages restantes PENDANT un lot (sonde de progression, toutes les 2 s).
    public static func pagesLeft(_ count: Int) -> String {
        "pages-left(\(count))"
    }

    /// Le document en cours. Le seul texte libre qui subsiste — un nom de
    /// fichier ne se traduit pas —, mais il est ÉTIQUETÉ comme tel : sans quoi
    /// rien ne distinguait « Cours de chimie.pdf » d'une phrase d'état.
    public static func document(_ name: String) -> String { "document(\(name))" }

    /// Ce qu'un `detail` veut dire. `free` est la valeur qu'on ne connaît pas :
    /// elle s'affiche telle quelle (voir l'en-tête).
    public enum Token: Equatable, Sendable {
        case queueDrained
        case starting
        case signalReceived(String)
        case pagesQueued(Int)
        case pagesLeft(Int)
        case document(String)
        case free(String)
    }

    public static func parse(_ raw: String) -> Token {
        let (name, payload) = split(raw)
        switch (name, payload) {
        case (queueDrained, nil):     return .queueDrained
        case (starting, nil):         return .starting
        case ("signal-received", _):  return .signalReceived(payload ?? "")
        case ("pages-queued", let p): return number(p).map { .pagesQueued($0) } ?? .free(raw)
        case ("pages-left", let p):   return number(p).map { .pagesLeft($0) } ?? .free(raw)
        case ("document", let p):     return p.map { .document($0) } ?? .free(raw)
        default:                      return .free(raw)
        }
    }

    /// La phrase ANGLAISE : celle de `fouine status`, du journal de l'agent et
    /// du serveur MCP (`docs/i18n.md` — la CLI et les journaux ne se traduisent
    /// pas). L'application, elle, part du JETON et rend sa propre phrase.
    public static func english(_ raw: String) -> String {
        switch parse(raw) {
        case .queueDrained:            return "OCR queue empty"
        case .starting:                return "starting up"
        case .signalReceived(let name):
            return name.isEmpty ? "shutdown signal received" : "\(name) received"
        case .pagesQueued(let n):      return "\(n) page(s) queued"
        case .pagesLeft(let n):        return "\(n) page(s) left"
        case .document(let name):      return name
        case .free(let text):          return text
        }
    }

    // MARK: - Découpage

    private static func split(_ raw: String) -> (name: String, payload: String?) {
        guard let open = raw.firstIndex(of: "("), raw.hasSuffix(")") else {
            return (raw, nil)
        }
        let name = String(raw[raw.startIndex..<open])
        let payload = String(raw[raw.index(after: open)..<raw.index(before: raw.endIndex)])
        return (name, payload)
    }

    private static func number(_ payload: String?) -> Int? {
        payload.flatMap(Int.init)
    }
}
