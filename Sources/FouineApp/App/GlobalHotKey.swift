// GlobalHotKey.swift — raccourci global ⌥⌘F (SPEC §5.6). Propriété : A-App.
//
// Voie choisie : Carbon `RegisterEventHotKey`. Contrairement à
// `NSEvent.addGlobalMonitorForEvents` (qui exige l'autorisation « Surveillance
// de l'entrée » et ne peut pas CONSOMMER l'événement), un hot key Carbon
// fonctionne sans bundle, sans signature et sans autorisation TCC — y compris
// depuis `swift run FouineApp`. L'API est ancienne mais non dépréciée pour cet
// usage précis, et c'est celle qu'emploient les utilitaires du même genre.

import AppKit
import Carbon.HIToolbox

enum GlobalHotKey {

    private static var hotKeyRef: EventHotKeyRef?
    private static var handlerRef: EventHandlerRef?
    private static var action: (@MainActor () -> Void)?

    /// Enregistre ⌥⌘F au niveau système. Renvoie `false` si le système refuse
    /// (combinaison déjà prise par une autre app, environnement sans serveur de
    /// fenêtres) : l'appelant l'affiche, le raccourci LOCAL ⌥⌘F des Commands
    /// SwiftUI reste, lui, toujours disponible.
    @discardableResult
    static func registerOptionCommandF(_ perform: @escaping @MainActor () -> Void) -> Bool {
        guard hotKeyRef == nil else { return true }
        action = perform

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        // Fermeture SANS capture : convertible en pointeur de fonction C.
        let callback: EventHandlerUPP = { _, _, _ in
            DispatchQueue.main.async {
                if let action = GlobalHotKey.action {
                    MainActor.assumeIsolated { action() }
                }
            }
            return noErr
        }
        guard InstallEventHandler(GetApplicationEventTarget(), callback, 1,
                                  &eventType, nil, &handlerRef) == noErr else {
            // `InstallEventHandler` peut avoir écrit une valeur dans `handlerRef`
            // avant d'échouer : on ne garde rien.
            handlerRef = nil
            action = nil
            return false
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x464F_5549), id: 1) // 'FOUI'
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_F),
                                         UInt32(cmdKey | optionKey),
                                         hotKeyID,
                                         GetApplicationEventTarget(),
                                         0, &hotKeyRef)
        guard status == noErr else {
            // Échec PARTIEL : le gestionnaire d'événements est, lui, bien
            // installé. Le laisser en place fuyait (audit A10.10) et, comme
            // `hotKeyRef` repassait à `nil`, le garde-fou d'entrée ne protégeait
            // plus : un second appel réinstallait un gestionnaire de plus.
            unregister()
            return false
        }
        return true
    }

    static func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        hotKeyRef = nil
        if let handler = handlerRef { RemoveEventHandler(handler) }
        handlerRef = nil
        action = nil
    }
}
