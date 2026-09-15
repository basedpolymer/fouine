# frozen_string_literal: true

# La ligne ci-dessus est posée par `brew style` : hors d'un tap, Homebrew
# applique les règles Ruby génériques, dont `Style/FrozenStringLiteralComment`.
# Elle est sans effet sur un cask (le DSL ne mute aucun littéral). Le contrôle
# qui compte vraiment est `brew audit --cask --online fouine`, DANS le tap :
# hors tap, `brew style` réclame en plus un sigil Sorbet qu'aucun cask ne porte.
#
# fouine.rb — cask Homebrew (audit D13). Propriété : A-App, palier 3.4.
#
# CE FICHIER EST UN MODÈLE, ET AUSSI LE CASK RÉEL. `Packaging/cask.sh` le relit,
# y remplace `version` et `sha256` par ceux de la release qu'on publie, et sort
# le résultat sur la sortie standard — c'est ce qu'on dépose dans le tap
# (`Casks/fouine.rb`). Les deux lignes en question sont les SEULES à changer
# d'une version à l'autre ; tout le reste est stable, et se relit ici.
#
# `sha256` est celui du DMG, tel que `dist/SHA256SUMS` le publie (RELEASING.md
# étape 4). La valeur ci-dessous est un gabarit — 64 zéros — et non une vraie
# empreinte : un cask déposé sans passer par `cask.sh` refusera d'installer, ce
# qui est très exactement ce qu'on veut d'une empreinte oubliée.
#
# `binary` pointe dans le bundle, PAS vers une copie : `Contents/Helpers/fouine`
# est la CLI signée avec l'application (SPEC §11.2), et un lien vers elle donne
# `fouine` dans le PATH sans passer par le menu « Installer l'outil en ligne de
# commande… ». Une copie divergerait à la première mise à jour et lirait la base
# avec un schéma périmé.
#
# `uninstall launchctl:` est INDISPENSABLE : l'agent d'arrière-plan est
# enregistré auprès de launchd par `SMAppService` (§5.7). Sans cette ligne,
# `brew uninstall` laisserait derrière lui un agent qui pointe vers une
# application effacée.
cask "fouine" do
  version "1.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/basedpolymer/fouine/releases/download/v#{version}/Fouine-#{version}.dmg"
  name "Fouine"
  desc "Full-text search for local documents, with non-destructive OCR"
  homepage "https://github.com/basedpolymer/fouine"

  livecheck do
    url :url
    strategy :github_latest
  end

  # Ventura (13) est la cible de déploiement du paquet (Package.swift).
  depends_on macos: ">= :ventura"

  app "Fouine.app"
  binary "#{appdir}/Fouine.app/Contents/Helpers/fouine"

  uninstall launchctl: "io.github.basedpolymer.fouine.agent",
            quit:      "io.github.basedpolymer.fouine"

  # `zap` n'est joué que sur `brew uninstall --zap` : il emporte l'index, qui a
  # pu coûter des heures d'OCR. Les dossiers INDEXÉS n'y sont évidemment pas —
  # Fouine n'y a jamais écrit.
  zap trash: [
    "~/Library/Application Support/Fouine",
    "~/Library/Caches/fouine",
    "~/Library/Caches/io.github.basedpolymer.fouine",
    "~/Library/HTTPStorages/io.github.basedpolymer.fouine",
    "~/Library/Logs/Fouine",
    "~/Library/Preferences/io.github.basedpolymer.fouine.plist",
    "~/Library/Saved Application State/io.github.basedpolymer.fouine.savedState",
  ]

  caveats <<~EOS
    Fouine only searches the folders you give it, and it reads them without
    ever modifying them.

    macOS will ask for permission the first time you add a folder under
    Documents, Desktop, Downloads, a removable volume or a network share.
    If you refuse, that folder indexes as if it were empty, with no error:
      System Settings > Privacy & Security > Files and Folders > Fouine

    Full Disk Access is asked for one thing only: reading Apple Notes, if you
    tick that box under Settings > Folders > Applications. The box is off to
    begin with, and Fouine asks for nothing while it stays off. Folders are
    read with the per-folder permission above, background agent included.
    See https://github.com/basedpolymer/fouine/blob/main/docs/permissions.md

    Semantic search needs a 220 MB model, downloaded on demand and never
    automatically: run `fouine model download`, or use Settings > Search by
    meaning.

    To remove the index and the settings as well as the application:
      brew uninstall --zap --cask fouine
  EOS
end
