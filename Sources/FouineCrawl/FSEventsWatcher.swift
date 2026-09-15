// FSEventsWatcher.swift — surveillance des racines (SPEC §5.2).
// Propriété : A-Ingest. Consommateur : l'agent d'arrière-plan (vague 3, §5.7).
//
// « FSEventStreamCreate sur chaque racine,
//   kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer,
//   latence 3 s. Persister lastEventId dans volumes.fsevent_id à chaque lot
//   traité. Au redémarrage, rejouer depuis cet identifiant ; si l'historique a
//   été purgé (kFSEventStreamEventFlagHistoryDone sans événements, ou
//   identifiant invalide), basculer sur un crawl delta complet. »
//
// AMENDEMENT du 04/09/2026 (lot K6, constat A3-03). « HistoryDone sans
// événements » N'EST PAS le signe d'un historique purgé : c'est le démarrage
// ORDINAIRE d'un agent quand rien n'a bougé depuis la dernière fois — plusieurs
// fois par jour. Mesuré ici (`testAQuietRestartOnAValidCursorAsksForNothing`) :
// avec un curseur valide et un disque au repos, FSEvents livre `HistoryDone`
// seul, et Fouine relançait alors un crawl delta COMPLET de toutes les racines.
// Une vraie perte d'historique, elle, est signalée par des DRAPEAUX —
// MustScanSubDirs, UserDropped, KernelDropped, EventIdsWrapped — que
// `requiresFullDelta(flags:)` traite déjà, et un identifiant invalide est
// intercepté dès `start()`. La distinction est donc bien observable, et le
// repli aveugle disparaît.
//
// « FSEvents sur ~/Documents est soumis au même TCC que la lecture : un flux qui
//   ne renvoie jamais rien est un symptôme d'autorisation, pas d'inactivité »
//   (§7.1) — d'où `probeReadable` AVANT d'ouvrir un flux, côté appelant.
//
// Ici : pas de démon, pas de boucle d'attente. Une API démarrable, arrêtable et
// testable ; `deliver` est le point d'entrée pur que les tests exercent sans
// dépendre du système de fichiers.

import Foundation
import CoreServices
import FouineCore

public final class FSEventsWatcher: @unchecked Sendable {
    /// Une salve : les chemins touchés, le curseur à persister, et le drapeau qui
    /// dit à l'appelant qu'un crawl delta complet est nécessaire.
    public struct Batch: Sendable {
        public let paths: [String]
        public let lastEventID: UInt64
        public let requiresFullDelta: Bool
        public init(paths: [String], lastEventID: UInt64, requiresFullDelta: Bool) {
            self.paths = paths
            self.lastEventID = lastEventID
            self.requiresFullDelta = requiresFullDelta
        }
    }

    public typealias Handler = @Sendable (Batch) -> Void

    /// Latence imposée par le §5.2.
    public static let defaultLatency: CFTimeInterval = 3.0

    public let roots: [URL]
    public let volUUID: String
    public let latency: CFTimeInterval

    private let store: any IndexStore
    private let handler: Handler
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Void>()
    private let lock = NSLock()

    private var stream: FSEventStreamRef?
    private var lastEventID: UInt64 = 0
    /// Dernière erreur de persistance du curseur, pour le diagnostic. Écrite
    /// depuis la file FSEvents, lue depuis n'importe quel fil : elle passe donc
    /// par `lock`, comme tous les autres champs mutables de cette classe.
    private var storedLastError: Error?
    public var lastError: Error? {
        lock.lock(); defer { lock.unlock() }
        return storedLastError
    }

    public init(roots: [URL], volUUID: String, store: any IndexStore,
                latency: CFTimeInterval = FSEventsWatcher.defaultLatency,
                queue: DispatchQueue = DispatchQueue(label: "fouine.fsevents",
                                                     qos: .utility),
                onBatch: @escaping Handler) {
        self.roots = roots
        self.volUUID = volUUID
        self.store = store
        self.latency = latency
        self.queue = queue
        self.handler = onBatch
        queue.setSpecific(key: queueKey, value: ())
    }

    // Le flux FSEvents retient l'instance tant qu'il tourne grâce aux callbacks
    // retain/release de FSEventStreamContext. deinit n'est donc atteint qu'après
    // stop() ou si le flux n'a jamais démarré. Ne pas appeler stop() ici (C2-10).

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return stream != nil
    }

    /// Curseur courant (volumes.fsevent_id).
    public var currentEventID: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return lastEventID
    }

    // MARK: - Cycle de vie

    public func start() throws {
        guard !roots.isEmpty else {
            throw FouineError.rootUnreadable(
                path: "",
                reason: RootProbe.Reason.system("no root to watch").token)
        }
        lock.lock()
        guard stream == nil else { lock.unlock(); return }
        lock.unlock()

        let stored = (try? store.fseventID(volUUID: volUUID)) ?? 0
        // Échantillonné AVANT FSEventStreamCreate : le flux ne rendra que des
        // identifiants POSTÉRIEURS, donc ce curseur sur-couvre — quelques
        // événements rejoués pour rien — au lieu de sous-couvrir, ce qui perdrait
        // des modifications.
        let current = UInt64(FSEventsGetCurrentEventId())
        let startupCursor = Self.startupCursor(stored: stored, current: current)

        var sinceWhen = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        var mustRescan = false
        if stored > 0 {
            if stored <= current {
                sinceWhen = FSEventStreamEventId(stored)
                lock.lock(); lastEventID = stored; lock.unlock()
            } else {
                // Identifiant invalide (historique purgé, base plus récente que le
                // système) : crawl delta complet.
                mustRescan = true
            }
        }

        let client = Unmanaged.passRetained(self)
        defer { client.release() }
        var context = FSEventStreamContext(
            version: 0,
            info: client.toOpaque(),
            retain: { ptr in
                guard let ptr else { return nil }
                _ = Unmanaged<FSEventsWatcher>.fromOpaque(ptr).retain()
                return ptr
            },
            release: { ptr in
                guard let ptr else { return }
                Unmanaged<FSEventsWatcher>.fromOpaque(ptr).release()
            },
            copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents
                           | kFSEventStreamCreateFlagNoDefer
                           | kFSEventStreamCreateFlagUseCFTypes)
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault, fouineFSEventsCallback, &context,
            roots.map(\.path) as CFArray, sinceWhen, latency, flags)
        else {
            throw FouineError.rootUnreadable(
                path: roots[0].path,
                reason: RootProbe.Reason.system("FSEventStreamCreate failed").token)
        }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            throw FouineError.rootUnreadable(
                path: roots[0].path,
                reason: RootProbe.Reason.system(
                    "FSEventStreamStart failed (privacy permission?)").token)
        }
        lock.lock(); stream = created; lock.unlock()

        // Curseur de démarrage, persisté SEULEMENT APRÈS un FSEventStreamStart
        // réussi : un flux qui n'a pas démarré ne couvre rien. Sans cette écriture,
        // `volumes.fsevent_id` reste à 0 tant qu'aucune salve n'arrive, et chaque
        // redémarrage de l'agent repart en crawl delta complet de toutes les
        // racines (§5.2).
        if let cursor = startupCursor { persistCursor(cursor) }

        if mustRescan {
            let batch = Batch(paths: [], lastEventID: 0, requiresFullDelta: true)
            queue.async { [handler] in handler(batch) }
        }
    }

    public func stop() {
        lock.lock()
        let current = stream
        stream = nil
        lock.unlock()
        guard let current else { return }

        let performStop = {
            FSEventStreamStop(current)
            FSEventStreamInvalidate(current)
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            performStop()
        } else {
            queue.sync(execute: performStop)
        }
        FSEventStreamRelease(current)
    }

    // MARK: - Salve

    /// Traitement d'une salve. Public au module pour être testable sans démon.
    func deliver(paths: [String],
                 flags: [FSEventStreamEventFlags],
                 ids: [FSEventStreamEventId]) {
        var files: [String] = []
        var requiresFullDelta = false
        var maxID: UInt64 = 0

        for (index, path) in paths.enumerated() {
            let flag = index < flags.count ? flags[index] : 0
            if index < ids.count {
                let id = UInt64(ids[index])
                if id != UInt64(kFSEventStreamEventIdSinceNow), id > maxID { maxID = id }
            }
            // `HistoryDone` marque la FIN du rejeu, rien de plus (A3-03) : ce
            // n'est pas un chemin à traiter, et son absence d'événements n'est
            // pas un symptôme. Une perte d'historique porte un DRAPEAU, et
            // c'est `requiresFullDelta(flags:)` qui le lit.
            if Self.isHistoryDone(flag) { continue }
            if Self.requiresFullDelta(flags: flag) { requiresFullDelta = true }
            files.append(path)
        }

        lock.lock()
        if maxID > lastEventID { lastEventID = maxID }
        let cursor = lastEventID
        lock.unlock()

        // Persistance du curseur À CHAQUE LOT (§5.2).
        persistCursor(cursor)

        guard !files.isEmpty || requiresFullDelta else { return }
        handler(Batch(paths: files, lastEventID: cursor,
                      requiresFullDelta: requiresFullDelta))
    }

    /// Curseur à poser au démarrage, ou `nil` s'il ne faut RIEN écrire.
    /// En reprise (curseur enregistré valide), la base porte déjà un curseur plus
    /// ancien : l'écraser par un plus récent perdrait la fenêtre que le flux est
    /// justement en train de rejouer. Dans tous les autres cas — base neuve, ou
    /// identifiant invalide qui force un crawl delta complet — le flux part de
    /// « maintenant » et c'est « maintenant » qu'il faut mémoriser.
    static func startupCursor(stored: UInt64, current: UInt64) -> UInt64? {
        (stored > 0 && stored <= current) ? nil : current
    }

    /// Écrit le curseur dans `volumes.fsevent_id` et avance le curseur en mémoire.
    /// Appelée depuis `start()` comme depuis la file FSEvents : l'échec éventuel
    /// est publié sous `lock`, comme le reste de l'état mutable.
    private func persistCursor(_ cursor: UInt64) {
        guard cursor > 0 else { return }
        lock.lock()
        if cursor > lastEventID { lastEventID = cursor }
        lock.unlock()
        do {
            try store.setFSEventID(volUUID: volUUID, cursor)
        } catch {
            lock.lock(); storedLastError = error; lock.unlock()
        }
    }

    /// Drapeaux qui invalident le suivi incrémental : il faut re-parcourir.
    public static func requiresFullDelta(flags: FSEventStreamEventFlags) -> Bool {
        let rescan = UInt32(kFSEventStreamEventFlagMustScanSubDirs)
            | UInt32(kFSEventStreamEventFlagUserDropped)
            | UInt32(kFSEventStreamEventFlagKernelDropped)
            | UInt32(kFSEventStreamEventFlagEventIdsWrapped)
            | UInt32(kFSEventStreamEventFlagRootChanged)   // racine déplacée, §7.2 n°14
            | UInt32(kFSEventStreamEventFlagUnmount)
        return (flags & rescan) != 0
    }

    public static func isHistoryDone(_ flags: FSEventStreamEventFlags) -> Bool {
        (flags & UInt32(kFSEventStreamEventFlagHistoryDone)) != 0
    }
}

/// Trampoline C : FSEvents ne connaît pas les méthodes Swift.
private func fouineFSEventsCallback(stream: ConstFSEventStreamRef,
                                    clientInfo: UnsafeMutableRawPointer?,
                                    numEvents: Int,
                                    eventPaths: UnsafeMutableRawPointer,
                                    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
                                    eventIds: UnsafePointer<FSEventStreamEventId>) {
    guard let clientInfo else { return }
    let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(clientInfo)
        .takeUnretainedValue()
    guard watcher.isRunning else { return }
    // kFSEventStreamCreateFlagUseCFTypes : eventPaths est un CFArray de CFString.
    let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
    var flags: [FSEventStreamEventFlags] = []
    var ids: [FSEventStreamEventId] = []
    flags.reserveCapacity(numEvents)
    ids.reserveCapacity(numEvents)
    for index in 0..<numEvents {
        flags.append(eventFlags[index])
        ids.append(eventIds[index])
    }
    watcher.deliver(paths: paths, flags: flags, ids: ids)
}
