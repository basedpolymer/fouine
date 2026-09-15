// EmbedCampaignLock.swift — un seul processus vectorise à la fois (constat C2-11).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
// Propriété : A-Embed.
//
// CE QUE CE VERROU N'EST PAS. Ce n'est PAS le verrou d'écriture `fouine.lock`,
// et il ne le remplace pas. `EmbedRun` rend `fouine.lock` après chaque lot,
// délibérément (audits B1-06 et D2-04) : le garder vingt heures empêchait
// l'application d'ajouter un dossier ou de lancer l'OCR pendant une campagne.
// C'est une bonne décision, à ne pas défaire — et c'est justement pour cela que
// `fouine doctor` répond « write lock : free » au beau milieu d'une campagne,
// et que rien n'empêchait un SECOND `fouine embed` de partir.
//
// MESURÉ (C2-11) : deux campagnes lancées à sept minutes d'intervalle sur la
// même base ont tourné ensemble onze minutes, chacune inférant les mêmes pages,
// toutes deux en sortie 0. Aucune corruption — les lignes de `page_vec` sont
// clés par (document, page, fenêtre) — mais des heures de CPU pour rien, sur
// une machine qui chauffe déjà. La campagne du fonds réel dure ~30 h : un
// double départ (le bouton de l'app pendant qu'un terminal tourne, deux
// fenêtres oubliées) double la facture énergétique sans produire une page de
// plus.
//
// CE QU'IL EST. Un verrou CONSULTATIF de campagne : `fouine-embed.lock`, à côté
// de la base, pris en `flock(LOCK_EX | LOCK_NB)` pour toute la durée du
// processus. Il ne protège aucune écriture — c'est le travail de `fouine.lock`
// — il répond à une seule question : « une vectorisation tourne-t-elle déjà ? ».
// `fouine status` la pose aussi, ce qui répond au passage à « ma campagne
// tourne-t-elle encore ? ».
//
// Le noyau rend `flock()` à la mort du processus : une campagne tuée, plantée
// ou débranchée ne laisse donc jamais un verrou coincé. Le NOM qu'elle a
// inscrit, lui, survit — d'où la troncature dès qu'on constate que le verrou
// est libre (même règle que `WriteLock.inspect`).

import Foundation
import FouineCore

public final class EmbedCampaignLock: @unchecked Sendable {

    /// Qui vectorise, depuis quand.
    public struct Holder: Sendable, Equatable {
        public let pid: pid_t
        public let since: Date

        public init(pid: pid_t, since: Date) {
            self.pid = pid
            self.since = since
        }

        /// « 19:13 » — l'heure telle que la locale de la machine l'écrit.
        public var clockText: String { EmbedCampaignLock.clock.string(from: since) }

        /// La date ISO 8601, sans langue : c'est elle qui part dans `--json`.
        public var isoText: String { EmbedCampaignLock.iso.string(from: since) }

        /// Le processus nommé existe-t-il encore ? `kill(pid, 0)` ne tue rien ;
        /// seul `ESRCH` prouve l'absence (même règle que `LockHolder.isAlive`).
        public var isAlive: Bool {
            if kill(pid, 0) == 0 { return true }
            return errno != ESRCH
        }
    }

    /// Le refus : une campagne tourne déjà.
    public struct Busy: Error, Sendable, CustomStringConvertible {
        public let holder: Holder?
        public let path: String

        /// La phrase de la CLI (§4.3, anglais). Un détenteur qu'on ne sait pas
        /// nommer ne part JAMAIS dans le message : mieux vaut ne rien dire que
        /// d'accuser un processus au hasard.
        public var description: String {
            guard let holder else {
                return "a vectorisation campaign is already running "
                    + "(holder not named in \(path))"
            }
            return "a vectorisation campaign is already running "
                + "(pid \(holder.pid), since \(holder.clockText))"
        }
    }

    /// Le fichier de verrou n'a pas pu être ouvert (dossier en lecture seule,
    /// descripteurs épuisés). Ce n'est pas une raison d'empêcher une campagne :
    /// l'appelant en avertit et continue.
    public struct Unavailable: Error, Sendable, CustomStringConvertible {
        public let reason: String
        public var description: String {
            "cannot open the vectorisation lock: \(reason)"
        }
    }

    /// Voisin de la base, et il PORTE SON NOM comme le verrou d'écriture
    /// (BU-30) : `fouine.db` → `fouine-embed.lock`, `c2.db` → `c2-embed.lock`.
    /// Deux campagnes sur deux copies d'un même dossier se refusaient l'une
    /// l'autre.
    public static func url(for databaseURL: URL) -> URL {
        FouinePaths.embedLockURL(for: databaseURL)
    }

    private let path: String
    private let mutex = NSLock()
    private var fd: Int32

    private init(path: String, fd: Int32) {
        self.path = path
        self.fd = fd
    }

    deinit { release() }

    // MARK: - Prise et libération

    /// Prend le verrou pour la durée de vie de l'objet rendu.
    ///
    /// - Throws: `Busy` si une campagne tourne déjà, `Unavailable` si le
    ///   fichier ne peut pas être ouvert.
    @discardableResult
    public static func acquire(databaseURL: URL) throws -> EmbedCampaignLock {
        let path = url(for: databaseURL).path
        // 0600 comme `fouine.lock` : la ligne nomme un processus et une heure,
        // c'est un renseignement sur l'activité de l'utilisateur.
        let fd = Darwin.open(path, O_CREAT | O_RDWR, FilePermissions.file)
        guard fd >= 0 else {
            throw Unavailable(reason: String(cString: strerror(errno)))
        }
        _ = fchmod(fd, FilePermissions.file)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            let holder = readHolder(path: path)
            Darwin.close(fd)
            guard code == EWOULDBLOCK else {
                throw Unavailable(reason: String(cString: strerror(code)))
            }
            throw Busy(holder: holder, path: path)
        }
        let lock = EmbedCampaignLock(path: path, fd: fd)
        lock.stamp()
        return lock
    }

    /// Qui tient le verrou, ou `nil` s'il est libre. Ne bloque jamais, ne crée
    /// rien : `fouine status` s'en sert, et `status` est une lecture.
    public static func probe(databaseURL: URL) -> Holder? {
        let path = url(for: databaseURL).path
        let holder = readHolder(path: path)
        let fd = Darwin.open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            // Libre : le nom qu'on vient de lire est périmé. On tronque TANT
            // QU'ON TIENT le verrou, personne ne peut lire entre les deux.
            if holder != nil { _ = Darwin.truncate(path, 0) }
            _ = flock(fd, LOCK_UN)
            return nil
        }
        return holder
    }

    /// Rend le verrou. Idempotent ; appelé aussi par `deinit`.
    public func release() {
        mutex.lock()
        defer { mutex.unlock() }
        guard fd >= 0 else { return }
        _ = ftruncate(fd, 0)
        _ = flock(fd, LOCK_UN)
        Darwin.close(fd)
        fd = -1
    }

    // MARK: - Contenu du fichier

    /// « pid 54695 since 2026-09-09T19:13:44Z »
    static func line(pid: pid_t, since: Date) -> String {
        "pid \(pid) since \(iso.string(from: since))\n"
    }

    private func stamp() {
        let text = Self.line(pid: getpid(), since: Date())
        _ = ftruncate(fd, 0)
        _ = lseek(fd, 0, SEEK_SET)
        text.withCString { pointer in
            _ = Darwin.write(fd, pointer, strlen(pointer))
        }
    }

    /// Relit la ligne. `nil` si le fichier est vide, tronqué ou d'un format
    /// qu'on ne sait pas lire.
    static func parse(_ text: String) -> Holder? {
        let fields = text.split(separator: "\n").first?
            .split(separator: " ").map(String.init) ?? []
        guard fields.count >= 2, fields[0] == "pid",
              let pid = pid_t(fields[1]), pid > 0 else { return nil }
        var since = Date()
        if fields.count >= 4, fields[2] == "since",
           let parsed = iso.date(from: fields[3]) {
            since = parsed
        }
        return Holder(pid: pid, since: since)
    }

    static func readHolder(path: String) -> Holder? {
        guard let data = FileManager.default.contents(atPath: path),
              !data.isEmpty else { return nil }
        return parse(String(decoding: data, as: UTF8.self))
    }

    static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Comme `LockHolder.clock` (audit B1-23) : le gabarit `jm` laisse la locale
    /// choisir l'ordre et l'AM/PM, `dateFormat = "HH:mm"` faisait lire « 17:25 »
    /// à quelqu'un dont le système écrit « 5:25 PM ».
    static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("jm")
        return formatter
    }()
}
