// main.swift — point d'entrée de la CLI `fouine` (SPEC §4.3). Propriété : A-Core.
//
// UNE LIGNE DE PLUS SUR LE REFUS D'ARGUMENTPARSER (lot MN1). `fouine search
// -type:pdf réacteur` sort en 64 sur « Unknown option '-type:pdf' » : la
// requête commence par un tiret, et la bibliothèque la lit comme une option
// avant que Fouine n'ait vu la chaîne. Le message est juste et ne dit pas le
// geste ; on ajoute donc la forme qui marche, après lui.
//
// C'est pourquoi ce fichier ne peut pas rester `FouineCLI.main()` :
// `exit(withError:)` écrit le message ET sort, donc rien ne peut s'écrire
// après. On refait ici les trois lignes de `ParsableCommand.main()` — analyse,
// exécution, sortie — en n'ajoutant qu'une phrase, et seulement au cas décrit
// par `DashedQueryHint`. Tout le reste sort exactement comme avant, message et
// code compris (`ExitCode` n'imprime rien, cf. `MessageInfo.other`).

import ArgumentParser
import Foundation

do {
    var command = try FouineCLI.parseAsRoot()
    try command.run()
} catch {
    if FouineCLI.exitCode(for: error) == ExitCode.validationFailure,
       let hint = DashedQueryHint.line(arguments: CommandLine.arguments) {
        CLI.fail(FouineCLI.fullMessage(for: error))
        CLI.fail(hint)
        FouineCLI.exit(withError: ExitCode.validationFailure)
    }
    FouineCLI.exit(withError: error)
}
