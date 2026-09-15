// main.swift — point d'entrée de Fouine.app (SPEC §5.6). Propriété : A-App.
//
// Pourquoi du code de haut niveau plutôt que `@main` : l'exécutable doit pouvoir
// être lancé SANS interface (`FOUINE_SELFTEST=1`) pour vérifier en tête-à-tête
// avec la base réelle la recherche, les facettes, la résolution d'aperçu et la
// projection des boîtes OCR — un agent d'exécution n'a pas toujours de serveur de
// fenêtres. `App.main()` est appelé explicitement dans le cas normal.

import Foundation

if SelfTest.isRequested {
    SelfTest.run()
    exit(0)
}

FouineDesktopApp.main()
