// DeepLink.swift — le lien `fouine://` qui rouvre Fouine sur une page (INT-L1).
//
// POURQUOI CE TYPE VIT DANS LE CŒUR, ET PAS DANS L'APPLICATION. Le lien est
// ÉMIS par trois surfaces qui ne se connaissent pas — l'application (« copier
// la référence »), `fouine search --json` et le serveur MCP —, et n'est LU que
// par une seule, l'application. Trois écritures et une lecture d'une même
// grammaire : la mettre dans `FouineApp` obligerait la CLI et le serveur à la
// recopier, et deux copies d'une grammaire d'URL divergent toujours par un
// caractère d'échappement.
//
// DEUX FORMES, ET L'ORDRE DE PRÉFÉRENCE EST LE POINT :
//
//   fouine://open?path=/Users/…/cours.pdf&page=87&q=electrolyse   ← canonique
//   fouine://open?doc=1329&page=87                                ← repli
//   fouine://open?path=/Users/…/cours.m4a&page=2&t=760            ← un moment
//
// La forme par CHEMIN survit à tout : une réindexation, une base restaurée
// d'une sauvegarde, une machine changée. `docs.id` est un rowid SQLite — il
// est réattribué à un autre document dès qu'un `fouine index` complet repart
// d'une base neuve, et une citation collée dans un mémoire six mois plus tôt
// ouvrirait alors la mauvaise page, sans un mot. Le `doc` n'est donc émis que
// lorsqu'il n'y a rien d'autre à dire : volume démonté, chemin absolu
// inconnaissable. `link(absolutePath:docID:page:)` porte cet arbitrage à un
// seul endroit.
//
// L'ALLER-RETOUR EST LA SEULE CHOSE QUI COMPTE. Un chemin réel porte des
// espaces, des accents, et — sur ce corpus — des `&`, des `#`, des `+` et des
// `%`. Toute construction par concaténation casse sur l'un des cinq : `&`
// coupe le lien en deux paramètres, `#` en fait un fragment, `%` ouvre une
// séquence d'échappement invalide qui rend `URL(string:)` nul. D'où
// l'encodage explicite ci-dessous, et le test qui fait tourner les cinq.

import Foundation

/// Ce qu'un lien `fouine://` demande à l'application de faire.
public enum DeepLink: Equatable, Sendable {

    /// Le document désigné par le lien.
    public enum Target: Equatable, Sendable {
        /// Chemin ABSOLU du fichier, tel qu'il était au moment de la citation.
        case path(String)
        /// `docs.id`, forme de repli (voir l'en-tête).
        case doc(Int64)
    }

    /// Ouvrir un document, à une page s'il y en a une, en montrant `query` dans
    /// le champ de recherche quand elle est là.
    ///
    /// `time` est un nombre de SECONDES depuis le début d'un enregistrement
    /// (lot PV1) : une page de son ou de vidéo vaut dix minutes de parole, et
    /// citer « page 2 » d'un cours de deux heures ne renvoie personne nulle
    /// part. Il ne vaut que pour les médias, et vaut `nil` partout ailleurs.
    case open(target: Target, page: Int?, query: String?, time: Int?)
    /// Rejouer une recherche dans la fenêtre principale.
    case search(query: String)

    /// Le MÊME cas, sans moment.
    ///
    /// Un `time` ne concerne QUE les sons et les vidéos : les surfaces qui
    /// n'en émettent pas — Spotlight, l'export, la CLI — n'ont pas à écrire
    /// `time: nil` à chaque appel, et le jour où elles en émettront un, c'est
    /// ici que leur appel changera.
    public static func open(target: Target, page: Int?, query: String?) -> DeepLink {
        .open(target: target, page: page, query: query, time: nil)
    }

    /// Le schéma d'URL déclaré par `Packaging/Info.plist`.
    public static let scheme = "fouine"

    private enum Host: String {
        case open, search
    }

    // MARK: - Lecture

    /// `nil` pour tout ce qui n'est pas un lien Fouine VALIDE : un autre
    /// schéma, un hôte inconnu, `page` nulle ou négative, un `doc` qui n'est
    /// pas un entier, un `path` relatif, une recherche sans texte.
    ///
    /// Refuser plutôt que réparer : un lien à moitié compris ouvrirait une
    /// autre page que celle citée, ce qui est pire que de ne rien ouvrir.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host.flatMap({ Host(rawValue: $0.lowercased()) })
        else { return nil }

        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            // La PREMIÈRE occurrence gagne : `?page=1&page=2` est une URL
            // trafiquée, pas une intention.
            if values[item.name] == nil, let value = item.value { values[item.name] = value }
        }

        switch host {
        case .search:
            let text = (values["q"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            self = .search(query: text)

        case .open:
            let page: Int?
            if let raw = values["page"] {
                // Une page nulle ou négative n'existe pas : les pages sont
                // 1-indexées partout dans Fouine.
                guard let value = Int(raw), value >= 1 else { return nil }
                page = value
            } else {
                page = nil
            }
            let query = values["q"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty

            // UN MOMENT ILLISIBLE S'IGNORE, là où une page illisible refuse le
            // lien entier : une page fausse ouvrirait une AUTRE page que celle
            // citée, alors qu'un `t=` absurde ne coûte que la tête de lecture
            // — le passage reste celui du texte trouvé, et le lecteur a sa
            // barre de transport.
            let time = values["t"].flatMap(Int.init).flatMap { $0 >= 0 ? $0 : nil }

            // Le CHEMIN d'abord : c'est la forme canonique, et un lien qui
            // porte les deux a été écrit par une version qui savait le chemin.
            if let path = values["path"] {
                guard path.hasPrefix("/") else { return nil }
                self = .open(target: .path(path), page: page, query: query, time: time)
            } else if let raw = values["doc"] {
                guard let id = Int64(raw), id >= 1 else { return nil }
                self = .open(target: .doc(id), page: page, query: query, time: time)
            } else {
                return nil
            }
        }
    }

    // MARK: - Écriture

    /// L'URL de ce lien. Construite item par item, jamais par concaténation.
    public var url: URL {
        var items: [(String, String)] = []
        let host: Host
        switch self {
        case .open(let target, let page, let query, let time):
            host = .open
            switch target {
            case .path(let path): items.append(("path", path))
            case .doc(let id): items.append(("doc", String(id)))
            }
            if let page { items.append(("page", String(page))) }
            if let query, !query.isEmpty { items.append(("q", query)) }
            // APRÈS la requête : un lien se lit souvent à l'œil dans un
            // courriel, et le moment est ce qu'on vérifie en dernier.
            if let time, time >= 0 { items.append(("t", String(time))) }
        case .search(let query):
            host = .search
            items.append(("q", query))
        }

        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = host.rawValue
        components.percentEncodedQuery = items
            .map { "\($0.0)=\(Self.encode($0.1))" }
            .joined(separator: "&")
        // `URLComponents` ne rend `nil` que sur un hôte impossible ; les deux
        // hôtes sont des littéraux. Le repli reste écrit plutôt que forcé —
        // un `!` dans un chemin d'écriture de citation ne se justifie pas.
        return components.url ?? URL(string: "\(Self.scheme)://\(host.rawValue)")!
    }

    /// L'encodage d'une VALEUR de paramètre.
    ///
    /// `urlQueryAllowed` laisse passer `&`, `=`, `+`, `#`, `?` et `/` : les
    /// quatre premiers cassent la relecture d'un chemin réel (voir l'en-tête).
    /// On les retire, et on retire aussi `%` — sans quoi un chemin qui en porte
    /// un déjà (« 100%.pdf ») produirait une séquence d'échappement invalide.
    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: Self.valueAllowed) ?? value
    }

    private static let valueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+#?%")
        return set
    }()

    // MARK: - Fabriques

    /// Le lien d'une page désignée par son chemin absolu. `page` nulle = le
    /// document, sans page.
    public static func page(absolutePath: String, page: Int?,
                            query: String? = nil, time: Int? = nil) -> URL {
        DeepLink.open(target: .path(absolutePath), page: page, query: query,
                      time: time).url
    }

    /// Le lien d'une page désignée par son document. Forme de REPLI : à
    /// n'émettre que faute de chemin absolu (voir l'en-tête).
    public static func page(docID: Int64, page: Int?, query: String? = nil,
                            time: Int? = nil) -> URL {
        DeepLink.open(target: .doc(docID), page: page, query: query, time: time).url
    }

    /// LE POINT UNIQUE de l'arbitrage entre les deux formes : le chemin quand
    /// on le connaît, le document sinon. Toute surface qui émet un lien passe
    /// par ici — sans quoi l'une d'elles émettrait des `doc` là où les autres
    /// émettent des `path`, et deux citations de la même page ne se
    /// ressembleraient pas.
    public static func link(absolutePath: String?, docID: Int64,
                            page: Int?, query: String? = nil,
                            time: Int? = nil) -> URL {
        if let absolutePath, absolutePath.hasPrefix("/") {
            return DeepLink.page(absolutePath: absolutePath, page: page,
                                 query: query, time: time)
        }
        return DeepLink.page(docID: docID, page: page, query: query, time: time)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
