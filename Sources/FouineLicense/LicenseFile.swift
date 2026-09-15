// LicenseFile.swift — le seul fichier que Fouine tient sur l'achat (lot L1C).
// Propriété : A-Core.
//
//     ~/Library/Application Support/Fouine/license.json
//
// Il porte SEPT champs et pas un de plus : la date de début d'essai, la clé,
// l'instance rendue par Creem, deux horodatages et la limite d'activation lue
// dans la réponse. Rien sur la machine, rien sur les documents, rien qui
// ressemble à un identifiant fabriqué par nous.
//
// OÙ IL VIT, ET POURQUOI IL SUIT LA BASE. Le chemin se dérive du fichier
// `.db` — même règle que `FouinePaths.sourcesDirectory`, et pour la même raison
// de sûreté : `FOUINE_DB` désigne une copie jetable dans les tests et la
// recette, et le fichier de licence suit alors la copie. Il n'existe donc aucun
// chemin de code capable d'écrire dans le dossier RÉEL de quelqu'un depuis un
// test. En usage normal, `FOUINE_DB` n'est pas posée et le fichier est bien à
// côté de `fouine.db`.
//
// LECTURE TOLÉRANTE, ÉCRITURE ATOMIQUE. Un fichier illisible — tronqué par une
// panne de courant, édité à la main, écrit par une version future — ne fait
// planter personne : il vaut « pas de licence », une ligne de journal, et
// l'essai repart. L'écriture passe par un fichier temporaire puis un
// `replaceItem` : un `write(to:)` direct interrompu laisserait un JSON à moitié
// écrit, c'est-à-dire exactement le fichier illisible qu'on vient de décrire —
// mais après un achat.

import Foundation
import os

/// Ce que le fichier contient. Les clés JSON sont en `snake_case` : ce fichier
/// se lit à l'œil nu, et c'est voulu — la personne qui a payé doit pouvoir
/// vérifier ce que Fouine garde sur elle.
public struct LicenseFile: Codable, Equatable, Sendable {

    /// L'état vu la dernière fois qu'on a parlé au relais.
    ///
    /// Un fichier SANS `state` (écrit avant L1C, ou à la main) se lit comme
    /// avant : la clé décide. `released` s'ajoute sans rien changer aux deux
    /// premiers (LC2).
    public enum State: String, Codable, Sendable {
        case active
        case revoked
        /// Ce Mac a été libéré ailleurs — depuis le portail client, le plus
        /// souvent. La clé n'est plus dans le fichier : il ne reste que l'essai
        /// et ce mot, qui permet de dire à la personne CE qui s'est passé au
        /// lieu de lui annoncer un essai terminé sorti de nulle part.
        case released
    }

    /// Premier lancement de l'application OU premier `fouine crawl` — le
    /// premier des deux. Un fonds déjà indexé commence donc son essai le jour
    /// où cette version arrive, pas rétroactivement.
    public var trialStarted: Date
    public var key: String?
    public var instanceID: String?
    public var instanceName: String?
    public var activatedAt: Date?
    public var lastChecked: Date?
    public var activationLimit: Int?
    public var state: State?

    public init(trialStarted: Date,
                key: String? = nil,
                instanceID: String? = nil,
                instanceName: String? = nil,
                activatedAt: Date? = nil,
                lastChecked: Date? = nil,
                activationLimit: Int? = nil,
                state: State? = nil) {
        self.trialStarted = trialStarted
        self.key = key
        self.instanceID = instanceID
        self.instanceName = instanceName
        self.activatedAt = activatedAt
        self.lastChecked = lastChecked
        self.activationLimit = activationLimit
        self.state = state
    }

    enum CodingKeys: String, CodingKey {
        case trialStarted = "trial_started"
        case key
        case instanceID = "instance_id"
        case instanceName = "instance_name"
        case activatedAt = "activated_at"
        case lastChecked = "last_checked"
        case activationLimit = "activation_limit"
        case state
    }

    /// Y a-t-il une clé activée ? Une clé sans instance n'en est pas une : le
    /// couple est indissociable, c'est lui qui permet de vérifier et de
    /// désactiver ce Mac.
    public var hasKey: Bool {
        guard let key, !key.isEmpty else { return false }
        return !(instanceID ?? "").isEmpty
    }

    /// Le fichier tel qu'il redevient après « Désactiver ce Mac » : l'essai
    /// gardé (sa date ne se rejoue pas), tout le reste effacé.
    public func withoutKey() -> LicenseFile {
        LicenseFile(trialStarted: trialStarted)
    }

    /// Le fichier tel qu'il redevient quand la vérification apprend que ce Mac
    /// a été libéré ailleurs (LC2) : la clé oubliée comme après « Désactiver ce
    /// Mac », plus le mot `released`.
    ///
    /// Oubliée, et non gardée à côté d'un état : une clé que Creem ne compte
    /// plus sur ce Mac ne sert à rien ici, et la garder ferait croire au
    /// fichier — lu à l'œil — qu'elle y est encore activée.
    public func released() -> LicenseFile {
        var file = withoutKey()
        file.state = .released
        return file
    }
}

/// Lecture, écriture et emplacement du fichier de licence.
public enum LicenseStore {

    private static let log = Logger(
        subsystem: "io.github.basedpolymer.fouine", category: "licence")

    public static let fileName = "license.json"

    /// Le fichier, à côté de la base. `databaseURL` est ce que les trois
    /// exécutables résolvent déjà chacun de leur côté (`FouinePaths`,
    /// `AppPaths`, `CLI`, `AgentPaths`) : on ne rajoute pas une quatrième
    /// résolution, on dérive de la leur.
    public static func fileURL(databaseURL: URL) -> URL {
        databaseURL.deletingLastPathComponent()
            .appendingPathComponent(fileName)
    }

    // MARK: - Lecture

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }

    /// Le fichier, ou `nil` s'il n'existe pas / ne se lit pas.
    ///
    /// Les deux cas se distinguent dans le JOURNAL et nulle part ailleurs :
    /// pour tout le reste du produit, un fichier corrompu est un fichier
    /// absent. Le contraire — refuser d'indexer parce qu'un octet est de
    /// travers — punirait la personne qui a payé.
    public static func load(at url: URL) -> LicenseFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try decoder.decode(LicenseFile.self, from: data)
        } catch {
            log.error("licence file unreadable, treated as absent: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Écriture

    /// Écriture ATOMIQUE : temporaire dans le même dossier, puis remplacement.
    /// Le même volume est indispensable — `replaceItemAt` retombe sinon sur une
    /// copie, qui n'est plus atomique.
    public static func save(_ file: LicenseFile, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(file)
        let temporary = directory.appendingPathComponent(
            ".\(fileName).\(UUID().uuidString)")
        try data.write(to: temporary, options: .atomic)
        // 0o600 : ce fichier porte une clé achetée. Les autres comptes de la
        // machine n'ont rien à y lire.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }

    /// Le fichier après s'être assuré que l'essai a une date de départ.
    ///
    /// Appelée au premier lancement de l'application ET par la garde d'essai de
    /// la CLI : le premier des deux pose la date, le second la lit. Une
    /// écriture qui échoue (disque plein, dossier en lecture seule) ne fait
    /// rien échouer — on rend l'objet en mémoire, l'essai repartira au prochain
    /// coup, et c'est le sens le plus favorable à l'utilisateur.
    @discardableResult
    public static func ensureTrialStarted(at url: URL,
                                          now: Date = Date()) -> LicenseFile {
        if let existing = load(at: url) { return existing }
        let fresh = LicenseFile(trialStarted: now)
        do {
            try save(fresh, to: url)
        } catch {
            log.error("could not start the trial: \(error.localizedDescription, privacy: .public)")
        }
        return fresh
    }

    /// Supprime le fichier (désinstallation, désactivation ratée). Silencieuse :
    /// il n'y a rien à faire d'un échec, et rien à en dire à qui désinstalle.
    public static func remove(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
