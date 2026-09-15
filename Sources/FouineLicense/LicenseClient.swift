// LicenseClient.swift — les trois seuls appels sortants de la licence (L1C).
// Propriété : A-Core.
//
// TROIS APPELS, TOUS À LA DEMANDE (docs/privacy.md) :
//
//   activate   — la personne colle sa clé et clique « Activer ».
//   validate   — au lancement de l'application, ou par `fouine license
//                status`, si la licence n'a pas été vérifiée depuis 30 jours.
//                C'est le seul appel que la personne ne déclenche pas d'un
//                clic, et le seul qui soit silencieux : hors ligne, il ne se
//                passe rien, on réessaie la fois suivante. Ce qu'il change au
//                fichier est décidé par `LicenseCheck` (LC2).
//   deactivate — « Désactiver ce Mac », ou la désinstallation.
//
// CE QUI PART, EXHAUSTIVEMENT : la clé, et — pour `activate` — le nom de
// l'ordinateur (« MacBook Air de Claire »). Rien d'autre. Le nom de la machine
// n'est pas un identifiant que nous fabriquons : c'est ce que la personne verra
// dans son portail Creem pour savoir QUEL Mac libérer quand elle en changera.
// Sans lui, elle lirait trois lignes identiques.
//
// L'API DE CREEM N'EST PAS APPELÉE DIRECTEMENT, et ne peut pas l'être : ses
// points de licence exigent la clé API secrète du marchand. Un binaire
// distribué qui la porterait la donnerait à tout le monde. Le relais la porte,
// à un seul endroit, sur un serveur.
//
// SESSION ÉPHÉMÈRE, comme `ModelDownload` : ni cookie ni cache écrits sur le
// disque, un seul en-tête envoyé, un délai de garde de 15 s.

import Foundation

/// L'instance — un Mac, du point de vue de Creem.
public struct LicenseInstance: Equatable, Sendable {
    public let id: String
    public let name: String?
    public let status: String?

    public init(id: String, name: String? = nil, status: String? = nil) {
        self.id = id
        self.name = name
        self.status = status
    }
}

/// Ce que le relais rend, réduit à ce dont Fouine se sert.
public struct LicenseResponse: Equatable, Sendable {
    public let status: String
    public let key: String?
    public let activation: Int?
    public let activationLimit: Int?
    public let instance: LicenseInstance?

    public init(status: String, key: String? = nil, activation: Int? = nil,
                activationLimit: Int? = nil, instance: LicenseInstance? = nil) {
        self.status = status
        self.key = key
        self.activation = activation
        self.activationLimit = activationLimit
        self.instance = instance
    }

    /// Le statut de la CLÉ : Creem rend `active`, `inactive`, `expired` ou
    /// `disabled`. Il ne dit rien de CE Mac.
    public var isActive: Bool { status == "active" }

    /// La clé est active ET l'instance est là, active elle aussi — seul ce
    /// couple vaut « cette clé sert sur ce Mac ».
    ///
    /// MESURÉ LE 14/09/2026 dans le bac à sable : la validation d'un Mac libéré
    /// depuis le portail rend **200**, `"status": "active"` (la clé sert encore
    /// sur les autres Mac) et `"instance": { "status": "deactivated" }`. Ne lire
    /// que la clé laissait ce Mac sous licence pour toujours, et la limite de
    /// trois Mac ne protégeait plus rien.
    public var instanceIsActive: Bool {
        isActive && instance?.status == "active"
    }
}

/// Ce qui peut mal se passer, du point de vue de quelqu'un qui vient de payer.
///
/// Six cas, pas dix : chacun correspond à une phrase et à un geste différents.
/// Le détail brut de Creem voyage dans `keyRefused` pour le JOURNAL, et pour
/// choisir la phrase — il n'est pas documenté, il peut changer, et il est en
/// anglais technique : on ne le montre jamais tel quel.
public enum LicenseClientError: Error, Equatable, Sendable {
    /// Pas de réseau du tout (avion, Wi-Fi coupé, DNS muet).
    case offline
    /// 404 de Creem À L'ACTIVATION : cette clé n'existe pas. Presque toujours
    /// une coquille.
    case unknownKey
    /// 404 de Creem à la VÉRIFICATION ou à la DÉSACTIVATION : la clé a été
    /// acceptée un jour, c'est l'instance — ce Mac — que Creem ne connaît plus
    /// (libérée puis supprimée côté vendeur, ou identifiant abîmé). Mesuré le
    /// 14/09/2026 : `404`, `"message": ["License key instance not found"]`.
    case instanceNotFound
    /// 4xx autre que 404 : limite d'activation atteinte, clé désactivée,
    /// expirée, instance déjà libérée. Creem ne documente pas le texte ; on le
    /// garde tel quel.
    case keyRefused(detail: String)
    /// 5xx, ou le relais lui-même en panne.
    case serviceUnavailable
    /// Une réponse 200 dont le corps n'est pas ce qu'on attend.
    case malformed

    /// Le refus est-il la limite d'activation ? Creem répond **400**,
    /// `"message": "Activation limit reached"` (mesuré le 14/09/2026) : c'est
    /// le seul refus qui ait un geste à lui — libérer un autre Mac.
    public var isActivationLimit: Bool {
        guard case .keyRefused(let detail) = self else { return false }
        return detail.lowercased().contains("activation limit")
    }

    /// Ce Mac était-il DÉJÀ libéré ? Une désactivation qui l'apprend n'a plus
    /// rien à libérer, et doit nettoyer ce Mac au lieu d'échouer.
    ///
    /// Deux formes mesurées le 14/09/2026 : le 404 d'une instance inconnue, et
    /// le 400 `"License key instnace is already deactivated"` — la faute est
    /// de Creem. On cherche `deactivated` seul : le jour où Creem corrigera
    /// « instnace », la phrase continuera d'être reconnue.
    public var meansAlreadyReleased: Bool {
        switch self {
        case .instanceNotFound:
            return true
        case .keyRefused(let detail):
            return detail.lowercased().contains("deactivated")
        default:
            return false
        }
    }
}

public struct LicenseClient: Sendable {

    private let session: URLSession
    private let endpoint: URL
    private let userAgent: String

    /// - Parameter session: injectable pour les tests, qui y posent un
    ///   `URLProtocol` de substitution. En production, la session éphémère
    ///   ci-dessous : rien n'est écrit sur le disque.
    /// - Parameter version: la version de Fouine, pour l'en-tête `User-Agent`.
    ///   Passée et non lue ici : cette cible ne dépend que de Foundation, elle
    ///   ne connaît pas `FouineVersion`.
    public init(session: URLSession? = nil,
                endpoint: URL = LicenseTerms.relayURL,
                version: String = "1.0.0") {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = LicenseTerms.requestTimeout
            configuration.timeoutIntervalForResource = LicenseTerms.requestTimeout
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.httpCookieAcceptPolicy = .never
            configuration.httpShouldSetCookies = false
            self.session = URLSession(configuration: configuration)
        }
        self.endpoint = endpoint
        self.userAgent = "Fouine/\(version)"
    }

    /// Le nom de cet ordinateur, tel que la personne le lira dans son portail
    /// Creem. Repli « Mac » : `localizedName` est optionnel, et une instance
    /// sans nom serait pire qu'un nom générique.
    public static func thisMacName() -> String {
        let name = Host.current().localizedName ?? ""
        return name.isEmpty ? "Mac" : name
    }

    // MARK: - Les trois appels

    public func activate(key: String,
                         instanceName: String = thisMacName()) async throws -> LicenseResponse {
        try await send(["action": "activate", "key": key,
                        "instance_name": instanceName],
                       notFound: .unknownKey)
    }

    public func validate(key: String, instanceID: String) async throws -> LicenseResponse {
        try await send(["action": "validate", "key": key,
                        "instance_id": instanceID],
                       notFound: .instanceNotFound)
    }

    public func deactivate(key: String, instanceID: String) async throws -> LicenseResponse {
        try await send(["action": "deactivate", "key": key,
                        "instance_id": instanceID],
                       notFound: .instanceNotFound)
    }

    // MARK: - L'aller-retour

    /// - Parameter notFound: ce que vaut un 404 JSON pour CET appel. À
    ///   l'activation, la clé est inconnue ; ensuite, elle a été acceptée un
    ///   jour, et c'est l'instance qui manque. Les confondre disait « clé non
    ///   reconnue » à un Mac libéré, et la revalidation, qui n'y voyait qu'une
    ///   panne, réessayait à chaque lancement pour toujours.
    private func send(_ body: [String: String],
                      notFound: LicenseClientError) async throws -> LicenseResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = LicenseTerms.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // Toute panne de transport est « hors ligne » pour la personne :
            // distinguer un DNS muet d'un TLS refusé ne changerait pas son
            // geste, qui est de se connecter et de réessayer.
            throw LicenseClientError.offline
        }

        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200...299:
            guard let parsed = Self.parse(data) else {
                throw LicenseClientError.malformed
            }
            return parsed
        case 404:
            // UN 404 QUI N'EST PAS DU JSON N'EST PAS UNE CLÉ INCONNUE.
            //
            // Mesuré le 13/09/2026, relais pas encore déployé :
            // `https://basedpolymer.eu/api/fouine/license` rend le 404 HTML de
            // l'hébergeur pour une route absente — indiscernable, par le code
            // seul, du « License not found » de Creem. Fouine annonçait donc
            // « cette clé n'est pas reconnue » à quelqu'un qui venait de payer,
            // pour une panne qui n'était pas la sienne. Le corps tranche : le
            // relais et Creem répondent tous deux un objet JSON, jamais une
            // page.
            guard (try? JSONSerialization.jsonObject(with: data))
                    as? [String: Any] != nil else {
                throw LicenseClientError.serviceUnavailable
            }
            throw notFound
        case 400...499:
            // La limite d'activation atteinte arrive ICI (400), comme la
            // désactivation d'une instance déjà libérée, et leur texte n'est
            // pas documenté par Creem : on ne le montre pas, on le journalise,
            // et l'appelant écrit la phrase publique d'après lui.
            throw LicenseClientError.keyRefused(detail: Self.detail(data, code: code))
        default:
            throw LicenseClientError.serviceUnavailable
        }
    }

    // MARK: - Lecture de la réponse

    /// `nil` quand le corps n'a pas la forme attendue. `status` est le seul
    /// champ EXIGÉ : c'est lui qui décide, tout le reste est de l'affichage.
    static func parse(_ data: Data) -> LicenseResponse? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let status = root["status"] as? String else { return nil }
        var instance: LicenseInstance?
        if let raw = root["instance"] as? [String: Any],
           let id = raw["id"] as? String, !id.isEmpty {
            instance = LicenseInstance(id: id,
                                       name: raw["name"] as? String,
                                       status: raw["status"] as? String)
        }
        return LicenseResponse(status: status,
                               key: root["key"] as? String,
                               activation: root["activation"] as? Int,
                               activationLimit: root["activation_limit"] as? Int,
                               instance: instance)
    }

    /// Le texte brut d'une erreur. Le relais rend `{ "error": "…" }` ; Creem
    /// rend `message`, tantôt chaîne, tantôt tableau — et AUSSI `error`.
    ///
    /// `message` D'ABORD. Mesuré le 14/09/2026, la limite d'activation :
    /// `{"status":400,"error":"Bad Request","message":"Activation limit reached"}`.
    /// Lire `error` en premier rendait « Bad Request », et la phrase de la
    /// limite ne pouvait plus se reconnaître.
    static func detail(_ data: Data, code: Int) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else { return "HTTP \(code)" }
        if let message = root["message"] as? String, !message.isEmpty { return message }
        if let messages = root["message"] as? [Any] {
            let joined = messages.map { String(describing: $0) }.joined(separator: "; ")
            if !joined.isEmpty { return joined }
        }
        if let error = root["error"] as? String, !error.isEmpty { return error }
        return "HTTP \(code)"
    }
}
