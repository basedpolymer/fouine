# Le guide de Fouine

Fouine est une application de recherche pour macOS. Vous lui indiquez des
dossiers ; Fouine extrait le texte de chacun de leurs documents et retrouve une
page par ses mots ou par son sens. Rien ne quitte votre Mac.

- [1. La fenêtre principale](#1-la-fenêtre-principale)
- [2. Aperçu](#2-aperçu)
- [3. Emporter les résultats](#3-emporter-les-résultats)
- [4. La carte Index](#4-la-carte-index)
- [5. La fenêtre Votre index](#5-la-fenêtre-votre-index)
- [6. Tous vos documents](#6-tous-vos-documents)
- [7. La mise à jour automatique](#7-la-mise-à-jour-automatique)
- [8. La barre des menus](#8-la-barre-des-menus)
- [9. Options de recherche et filtres](#9-options-de-recherche-et-filtres)
- [10. Citer une page](#10-citer-une-page)
- [11. Les réglages](#11-les-réglages)
- [12. Fouine dans Spotlight](#12-fouine-dans-spotlight)
- [13. Fouine dans Raccourcis et Siri](#13-fouine-dans-raccourcis-et-siri)
- [14. Raccourcis clavier](#14-raccourcis-clavier)
- [15. Le menu Aide](#15-le-menu-aide)

---

## 1. La fenêtre principale

La fenêtre se divise en trois panneaux :

| Panneau | Ce qu'il contient |
|---|---|
| Barre latérale (gauche) | la carte « Index », l'interrupteur de mise à jour automatique, vos dossiers, les options de recherche et les filtres |
| Résultats (centre) | les documents trouvés, dépliables page par page, avec l'extrait, vos mots surlignés et l'origine du texte |
| Aperçu (droite) | le document sélectionné, ouvert à la bonne page, les occurrences surlignées |

Tant que vous n'avez ajouté aucun dossier, la fenêtre affiche un écran d'accueil
qui vous invite à en choisir un. Sa dernière ligne s'adresse à ceux qui se
servent d'un assistant IA : pour utiliser Fouine avec Claude, Codex, Antigravity
ou un autre assistant, demandez-lui d'installer le serveur MCP de Fouine. Le
bouton **Copier la demande pour votre assistant**, juste dessous, met toute la
demande dans le presse-papiers, prête à coller. Elle contient la commande à
lancer, avec l'emplacement réel de la ligne de commande de Fouine dans
l'application, les assistants qu'elle configure (Claude Desktop, Claude Code,
Cursor, Codex, Antigravity) et ses options : l'assistant n'a besoin de rien
d'autre.

L'interface s'affiche une fois l'état réel de vos dossiers relu, ce qui évite
tout clignotement au lancement.

Si vous refusez l'autorisation que macOS demande au moment d'ajouter ce premier
dossier, ou si les droits du fichier en interdisent la lecture, le dossier n'est
pas ajouté et une alerte explique pourquoi. En plus d'« OK », l'alerte porte deux
boutons : **Ouvrir les Réglages Système**, qui mène droit au volet
Confidentialité et sécurité ▸ Fichiers et dossiers, et **Réessayer**, qui
rouvre le panneau de choix du dossier. Un dossier introuvable ou vide n'a pas
ces deux boutons, puisqu'il n'y a rien à autoriser.

L'index s'ouvre au lancement, que la fenêtre s'affiche ou non. Si Fouine démarre
avec votre session, sans fenêtre, le panneau de la barre des menus peut quand
même chercher.

### Déposer un dossier sur l'icône de Fouine

Quand vous prenez un dossier dans le Finder et le lâchez sur l'icône de Fouine
dans le Dock, la suite dépend de ce que Fouine indexe déjà.

- Si le dossier est suivi, ou se trouve dans un dossier suivi, la fenêtre passe
  au premier plan et le champ de recherche reçoit le filtre du dossier, curseur
  placé derrière, prêt pour la suite de votre requête. Aucune recherche ne
  démarre. Le filtre porte l'étiquette du dossier suivi, pas celle du
  sous-dossier déposé, car il ne connaît que les dossiers de votre liste.
- Si aucun dossier suivi ne le contient, une question s'affiche : « Chercher dans
  “Factures” avec Fouine ? », « Fouine va lire ce dossier et le tenir à jour. »,
  avec **Ajouter ce dossier** et **Annuler**. Un dossier déposé sur la liste des
  dossiers de la barre latérale est ajouté sans question, parce qu'on vise alors
  la liste. Sur l'icône du Dock, on vise l'application, et le même geste peut
  vouloir dire « cherche ». Plusieurs dossiers lâchés d'un coup tiennent dans une
  seule question. Une fois ajouté, le dossier est traité comme s'il l'avait été
  depuis la barre latérale : une mise à jour démarre aussitôt.

Un fichier déposé sur l'icône ne fait rien, sans message : Fouine cherche dans
des dossiers et n'ouvre pas les documents. Fouine ne figure pas non plus dans le
menu « Ouvrir avec » d'un dossier. Le double-clic sur un dossier l'ouvre
toujours dans le Finder ; l'icône du Dock accepte seulement le dépôt.

### Le champ de recherche

Le champ affiche « Cherchez dans vos documents ». Son infobulle et son aide
parlée donnent la syntaxe : guillemets pour une phrase exacte, astérisque pour un
préfixe, tiret devant un terme pour l'exclure. Trois erreurs courantes ne
trouveraient rien, alors une ligne sous le champ les signale :

| Ce qui est tapé | Ce qui s'affiche |
|---|---|
| `"energie` | Un guillemet n'est pas fermé. |
| `pres:` (ou `pres:` suivi d'un seul mot) | « pres: » attend deux mots. |
| `-energie` | Une recherche qui ne fait qu'exclure ne trouve rien. |

Une recherche qui ne trouve simplement rien n'affiche pas cette ligne. Elle ne
signale qu'une erreur dans la façon d'écrire la requête.

### Quand rien n'est trouvé

Sous « Aucun résultat pour “…” », la fenêtre propose les boutons qui peuvent
encore ramener quelque chose, et eux seuls :

- **Tolérer les fautes de frappe**, si le réglage n'est pas déjà sur
  « toujours » ;
- **Retirer les filtres**, si un filtre, une facette ou une portée est actif ;
- **Chercher aussi par le sens**, si le modèle est prêt et l'interrupteur éteint.

Vient ensuite la phrase « Essayez moins de mots, ou vérifiez l'orthographe. »
Chaque bouton change le réglage qu'il nomme et relance la recherche. Aucun
réglage ne change sans votre clic. Dans cet état, les sections de facettes vides
restent masquées, pour ne pas repousser ces boutons hors de vue.

### Ce qu'on peut faire d'un résultat

- Clic droit : « Afficher dans le Finder », « Ouvrir » (dans l'application
  habituelle), « Rechercher dans ce document », et, seulement si des pages de ce
  document attendent d'être lues, « Lire ses pages scannées en premier ».
  S'y ajoutent « Ouvrir l'aperçu dans sa propre fenêtre » et « Copier une
  référence vers cette page ».
- Glissez une ligne vers Mail, un dossier du Finder ou une application de
  bibliographie : c'est le fichier lui-même que vous déposez.
- Appuyez sur Espace sur la ligne sélectionnée pour le Coup d'œil de macOS,
  comme dans le Finder.
- Double-cliquez, ou appuyez sur ⌘⏎, pour ouvrir la page dans sa propre fenêtre
  d'aperçu.

Les boutons de la barre d'outils (tri, export, « Dans les résultats ») et ceux de
l'aperçu ne sont pas dans le parcours de Tab. C'est le comportement normal de
macOS tant que Réglages Système ▸ Clavier ▸ « Accès clavier complet » est
éteint. Une fois cette option activée, Tab les atteint tous.

### Les comptes, et la liste

Au-dessus de la liste, une ligne indique ce qui a été trouvé et en combien de
temps (« 29 037 pages dans 776 documents · 120 ms »).

Quand **Chercher aussi par le sens** est allumé, les deux recherches ne partent
pas ensemble. La recherche par les mots passe d'abord et ses résultats
s'affichent ; la recherche par le sens suit. Pendant ce temps, les comptes
restent lisibles, avec un tourniquet à côté et « recherche par le sens… », ou,
la toute première fois, « préparation de la recherche par le sens : la première
prend quelques secondes… ». Quand la recherche par le sens répond, la liste est
reclassée : les deux recherches sont fusionnées, l'ordre change, et des pages qui
ne contiennent aucun des mots tapés peuvent apparaître. D'ici là, « Charger
plus » attend, car une tranche de plus arriverait dans une liste sur le point
d'être refaite. Une nouvelle frappe annule les deux recherches.

Chaque document trouvé indique, à droite de son nom, combien de ses pages sont
dans la liste. Les meilleures pages de chaque document passent d'abord, pour
qu'un seul ouvrage de six cents pages ne remplisse pas l'écran. Un livre dont
trois cents pages répondent n'en affiche donc que quelques-unes.

Dans ce cas, le compte devient un lien : « 3 pages sur 300 · Les voir toutes ».
Un clic restreint la recherche à ce document et affiche toutes ses pages
trouvées, de la première à la dernière. Une pastille « dans “nom du document” »
apparaît sous le champ de recherche ; la fermer rend la recherche à tous vos
dossiers. Tant que la pastille est là, le compte redevient un simple nombre, et
les pages suivantes s'obtiennent par « Charger plus » en bas de la liste.

Le compte n'affiche que ce qui a été compté. Tant que toutes les pages trouvées
dans le document ne sont pas comptées, il indique « pages chargées » et rien de
plus. Quand tout est à l'écran, il affiche un seul nombre, sans lien.

Les lignes ne portent aucun pourcentage du type « pertinence : 47 % ». Ce
chiffre rapporterait le score d'une page au meilleur score de la tranche
chargée : il changerait à chaque « Charger plus » et n'aurait pas le même sens
d'une recherche à l'autre. La liste montre à la place l'ordre des documents, et
la ligne « Trouvé parce que… » sous le résultat sélectionné.

---

## 2. Aperçu

Le panneau de droite montre la page trouvée. Son en-tête porte le nom du document
et, en dessous, le chemin abrégé, comme dans la liste des résultats. Le chemin
complet est dans l'infobulle, et nulle part ailleurs.

L'aperçu prend l'une de quatre formes, selon le document :

| Ce qu'on voit | Pour quels documents |
|---|---|
| La page du PDF, avec les mots surlignés | `.pdf` |
| Une image de la page, rendue depuis le fichier | archives de bandes dessinées, `.docx`, `.pptx`, `.xlsx`, images, maquettes Figma et InDesign |
| Le document tel que macOS le dessine | `.rtf`, `.doc`, `.odt`, Pages, Numbers, Keynote, pages web, `.csv`, `.tsv`, `.svg`, `.ai`, anciens `.xls` et `.ppt` |
| Le texte retenu par Fouine, mots cherchés en évidence | tout le reste : EPUB, DjVu, carnets, sous-titres, boîtes aux lettres, fichiers texte et code |

Quand les deux existent, un sélecteur **Document | Texte** au-dessus de l'aperçu
passe de l'un à l'autre. « Document », c'est ce que montre la barre d'espace du
Finder : la mise en page, les images, les couleurs. Vos mots n'y sont pas mis en
évidence, car c'est macOS qui dessine la page et Fouine ne peut pas la marquer ;
l'infobulle du sélecteur le précise. Votre choix vaut pour tous les documents
jusqu'à ce que vous quittiez Fouine. Il n'est pas enregistré dans les réglages :
un choix fait il y a des mois ne peut donc pas changer l'affichage à votre insu.

Pour les documents que macOS dessine (`.rtf`, `.doc`, `.odt`, Pages, pages
web…), le mode « Document » commence toujours à la première page : macOS assure
le rendu et n'offre aucun moyen de lui demander une page. Un PDF s'ouvre bien à
la page trouvée, parce que c'est Fouine qui le dessine.

**Ouvrir le document** (le bouton en haut à droite de l'aperçu) ouvre le fichier
dans l'application que le Finder utiliserait, à la page affichée quand cette
application peut y aller. Seuls les PDF le permettent : la page 3 d'un livre
numérique dépend de la taille de texte choisie par le lecteur, et celle d'un
enregistrement est une tranche de dix minutes qui n'existe que dans Fouine.

| Ce qui ouvre vos PDF | Ce qui se passe |
|---|---|
| Aperçu, le lecteur d'usine de macOS | le document s'ouvre à sa première page |
| Chrome, Edge, Brave, Vivaldi, Opera, Arc, Firefox | le document s'ouvre à la page trouvée |
| Safari | le document s'ouvre à sa première page |
| un autre lecteur | le document s'ouvre comme un double-clic l'ouvrirait |

Aperçu ne peut pas ouvrir un PDF à une page donnée : macOS n'offre aucun moyen
de le lui demander, et Fouine ne peut pas contourner cette limite. L'infobulle du
bouton en tient compte : « Ouvrir dans l'application par défaut — à la page 412
quand elle le permet ». Quand la page ne peut pas être demandée, le document
s'ouvre normalement, sans message et sans attente. Si quelque chose empêche
l'ouverture à la page, le document s'ouvre quand même, au début.

Pour ouvrir vos PDF à la page trouvée, changez l'application qui ouvre les PDF :
dans le Finder, clic droit sur un PDF ▸ « Lire les informations » ▸ « Ouvrir
avec » ▸ choisissez le navigateur ▸ « Tout modifier ».

Sous le numéro de page, une ligne compte combien de fois chacun de vos mots
apparaît sur la page : une pastille de la couleur du mot, le mot, puis le nombre,
par exemple « azote 3 ». Un mot et les formes cherchées avec lui (« polymère »,
« polymères ») partagent une couleur et un seul compte ; un mot absent de la page
n'a pas de pastille. Cinq mots tiennent sur la ligne, les autres sont dans
l'infobulle. « 400+ » signale que le surlignage s'est arrêté à 400 occurrences
de ce mot sur la page.

Sur la page d'un PDF, la même ligne affiche « 3 / 27 » et deux chevrons. ⌘G va à
l'occurrence suivante et ⇧⌘G à la précédente ; les mêmes commandes sont dans le
menu Édition ▸ **Occurrence suivante** et **Occurrence précédente**. Les
occurrences suivent l'ordre de lecture, de haut en bas puis de gauche à droite,
et celle que vous atteignez est sélectionnée. Le parcours reste dans la page :
après la dernière occurrence, vous revenez à la première, et vous faites défiler
le PDF pour changer de page. Sur une page lue sur une image, chaque ligne où un
mot a été trouvé compte une fois. En mode Texte, seules les pastilles
s'affichent : ce panneau ne peut pas défiler jusqu'à un mot, et un compteur
« 3 / 27 » y proposerait un saut impossible.

Un fichier son ou vidéo s'ouvre dans un lecteur, avec sa transcription en
dessous. Le texte est découpé en paragraphes, chacun avec son horodatage
(« 12:40 »), et chaque paragraphe est un bouton qui place le lecteur à ce
passage. Ouvrir un résultat met la tête de lecture au début du passage trouvé
sans lancer la lecture : aucun son ne part à l'improviste dans une salle ou un
train. Les flèches « page précédente » et « page suivante » parcourent
l'enregistrement par tranches de dix minutes, comme les pages d'un livre.

Quand le disque n'est pas branché, l'aperçu montre le texte gardé dans l'index,
avec une ligne : « Le disque qui contient “Livres” n'est pas branché. Voici le
texte que Fouine avait gardé. », et un bouton **Copier ce texte**. Les autres
pages du document restent consultables, car leur texte vient de l'index et non
du disque.

Quand la recherche est restreinte à un document, le bouton **Quitter ce
document** la rend à tous vos dossiers.

Les fenêtres d'aperçu détachées suivent deux règles. Ce sont celles qu'ouvrent un
double-clic, le panneau de la barre des menus ou un lien `fouine://`. Il y a une
fenêtre par document : un second lien vers le même ouvrage change la page de sa
fenêtre et la ramène au premier plan. Et il y en a trois au plus : au-delà, la
fenêtre la moins récemment consultée reçoit le nouveau document. Un PDF de
plusieurs centaines de pages prend de la mémoire ; trois ouverts côte à côte,
c'est un usage, dix oubliés dans la journée, c'est un problème.

Un lien cité il y a un an peut désigner la page 99 999 d'un document raccourci
depuis. La première page s'ouvre alors, avec le message « La page 99 999 n'existe
plus dans ce document. »

**Relire cette page** (clic droit sur la page) n'apparaît que si le texte de la
page affichée a été lu sur une image, ce que l'en-tête indique déjà à côté du
numéro de page. Une page dont le document contenait le texte, ou une page
transcrite depuis un son, n'a pas d'image à relire.

Au clic, la page est remise en attente et une ligne s'affiche sous l'aperçu :
« Cette page sera relue à la prochaine lecture des scans. Son texte ne changera
que si vous venez de cocher sa langue dans Réglages ▸ Indexation. » Rien ne
démarre tout de suite : la prochaine lecture des pages scannées la reprendra. Si
l'index est occupé par une écriture, la ligne dit « L'index est en train de se
mettre à jour. Réessayez dans un instant. » Elle disparaît dès que vous changez
de page.

---

## 3. Emporter les résultats

### Exporter (⇧⌘E, ou le bouton de partage au-dessus de la liste)

Le panneau d'enregistrement propose trois formats et indique ce qui sera
exporté : « Export : 200 lignes — les résultats chargés, sur 29 037 pages
trouvées. » L'export contient les résultats chargés, dans l'ordre affiché, tri
et filtres compris. Il ne contient jamais plus que ce que vous avez vu à
l'écran.

| Format | Pour quoi faire |
|---|---|
| CSV (tableur) | Numbers, Excel, LibreOffice. Colonnes `path, page, score, snippet, root, modified, link`, en anglais et stables : c'est de la donnée, qu'un script relit. |
| JSON (script) | les mêmes champs, pour un traitement automatique. |
| Markdown (notes) | un carnet (Obsidian, Bear, Notion), un document Word, une bibliographie. |

Le fichier Markdown contient un titre, puis une ligne par page trouvée :

```
# Fouine — chlorure (3 résultats)

- [Chimie organique — CAPES tome 2.pdf, page 87](fouine://open?…) — … l'extrait …
```

La référence cliquable est exactement celle que donne « Copier la référence »,
et l'extrait est coupé à deux cents caractères. Il n'y a ni tableau ni en-tête
technique : le fichier se colle tel quel dans un carnet.

**Copier toutes les références** (⌥⌘C, menu Édition, sous « Copier la référence
de cette page ») met dans le presse-papiers une référence par résultat chargé,
dans l'ordre affiché. Sans résultat, l'élément de menu est désactivé.

### Trier

Le menu de tri au-dessus de la liste range les documents par pertinence (le
défaut), par date de modification (récent ou ancien d'abord), par nom de fichier
ou par chemin.

Dès que vous choisissez un autre ordre que la pertinence, tout le jeu de
résultats est chargé avant le tri. Trier les deux cents premiers résultats d'un
fonds de vingt-neuf mille pages donnerait les plus pertinents remis en ordre, pas
les deux cents plus récents, et « le document le plus récent qui parle de X »
n'aurait pas de réponse. Pendant le chargement, la ligne sous les compteurs
indique « Chargement de tous les résultats avant de les trier… ». Le sélecteur
reste actif, et revenir à la pertinence arrête le chargement.

Le chargement s'arrête à deux mille résultats, quelques secondes sur le fonds de
référence. Au-delà, une ligne donne la portée réelle du tri : « Tri par date ↓
sur les 2 000 premiers résultats, sur 29 037 pages trouvées. » Quand tout tient
sous la limite, la ligne disparaît. Une nouvelle recherche arrête le chargement
en cours.

La recherche par le sens ne pagine pas : elle rend un jeu déjà complet, et son
tri porte donc toujours sur l'ensemble.

### Recherches enregistrées

L'historique (le pictogramme d'horloge, à droite du champ) garde les quarante
dernières requêtes, puis les oublie. Pour garder « mes factures 2025 » d'un mois
sur l'autre, choisissez son premier élément, **Enregistrer cette recherche…**. La
requête elle-même est proposée comme nom, et vous pouvez la remplacer.

Les recherches enregistrées apparaissent dans la barre latérale, dans la section
**Recherches enregistrées**, au-dessus des filtres rapides, quand il y en a. Un
clic relance la recherche, un clic droit propose **Renommer…** et **Retirer**.
Faites-en glisser une vers le haut ou vers le bas pour changer sa place : le
nouvel ordre est gardé. Vous pouvez en garder cinquante au plus ; au-delà, la
plus ancienne disparaît.

La requête est enregistrée telle que vous l'avez tapée, préfixes compris :
`dossier:Factures 2025`, `"phrase exacte"` et `-brouillon` restent tels quels.
Les filtres cochés dans la barre latérale ne sont pas enregistrés. Ils se
recochent d'un clic, et leurs valeurs dépendent des documents indexés au moment
où vous cherchez : une sélection de dossier enregistrée l'an dernier pourrait ne
plus correspondre à aucun document, et la recherche ne rendrait rien sans dire
pourquoi.

---

## 4. La carte Index

En haut de la barre latérale, la carte « Index » montre l'essentiel : ce que
fait Fouine, si l'index est à jour, et si quelque chose est attendu de vous.
Elle ne contient que ceci :

- une phrase d'état (« À jour », « Lecture des pages scannées »…) et, dessous,
  une précision quand il y en a une (« Mis à jour il y a 3 min », « Elles seront
  lues dès que le Mac sera branché sur le secteur. ») ;
- pendant un travail, une barre d'avancement et, quand il peut être estimé, le
  temps restant (« environ 2 h restantes »). Le document en cours et le compte
  des pages changent sans cesse : ils sont dans la fenêtre « Votre index » ;
- au plus un bouton, quand vous avez quelque chose à faire ;
- la phrase de place disque, seulement quand le disque risque de manquer de
  place avant la fin du travail ;
- en dernière ligne, le lien **Détails…**, qui ouvre la fenêtre **Votre index**,
  où se trouve tout le reste.

Sous la carte se trouve l'interrupteur **Mettre l'index à jour
automatiquement**.

Le bouton **Arrêter** réagit tout de suite. Au clic, il se désactive, un petit
tourniquet apparaît à côté de la phrase, et celle-ci indique ce qui est attendu :
« Arrêt — “cours.mp4” se termine… » quand un seul document est en cours de
lecture, « Arrêt — 3 documents se terminent… » quand il y en a plusieurs. Fouine
lit jusqu'à quatre documents à la fois, et l'attente dure quelques secondes. Une
lecture en cours s'interrompt entre deux pages (PDF, DjVu) ou pendant la mise par
écrit d'un enregistrement, sans aller jusqu'au bout. Un document interrompu ainsi
n'est ni lu ni en échec : il reste à faire, et la prochaine mise à jour le
reprend depuis le début. Rien n'est perdu, rien n'est à moitié écrit. La lecture
des pages scannées et la préparation de la recherche par le sens s'arrêtent de
la même façon, avec leurs propres phrases.

### États de la carte

La carte affiche un seul état à la fois, choisi dans cet ordre : vérification,
aucun dossier, passe lancée depuis l'application, action attendue de vous, autre
programme qui écrit, mise à jour automatique, à jour.

| Titre affiché | Ligne secondaire | Signification | Bouton |
|---|---|---|---|
| Vérification… | aucune | l'état de l'index est relu au lancement | aucun |
| Aucun dossier à indexer | aucune | aucun dossier n'a été ajouté | Ajouter un dossier… |
| Mise à jour de l'index | le temps restant quand il est connu | parcours des dossiers, extraction du texte | Arrêter *(passe lancée depuis l'application)* |
| Lecture des pages scannées | « Environ 2 h restantes » | reconnaissance du texte des pages scannées | Arrêter *(idem)* |
| Préparation de la recherche par le sens | le temps restant quand il est connu | préparation des pages pour la recherche par le sens | Arrêter *(idem)* |
| L'index se met à jour | « Un autre programme écrit dans l'index ; la recherche fonctionne quand même. » | la ligne de commande met l'index à jour | aucun |
| À jour — N pages scannées à lire | « Elles seront lues dès que le Mac sera branché sur le secteur. » (ou : dès que le mode Économie d'énergie sera désactivé, dès que le Mac aura refroidi, dès que l'autre programme aura terminé, dès que tous les dossiers pourront être lus) | le texte est à jour ; la lecture des pages scannées attend le Mac | aucun *(« Lire les pages scannées… » est dans la fenêtre « Votre index »)* |
| Fouine n'a pas le droit de lire « … » | « Ses documents restent consultables. Autorisez Fouine dans Réglages Système ▸ Confidentialité et sécurité ▸ Fichiers et dossiers… » | macOS refuse la lecture du dossier | Autoriser l'accès… |
| Le disque contenant « … » n'est pas branché | « Ses documents restent consultables. Branchez le disque… » | le dossier est sur un disque absent | Revérifier |
| La mise à jour automatique attend votre accord | « Autorisez Fouine dans Réglages Système ▸ Général ▸ Ouverture et extensions. » | macOS attend votre confirmation | Ouvrir les Réglages Système |
| La mise à jour automatique ne démarre pas | « La relancer suffit en général… » | le service ne s'est jamais signalé, ou s'est arrêté | Relancer la mise à jour automatique |
| Plusieurs copies de Fouine sont installées | « Ne gardez que celle du dossier Applications… » | deux copies de Fouine.app sont installées | Relancer la mise à jour automatique |
| La mise à jour automatique est indisponible | « Fouine doit être installée dans le dossier Applications… » | l'application n'est pas dans Applications | Afficher dans le Finder *(la copie à déposer dans Applications)* |
| À jour | « Mis à jour il y a 3 min » | rien à faire | aucun |
| À jour — N pages scannées à lire | « Elles sont lues automatiquement quand le Mac est branché et au repos. » | le texte est à jour, les pages scannées suivront | aucun |
| Mise à jour manuelle (— N pages scannées à lire) | « Fouine ne met l'index à jour que lorsque vous le demandez. » | la mise à jour automatique est éteinte | Mettre à jour maintenant |

Un service qui tourne mais ne s'est pas signalé depuis quelques minutes (au
réveil du Mac, par exemple) apparaît « À jour », pas en panne. Seul un service
qui ne s'est jamais signalé, ou dont le processus a disparu, mène à « La mise à
jour automatique ne démarre pas ».

### Ce que l'essai ajoute à la carte

Pendant l'essai, une ligne discrète en bas de la carte indique « Essai : 12 jours
restants · Acheter ». C'est le seul rappel : rien ne s'ouvre au lancement et
aucun compte à rebours ne s'affiche en gros caractères. Le reste de la carte
montre ce qu'il montrerait de toute façon.

À la fin de l'essai, la carte remplace son bouton d'action par la phrase « Votre
essai est terminé : la recherche fonctionne toujours, l'index ne se met plus à
jour » et deux boutons, **Saisir une clé de licence…** et **Acheter**. Le bouton
**Mettre à jour maintenant** disparaît, puisqu'il ne pourrait plus rien faire.

L'interrupteur ne change pas. La mise à jour automatique s'arrête d'elle-même,
et griser l'interrupteur demanderait une explication à l'endroit même où la
carte vient d'en donner une.

Si le vendeur a désactivé votre clé, la carte indique « Cette clé a été
désactivée par le vendeur » et les deux mêmes boutons reviennent.

---

## 5. La fenêtre Votre index

Ouvrez-la par le lien **Détails…** de la carte « Index », ou par **Fenêtre ▸
Votre index**. Il n'y en a qu'une : la rouvrir ramène celle qui existe. Elle
relit tout à l'ouverture, puis se tient à jour tant que Fouine est au premier
plan. Pendant une mise à jour de l'index, ses comptes suivent : ils sont relus
toutes les dix secondes au plus, et une dernière fois quand la mise à jour se
termine.

La fenêtre compte quatre parties, qui couvrent ce que la carte laisse de côté.

**Ce que fait Fouine** reprend la phrase d'état de la carte avec sa précision
complète, document en cours compris, la barre d'avancement et le compte des
pages (« 312 / 1 200 pages · environ 2 h restantes »). Les boutons de cet état y
sont aussi : celui de la carte et, en second, un lien **Lire les pages
scannées…** quand des pages scannées attendent. Un bouton qui ouvre une feuille
ramène d'abord la fenêtre principale.

**Mise à jour automatique** contient le même interrupteur **Mettre l'index à jour
automatiquement** que sous la carte, avec la phrase qui l'explique (« Fouine
vérifie vos dossiers de temps en temps et met l'index à jour toute seule, même
quand sa fenêtre est fermée. »). On y trouve aussi la réponse à votre dernier
changement, confirmations comprises (« La mise à jour automatique est activée.
macOS peut vous demander de confirmer dans Réglages Système ▸ Général ▸
Ouverture. »), et l'endroit où régler les moments où elle travaille :
Réglages ▸ Indexation ▸ Quand mettre à jour automatiquement.

**Ce que contient l'index** donne :

- « 1 527 documents · 408 951 pages », deux nombres groupés de la même façon. La
  ligne est un lien qui ouvre « Tous vos documents ». Elle reste un simple texte
  tant que les statistiques se chargent, ou quand l'index est vide, puisqu'une
  liste sans aucune ligne n'apprendrait rien.
- Quand des documents n'ont pas pu être lus, « 23 documents illisibles », qui
  ouvre la fenêtre qui les liste, avec l'explication « Ces fichiers sont dans vos
  dossiers, mais Fouine n'a pas pu les lire. Vos fichiers ne sont pas
  modifiés. »
- Quand la mise à jour automatique a lu de nouvelles pages pendant que Fouine
  était fermée, « Depuis votre dernière visite : 4 200 nouvelles pages ». La
  ligne reste toute la session et n'a pas de case de fermeture : vous avez ouvert
  cette fenêtre pour la lire.
- La place qui reste sur le disque, seulement quand elle manque (ci-dessous).

La ligne de place disque n'apparaît que quand la place vient à manquer sur le
disque qui porte l'index. L'index n'est jamais comparé à une « taille prévue » :
ce chiffre vient des documents de conception, et quiconque ne les a pas lus
prendrait un nombre « prévu » pour une limite.

| Situation | Phrase | Où |
|---|---|---|
| plus de 5 Go libres | *aucune ligne* | nulle part |
| moins de 5 Go libres | « Il reste 3,2 Go libres sur votre disque ; votre index en occupe 2,15 Go » | la fenêtre « Votre index » |
| moins de 1 Go libre, ou moins que ce que la préparation du sens doit encore écrire | « Il ne reste que 800 Mo libres sur votre disque et votre index en occupe 2,15 Go : Fouine risque de manquer de place pour le finir. Libérez de l'espace, ou retirez un dossier dont vous n'avez plus besoin » | la fenêtre et la carte « Index » |

Cette ligne n'arrête jamais rien : l'indexation, la lecture des pages scannées
et la préparation de la recherche par le sens continuent. C'est un
avertissement, et le système refusera d'écrire le jour où le disque sera
vraiment plein. Il n'y a pas non plus de bouton, car la solution est de libérer
de l'espace ou de retirer un dossier, ce que la phrase indique. La place libre
affichée est celle que macOS garantit pour une écriture importante, le chiffre
du Finder, espace purgeable compris, relue en même temps que les comptes de
l'index. Si le volume ne répond pas, aucune ligne ne s'affiche plutôt qu'un
chiffre faux. Les tailles sont écrites comme le Finder les écrit (« 2,15 Go »).

**Pages scannées sans texte lisible** n'apparaît que s'il y en a. Une page
scannée peut avoir été lue sans donner de texte fiable. Son document est bien
dans l'index : ces pages ne comptent donc pas parmi les « documents
illisibles ». Il y a deux cas, chacun sur sa ligne :

```
3 157 pages scannées où Fouine n'a reconnu aucun texte
    Le plus souvent des pages blanches, des images ou des dessins.
1 053 pages scannées lues avec des lettres incertaines
    Scans pâles ou de travers, écriture manuscrite, polices inhabituelles :
    une recherche peut manquer certains de leurs mots.
```

Il n'y a pas de bouton pour les relire. Elles ont été lues au mieux : une
nouvelle lecture passe par la même reconnaissance, avec les mêmes réglages, et
rend le même résultat. Mesuré sur un index réel, les remettre en file laisse les
mêmes pages en place une fois la file vidée.

Relire ne change quelque chose que dans un cas : un document écrit dans une
langue qui n'est pas cochée dans **Réglages ▸ Indexation ▸ Langues des documents
scannés**. Cochez la langue, puis faites un clic droit sur la page dans l'aperçu
et choisissez **Relire cette page**. La ligne sous l'aperçu le rappelle aussi.

En ligne de commande, `fouine ocr requeue [--doubtful|--no-lines]` remet toujours
ces pages en attente, et les deux comptes sont dans `fouine status`.

---

## 6. Tous vos documents

Ouvrez-la par le compte de la fenêtre « Votre index », ou par **Fenêtre ▸ Tous
vos documents (⌘⇧L)**. Il n'y en a qu'une : la rouvrir ramène celle qui existe.
Elle contient :

- un champ **Filtrer par nom** (il cherche dans le nom et dans le dossier ; la
  liste se relit 300 ms après la dernière frappe) ;
- un menu **Dossier** (vos dossiers suivis, ou « Tous les dossiers ») ;
- un menu **Type** (les extensions réellement présentes, la plus fréquente
  d'abord, ou « Tous les types ») ;
- un menu d'ordre : **Récents** (défaut), **Nom**, **Pages** ;
- le compte de tout ce qui répond aux filtres, pas seulement de ce qui est à
  l'écran ;
- la liste, par tranches de 200, avec « Charger plus (N restants) ».

Chaque ligne indique le nom du fichier, le dossier abrégé, le nombre de pages et
la date en clair (« Modifié hier »). Le chemin complet reste dans l'infobulle.
Les documents qui n'ont pas pu être lus sont dans la liste, avec une phrase qui
donne la raison : cette fenêtre existe pour les montrer. Ceux qui attendent
encore portent « Pas encore lu : il le sera à la prochaine mise à jour ».

Un clic ouvre l'aperçu du document à sa première page, dans sa propre fenêtre,
avec les mêmes règles qu'ailleurs : une fenêtre par document, trois au plus. Un
clic droit propose « Afficher dans le Finder », « Ouvrir » et « Rechercher dans
ce document » ; ce dernier ferme la fenêtre et pose la portée dans la fenêtre
principale.

Quand rien ne correspond, la fenêtre indique « Aucun document ne correspond ».

La même liste s'obtient en ligne de commande avec `fouine list`.

---

## 7. La mise à jour automatique

L'interrupteur **Mettre l'index à jour automatiquement**, juste sous la carte
« Index », confie au système la surveillance de vos dossiers. C'est le même
interrupteur que dans la fenêtre « Votre index », sous le même nom.

Quand vous le basculez, aucune phrase ne s'affiche dessous : la carte montre
déjà le nouvel état, et l'attente de l'accord de macOS a son propre état (« La
mise à jour automatique attend votre accord »). Seul un refus s'y affiche.
L'interrupteur revient alors en arrière, et la phrase donne la raison : aucun
dossier (« Ajoutez d'abord un dossier : il n'y aurait rien à tenir à jour. »),
lecture des dossiers pas encore autorisée, ou Fouine installée ailleurs que dans
le dossier Applications. La fenêtre « Votre index » garde la réponse au dernier
changement, confirmations comprises.

Quand un document est créé, modifié ou supprimé dans un dossier indexé, le
changement arrive dans l'index en quelques secondes.

Pour ménager la batterie et la machine, la lecture des pages scannées attend
que :

1. le Mac soit branché sur le secteur ;
2. le mode Économie d'énergie soit désactivé ;
3. le Mac ne chauffe pas ;
4. aucun autre programme n'écrive dans l'index ;
5. tous les dossiers soient lisibles.

Les trois premières conditions se règlent dans Réglages ▸ Indexation. Quand
l'une d'elles manque, la carte la nomme (« Elles seront lues dès que le Mac sera
branché sur le secteur. »), et la lecture reprend d'elle-même ensuite. Pour ne
pas attendre, cliquez sur **Lire les pages scannées…** dans la fenêtre « Votre
index » : une passe démarre tout de suite, pour la durée que vous choisissez.

Ce qui tourne en arrière-plan, son journal et ses réglages : la page « Keeping the index up to date » de la documentation (en anglais).

---

## 8. La barre des menus

Fouine a une icône dans la barre des menus de macOS. L'icône change avec ce que
fait l'index, et prend trois formes :

| Icône | Quand | Ce que dit la ligne d'état du panneau |
|---|---|---|
| Loupe | rien en cours : à jour, mises à jour manuelles, en pause, aucun dossier, contrôle en cours | « À jour », « Mise à jour manuelle », « Aucun dossier à indexer » |
| Flèches circulaires | l'index travaille | « Mise à jour de l'index », « Lecture des pages scannées », « Préparation de la recherche par le sens » |
| Triangle | une action est attendue de vous | « Fouine n'a pas le droit de lire “…” », « La mise à jour automatique attend votre accord »… |

Un changement de forme signale qu'il se passe quelque chose ; la ligne d'état du
panneau dit quoi. VoiceOver lit l'icône avec cette même phrase d'état, jamais
comme « icône ».

Cliquez sur l'icône pour ouvrir un petit panneau. Le curseur est déjà dans le
champ : vous pouvez taper tout de suite.

- Les résultats arrivent pendant la frappe, après un quart de seconde sans
  touche. Une ligne correspond à une page : le nom du fichier, son numéro de
  page, et l'extrait sur une ligne. Les pages d'un même document se suivent. Si
  vous avez éteint **Chercher pendant que je tape** (§ 11), la frappe ne cherche
  plus : le premier ⏎ cherche dans le panneau, le suivant ouvre la fenêtre avec
  la même requête.
- Le panneau affiche huit pages au plus. Quand il y en a davantage, une ligne
  **Tout voir dans Fouine** ferme le panneau et place la requête dans la
  fenêtre, qui a les filtres, les facettes et l'aperçu.
- Un clic sur une page l'ouvre dans sa propre fenêtre d'aperçu, la même que le
  double-clic sur un résultat, à la même page, avec les mêmes surlignages.
- ⌘-clic ouvre le fichier dans son application habituelle.
- ↑ et ↓ parcourent les lignes, et ⏎ ouvre celle qui est sélectionnée ; sans
  ligne sélectionnée, ⏎ envoie la requête à la fenêtre principale.
- Échap ferme le panneau. ⌘Q quitte Fouine.

Ce panneau ne cherche que dans les mots de vos documents. La recherche par le
sens demande de charger un modèle : elle reste dans la fenêtre, car un panneau
doit répondre tout de suite. Le panneau ne touche pas à la fenêtre principale :
ses filtres, sa sélection et sa requête restent en place. Le raccourci global
⌥⌘F ouvre toujours la fenêtre.

Sous les résultats viennent une ligne d'état et deux boutons, rien d'autre. La
ligne reprend la phrase d'état de la carte « Index », en gris, sans bouton ;
elle explique la forme de l'icône. Viennent ensuite **Ouvrir Fouine**, qui
affiche la fenêtre principale ou la ramène au premier plan (aussi dans le menu
Fenêtre, ⌘0), et **Quitter Fouine**. Quand la mise à jour automatique est
allumée, une bulle d'aide sur **Quitter Fouine** rappelle que l'index continue
de se mettre à jour après la fermeture. Quand elle est éteinte, il n'y a pas de
bulle, puisque plus rien ne tournerait. ⌘Q fonctionne depuis le panneau, mais
son glyphe n'y figure pas : un panneau de barre des menus n'est pas un menu, et
macOS n'y dessine pas les raccourcis.

Fermer la fenêtre ne quitte pas Fouine. Si l'option de barre des menus est
active, fermer la fenêtre masque l'icône du Dock et laisse l'application dans la
barre des menus. **Ouvrir Fouine** ou ⌥⌘F rouvre la fenêtre. Un réglage permet
aussi de lancer Fouine avec votre session, directement dans la barre des menus,
sans ouvrir la fenêtre.

---

## 9. Options de recherche et filtres

### Fautes de frappe

Un sélecteur à trois positions règle la tolérance aux fautes d'orthographe et aux
erreurs de reconnaissance :

| Option | Comportement |
|---|---|
| Jamais | recherche stricte mot à mot |
| Auto (défaut) | tolérance seulement si un mot ne donne aucun résultat exact |
| Toujours | recherche élargie systématiquement aux variantes proches |

### Chercher aussi par le sens

La recherche par le sens trouve les passages dont le sujet correspond à votre
requête, même sans mot en commun. L'interrupteur **Chercher aussi par le sens**
réunit les pages trouvées par vos mots et celles trouvées par le sens. Si vos
documents n'ont pas encore été préparés, un bouton lance la préparation. Le
fonctionnement et ce qu'il vaut : la page « Searching » de la documentation (en
anglais).

### Filtres

Sous le champ de recherche, cinq sections restreignent les résultats :

- **Dossiers** : par dossier d'origine ;
- **Types de fichiers** : par format (PDF, DOCX, EPUB…) ;
- **Langues** : par langue du document (la section n'apparaît qu'à partir de deux
  langues) ;
- **Origine du texte** : texte tapé, pages scannées lues par Fouine,
  reconnaissances faites avant Fouine, parole mise par écrit. Ces quatre noms
  sont les mêmes partout : dans la facette, l'en-tête de l'aperçu, le
  pictogramme d'une ligne et pour le lecteur d'écran ;
- **Modifié en** : l'année de dernière modification du fichier, pas l'année de
  l'ouvrage. Un livre de 2003 copié sur le Mac en 2024 est rangé sous 2024, et
  l'infobulle de la section le précise.

**Daté de** apparaît au-dessus de **Modifié en** dès que des résultats portent
une date : l'année inscrite dans le document lui-même (PDF, Word, EPUB,
courriel, photo). Cocher une année ne garde que ces documents. Comme **Modifié
en**, ce filtre ne porte que sur l'affichage, et son infobulle le précise.

Chaque section affiche au plus douze valeurs, celles qui ont le plus de
résultats ; au-delà, une ligne indique « Seules les 12 premières sont
affichées ». Chaque section relance la recherche et met les totaux à jour, sauf
**Modifié en** et **Daté de**, qui ne filtrent que les résultats déjà affichés.

« Origine du texte » est la seule section qui s'applique page par page, car un
même livre peut mêler des pages tapées et des planches scannées. Le filtre rapide
**Scans seulement** pose exactement le même filtre.

### Filtres rapides

Au-dessus des facettes, quatre puces couvrent les filtres les plus courants :
**Modifié cette année**, **Modifié ces 5 dernières années**, **PDF seulement**,
**Scans seulement**. Les fenêtres de date sont des années civiles. Les puces et
les facettes partagent le même état : décocher « pdf » dans « Types de
fichiers » éteint la puce **PDF seulement**, et **Tout effacer** les retire
toutes.

### Pourquoi ce résultat

Sous l'extrait du résultat sélectionné, et de lui seul, une ligne en gris donne
la raison de la présence de cette page : « Trouvé parce que cette page contient
“cinétique” et “chimie”. », « Trouvé par une orthographe proche : “converslon” →
“conversion”. », « Aucun de vos mots n'est sur cette page, mais elle parle du
même sujet. », « Trouvé par vos mots et par le sens. »

La ligne n'affiche aucun nombre. Les mots cités sont les vôtres, et un terme
exclu n'est jamais nommé : ce serait montrer exactement ce que vous avez demandé
d'écarter.

---

## 10. Citer une page

Vous pouvez citer une page trouvée : son nom, son numéro de page, et un lien qui
ramène droit dessus. C'est ainsi que vous renvoyez quelqu'un, ou vous-même six
mois plus tard, à la bonne page d'un ouvrage de mille pages.

Deux endroits le proposent, avec les mêmes mots : le bouton **Copier une
référence vers cette page** dans le panneau d'aperçu, et le sous-menu du même nom
quand vous faites un clic droit sur une ligne de résultat. Au clavier, ⇧⌘C (menu
Édition ▸ **Copier la référence de cette page**) agit sur le résultat
sélectionné.

Chacun propose **Copier la référence** et **Copier le lien**. La référence tient
sur deux lignes :

```
Chimie organique — CAPES tome 2.pdf, page 87
fouine://open?path=/Users/…/Chimie%20organique.pdf&page=87
```

Le lien est seul sur sa ligne, à dessein : Mail, Notes, Pages et Word ne rendent
une adresse cliquable que si rien ne la suit. Pour la même raison, les
parenthèses d'un nom de fichier y sont écrites `%28` et `%29` : un ouvrage
universitaire sur deux porte son année entre parenthèses, et ces mêmes
applications coupent une adresse à la parenthèse fermante.

Une page de son ou de vidéo se cite par son moment. « Page 2 » d'un cours de deux
heures ne mène personne nulle part : la référence donne donc le moment, et le
lien le porte.

```
cours de chimie 12 mars.m4a, 12:40
fouine://open?path=/Users/…/cours%20de%20chimie.m4a&page=2&t=760
```

Le paramètre `t` est un nombre de secondes depuis le début de l'enregistrement :
la position de la tête de lecture quand vous avez copié la référence. À
l'ouverture du lien, le lecteur est placé là, sans démarrer. Seule l'application
écrit `t` ; `fouine search --json` et le serveur d'assistance citent la page.

Un lien `fouine://`, cliqué depuis n'importe quelle application, ramène Fouine au
premier plan et ouvre la page dans sa propre fenêtre d'aperçu. Quand le lien
porte aussi la recherche qui avait mené à cette page, celle-ci est relancée dans
le document et les mots sont de nouveau surlignés.

Un lien cité l'an dernier peut désigner un document déplacé, renommé, ou sorti
des dossiers suivis. La fenêtre affiche alors « Fouine ne connaît pas ce
document », avec le nom du fichier. Une mise à jour de l'index règle la plupart
de ces cas.

Le bouton **Ouvrir le fichier** n'apparaît que pour un document que Fouine aurait
pu indexer : un fichier ordinaire, dans l'un des dossiers que vous suivez, et qui
n'est pas un programme. Un lien peut venir de n'importe où, d'une page web ou
d'un courriel, et son auteur choisit le chemin qu'il porte. Fouine n'ouvre donc
que des documents rangés dans vos dossiers, jamais une application, un dossier
ou un script. Quand un fichier existe à ce chemin sans remplir ces conditions, la
fenêtre indique « Il est en dehors des dossiers que Fouine surveille : Fouine ne
l'ouvrira pas. » et n'affiche aucun bouton. (Un paquet `.rtfd` est techniquement
un dossier, mais c'est un document et il s'ouvre normalement.)

Le lien figure aussi dans l'export des résultats (colonne `link`), dans `fouine
search --json` et dans les réponses du serveur d'assistance. C'est ce qui permet
à un assistant de citer une page de vos documents d'une façon que vous pouvez
vérifier.

---

## 11. Les réglages

Les réglages s'ouvrent par ⌘, et comptent sept onglets.

### Général

- **Garder Fouine dans la barre des menus** (actif par défaut) garde l'icône dans
  la barre des menus et évite que Fouine se ferme avec la fenêtre. Sa description
  dit : « La petite icône en haut de l'écran permet de chercher dans vos
  documents et d'ouvrir Fouine. Elle montre aussi ce que fait l'index. »
- **Chercher pendant que je tape** (actif par défaut) : « Les résultats
  apparaissent au fil de la frappe. Éteint, appuyez sur Entrée pour chercher. »
  Le réglage vaut pour la fenêtre et pour le panneau de la barre des menus, dès la
  touche suivante. Quand il est éteint, la frappe ne fait que proposer des mots
  sous le champ, et ⏎ lance la recherche. Les filtres, les résultats et
  l'historique restent les mêmes.
- **Ouvrir Fouine à l'ouverture de session** démarre l'application en
  arrière-plan à la connexion.
- **Me prévenir quand toutes les pages scannées sont lues** envoie une
  notification macOS quand la file se vide. L'autorisation est demandée d'abord,
  et la case n'est cochée que si macOS accepte. Si la demande est ignorée ou
  refusée, ou si l'autorisation est retirée plus tard dans les Réglages Système,
  la case se décoche, avec la ligne « macOS n'a pas encore autorisé les messages
  de Fouine » et un bouton **Ouvrir les Réglages Système** dessous. L'état est
  relu à chaque ouverture de l'onglet : la case n'est jamais cochée quand aucune
  notification ne peut arriver.
- **Spotlight** : voir le § 12.
- **Raccourci clavier** : rappel de la combinaison ⌥⌘F.

### Licence

C'est le deuxième onglet, juste après Général. C'est celui qu'on ouvre après
avoir acheté, et le seul endroit où l'on règle la fin de l'essai.

- L'état, en une phrase : « Essai : 12 jours restants », « Votre essai est
  terminé : la recherche fonctionne toujours, l'index ne se met plus à jour »,
  « Sous licence — clé se terminant par ·····XYZ456 » avec la date du dernier
  contrôle, « Cette clé a été désactivée par le vendeur », ou, quand la
  vérification mensuelle constate que vous avez libéré ce Mac depuis votre
  espace client, « Ce Mac a été libéré depuis votre espace client. Saisissez de
  nouveau votre clé pour l’utiliser ici. »
- Un champ **Clé de licence** et un bouton **Activer**, inactif tant que le champ
  est vide. Le champ accepte ce que vous collez : espaces, retours à la ligne et
  minuscules sont nettoyés avant l'envoi.
- Un bouton **Acheter Fouine — 39 €**, qui ouvre la page de paiement dans votre
  navigateur. L'application ne vous demande jamais de numéro de carte.
- Une fois la clé saisie, le champ laisse la place à **Désactiver ce Mac**, qui
  demande confirmation : « Ce Mac ne comptera plus parmi vos 3 activations. Vous
  pourrez l'activer à nouveau plus tard. »
- Les refus s'affichent sous le champ, chacun en une phrase avec la marche à
  suivre : « Pas de connexion : connectez-vous à Internet, puis réessayez. »,
  « Cette clé n'est pas reconnue. Vérifiez qu'il n'y a pas de faute de frappe, ou
  retrouvez-la dans le courriel que Creem vous a envoyé. », « Cette clé est déjà
  utilisée sur 3 Mac. Désactivez-en un depuis les réglages, ou depuis votre
  espace client Creem. », « Le service de licence est indisponible pour le
  moment. Votre essai continue ; réessayez plus tard. »
- Le bas de l'onglet indique ce qui part et quand, comme celui des mises à jour :
  la clé et le nom de ce Mac, à l'activation, à la libération, et lors d'une
  vérification en arrière-plan par mois. Rien ne part pendant que Fouine indexe
  ou cherche. Détail : la page « Privacy » de la documentation (en anglais).

Le menu **Fouine ▸ Saisir une clé de licence…** ouvre directement cet onglet, et
**À propos de Fouine** rappelle l'état en une ligne.

### Dossiers

- La liste de vos dossiers avec leur nom et leur emplacement, et les boutons pour
  en ajouter ou en retirer un.
- Pour chaque dossier : **Lire ses pages scannées en premier** (les pages
  scannées de ce dossier passent avant celles des autres), et **Ce que Fouine
  ignore…** (ci-dessous).
- La case de gauche active ou désactive le dossier.
- Quand un réglage est grisé (Fouine hors du dossier Applications, valeur imposée
  par l'environnement), la raison est écrite sous le contrôle, et pas seulement
  dans une infobulle.

Sous chaque dossier, **Ce que Fouine ignore…** ouvre une feuille qui dit en clair
ce qui est laissé de côté dans ce dossier : « Le dossier « Santé » », « Tous les
fichiers .md », « Les fichiers nommés « INDEX.md » ». Une croix au bout d'une
ligne la retire. Trois boutons en ajoutent une, sans taper de motif :

- **Ignorer un dossier…** ouvre un sélecteur de dossier sur ce dossier ;
  choisissez un dossier à l'intérieur. Choisir le dossier lui-même est refusé
  (« C'est le dossier entier. Pour ne plus l'indexer, décochez-le dans la
  liste. »), un dossier situé ailleurs aussi.
- **Ignorer un type de fichier** est un menu des types de fichier présents dans
  ce dossier, les plus nombreux d'abord, chacun avec son compte.
- **Ignorer les fichiers nommés…** affiche un champ pour un nom de fichier, par
  exemple `INDEX.md`.

Ce qui est déjà ignoré ne s'ajoute pas deux fois : la feuille indique « Fouine
ignore déjà cet élément. » Avant d'enregistrer, une phrase donne l'effet :
« Environ 41 documents sortiront de l'index à la prochaine mise à jour. Vos
fichiers ne sont pas touchés. » Retirer une ligne affiche « Ce que vous
n'ignorez plus revient à la prochaine mise à jour. » Rien ne change avant que
vous cliquiez sur **Enregistrer**. Ensuite, si la mise à jour automatique est
éteinte, **Mettre à jour maintenant** applique le changement tout de suite ; si
elle est allumée, le changement s'applique dans les minutes qui suivent.

Fouine n'écrit rien dans votre dossier. Les règles sont gardées dans l'index de
Fouine : elles disparaissent si vous retirez le dossier de Fouine (le décocher
les garde). Un petit fichier nommé `.fouineignore` en haut d'un dossier
fonctionne aussi, pour un dossier que vous partagez ou copiez sur un autre Mac.
Il contient une ligne par chose à laisser de côté : un nom de dossier suivi d'une
barre oblique (`Santé/`), une sorte de fichier (`*.md`), ou le nom exact d'un
fichier (`INDEX.md`). Ses lignes apparaissent dans la même feuille, grisées, avec
« vient du fichier .fouineignore de ce dossier » et sans croix : Fouine ne fait
que lire ce fichier, donc une ligne se retire en le modifiant. Les deux jeux de
règles s'appliquent ensemble. Ce qu'ils nomment sort de l'index, et les
recherches cessent de le trouver. Vos fichiers ne sont jamais touchés, seulement
ce que l'index en garde.

Sous la liste des dossiers, la section **Applications** a une case par
application dont Fouine peut lire les notes : **Apple Notes**, **Bear** et
**Anki**. Quand une case est cochée, Fouine copie le texte des notes dans son
propre dossier pour pouvoir les chercher. La ligne sous les cases l'indique, et
précise que rien ne quitte ce Mac. Décocher efface les copies et retire les notes
de l'index ; vos notes, elles, ne sont jamais modifiées. Sous chaque case, l'état
s'affiche en clair : « pas installée sur ce Mac » (la case est grisée), « Fouine
n'a pas le droit de lire ces notes » avec un bouton **Ouvrir les Réglages
Système**, ou « N notes trouvables ». Apple Notes range ses notes dans un endroit
protégé, qui demande l'Accès complet au disque, un autre volet que « Fichiers et
dossiers ».

Ajouter le dossier d'Anki, d'Apple Notes ou de Bear avec « Ajouter un dossier… »
ne fonctionne pas : l'alerte invite à cocher l'application ici, et son bouton
**Ouvrir les Réglages** ouvre cet onglet.

Ces notes apparaissent comme dans leur application, jamais sous la forme de la
copie de Fouine : une note trouvée porte son titre et l'icône de Notes ou de
Bear, et s'ouvre dans son application. Dans l'aperçu, le bouton « Afficher dans
le Finder » devient **Ouvrir dans Notes** (ou **Ouvrir dans Bear**), parce que
c'est la note que vous voulez modifier. L'aperçu montre son texte. Le Coup d'œil,
le glisser-déposer et « Ouvrir » ne sont pas proposés, puisqu'ils ne montreraient
que la copie de Fouine. Dans « Vos dossiers » et dans la liste ci-dessus, le
dossier d'une application porte l'icône de cette application. Son menu n'a ni
« Afficher dans le Finder », ni « Renommer », ni « Retirer » : l'application
s'éteint ici, avec sa case.

Les cartes Anki arrivent paquet par paquet : chaque paquet est un document de la
liste, sous son nom, avec l'icône d'Anki et, au-dessus, les paquets qui le
contiennent (« Anki › Chimie »). Ses pages sont ses cartes : la liste indique
« carte 12 » et « 74 cartes », l'aperçu « carte 3 sur 642 », et une référence
copiée cite la carte. Une recherche qui touche quarante cartes d'un même paquet
montre donc ce paquet une seule fois, avec « Les voir toutes » pour parcourir les
cartes. Le nom d'un paquet n'est pas traité comme un mot de ses cartes ;
cherchez un paquet par son nom, comme un fichier. Anki peut rester ouvert pendant
que Fouine le lit, et une carte ajoutée il y a une minute est trouvée à la mise à
jour suivante. Dans l'aperçu, le bouton devient **Ouvrir dans Anki**. Anki pour
Mac ne peut pas ouvrir une carte donnée depuis l'extérieur : le bouton ouvre
donc Anki, où la carte est à une recherche. L'aperçu montre le texte de la carte,
puis ses images, lues dans le dossier d'Anki lui-même ; une image effacée dans
Anki n'est simplement pas montrée. Les mots écrits dans une image ne sont pas
cherchés, seulement le texte de la carte. Les sons, indices et étiquettes restent
dans Anki.

Notion et Craft n'ont pas de case, car leurs notes ne se lisent pas sur ce Mac.
Exportez vos pages en Markdown, puis ajoutez le dossier d'export avec « Ajouter
un dossier… ». Une page exportée de Notion se rouvre dans Notion depuis
l'aperçu.

### Indexation

- **Quand mettre à jour automatiquement** : trois conditions à cocher (seulement
  quand le Mac est branché, pas en mode Économie d'énergie, pas quand le Mac
  chauffe).
- **Préparer aussi la recherche par le sens en arrière-plan**, décochée par
  défaut. Quand elle est cochée, Fouine prépare ce dont la recherche par le sens
  a besoin, par courtes tranches et sous les mêmes trois conditions, une fois
  toutes les pages scannées lues. Une phrase sous la case indique quand cela se
  fera, ou, si le modèle n'est pas encore téléchargé, où l'obtenir.
- **Langues des documents scannés** : les langues attendues sur les pages
  scannées, la plus probable d'abord. Ce sont aussi les langues utilisées pour
  mettre les enregistrements par écrit. Chaque langue apparaît sous son nom, par
  ordre alphabétique, avec le code technique dans l'infobulle.
- **Indexer les images (photos, scans, fichiers RAW d'appareil photo)**, cochée
  par défaut. Quand elle est cochée, les photos, les scans et les fichiers RAW de
  vos dossiers suivis entrent dans l'index et passent par la reconnaissance de
  texte. Deux phrases sous la case en donnent les limites : chaque image passe par
  la reconnaissance de texte, ce qui peut occuper Fouine des heures sur un gros
  dossier de photos ; et Fouine lit le texte des documents photographiés (un
  ticket, un courrier, une page), alors que les enseignes, les étiquettes et les
  écritures décoratives lui échappent souvent.
- **Indexer les fichiers son et vidéo (titres, artistes, chapitres…)**, cochée
  par défaut ; décochez-la si un dossier suivi est une bibliothèque musicale
  plutôt qu'un fonds documentaire. Quand elle est cochée, les titres, artistes,
  albums, paroles et chapitres d'un enregistrement deviennent cherchables sans en
  écouter une seconde. Dessous, **Mettre aussi par écrit ce qui est dit**, cochée
  par défaut elle aussi, transcrit la parole sur ce Mac ; rien n'est envoyé nulle
  part. Comptez à peu près la durée de l'enregistrement. La langue doit être
  installée dans Réglages Système ▸ Clavier ▸ Dictée, sinon le document est mis
  de côté avec un message qui le dit. **Durée maximale mise par écrit
  (minutes)** limite l'effort (120 par défaut ; au-delà, seules les métadonnées
  sont indexées). Une page correspond à dix minutes d'enregistrement, chaque
  paragraphe précédé de son horodatage `[mm:ss]`.

### Recherche par le sens

Cet onglet contient l'interrupteur qui active la recherche par le sens, l'état du
modèle (un téléchargement unique de 220 Mo, stocké sur votre Mac), le nombre de
pages préparées et un bouton **Préparer la recherche par le sens…**. Quand la
préparation se fait en arrière-plan (la case ci-dessus cochée, le modèle
installé, la mise à jour automatique active), le bouton est remplacé par
« Fouine s'en occupe toute seule, quand l'ordinateur est branché et au
repos. » : le travail se fait, il n'y a rien à cliquer.

### Mises à jour

L'onglet contient un bouton **Rechercher les mises à jour…** et un interrupteur
de vérification périodique, désactivé par défaut. Aucune donnée personnelle ni
rien qui concerne vos documents n'est jamais transmis. Quand une vérification
échoue (pas de réseau, pas de réponse du serveur), la ligne « Dernière
vérification » indique « impossible de joindre le serveur », et l'onglet ajoute :
« Fouine n'a pas pu vérifier s'il existe une version plus récente. Réessayez plus
tard. Fouine continue de fonctionner telle quelle. » Détail : la page « Updates »
de la documentation (en anglais).

### Avancé

- Ce que Fouine fait à la fois : combien de documents sont lus ensemble, combien
  de pages scannées, et combien de documents en arrière-plan.
- La durée d'un lot de reconnaissance, en minutes.
- La fréquence à laquelle l'état est vérifié de nouveau, en secondes.
- La portée de la tolérance aux fautes de frappe : pages scannées seules, ou
  ensemble de l'index.
- **Installer l'outil en ligne de commande…** : crée le lien symbolique.
- **Ouvrir le journal d'activité** : ouvre le fichier de diagnostic.
- L'emplacement et la taille de l'index, avec un bouton pour l'afficher dans le
  Finder.

---

## 12. Fouine dans Spotlight

Spotlight, la loupe en haut à droite de l'écran (⌘-Espace), ne peut pas lire tous
les documents : un PDF scanné, un DjVu, une bande dessinée ou une archive de
courriel ne lui donnent aucun texte. Fouine a lu ces documents : leur texte est
donc transmis à Spotlight, qui les montre comme n'importe quel autre résultat.

Spotlight affiche alors le nom du fichier, les premières lignes du texte et le
nom du dossier suivi par Fouine. Un clic sur le résultat ouvre Fouine à la page
où se trouvent vos mots quand Spotlight transmet ce que vous avez tapé, et à la
première page sinon. Spotlight cherche aussi dans les noms de fichiers, ce que
Fouine ne fait pas : les documents transmis deviennent donc trouvables par leur
nom.

Par défaut, seuls les documents que Spotlight ne peut pas lire lui sont
transmis. Transmettre un `.docx` ou un `.pdf` ordinaire, que macOS lit déjà,
afficherait deux résultats pour le même fichier. Fouine transmet donc les
documents dont au moins une page vient de la reconnaissance de texte, les
enregistrements dont la parole a été mise par écrit (Spotlight lit le titre d'une
vidéo, jamais ce qui s'y dit), et les formats mesurés comme illisibles pour
Spotlight (`.djvu`, `.cbz`, `.cbr`, `.epub`, `.ai`, `.sketch`, `.fig`, `.indd`).
Le second bouton radio, **Tous les documents que Fouine a lus**, lève cette
restriction.

**Mettre Spotlight à jour maintenant** efface ce que Fouine avait transmis et
transmet tout de nouveau. C'est le seul moyen de retirer de Spotlight un document
supprimé du disque entre-temps, car l'index ne garde aucune trace des
suppressions. **Retirer les documents de Fouine de Spotlight** (avec
confirmation) remet le Mac exactement dans son état d'avant : vos documents ne
sont pas touchés, et Fouine les trouve toujours.

Sous les deux boutons, une ligne confirme la dernière remise : « Dernière remise
le <date> · <N> documents », lue dans l'index lui-même. Sans compte (remise faite
par une version antérieure de Fouine), seule la date apparaît ; avant la première
remise, ou après un retrait, la ligne indique « Aucune remise pour l'instant ».
C'est la seule vérification possible de l'extérieur, car `mdfind` n'interroge pas
l'index de Spotlight que Fouine alimente.

La remise se fait d'elle-même à la fin de chaque mise à jour de l'index et à
chaque ouverture de Fouine. La commande `fouine` et la mise à jour automatique en
arrière-plan n'ont pas accès à Spotlight : ce qu'elles indexent est transmis à
la prochaine ouverture de l'application.

Fouine transmet au plus un mégaoctet de texte par document, en pages entières,
jamais une page coupée au milieu. Sur le fonds de référence (1 527 documents,
surtout des livres scannés), la première remise envoie 561 Mo à Spotlight en
25 secondes, en tâche de fond. Ensuite, chaque mise à jour ne touche que ce qui a
changé et prend quelques millisecondes. Cette limite se règle en ligne de
commande (`spotlight.text_kb`).

Rien ne quitte le Mac : l'index de Spotlight est local, comme celui de Fouine, et
la désinstallation retire les documents transmis avant d'effacer quoi que ce soit
(voir la page « Privacy » de la documentation, en anglais).

---

## 13. Fouine dans Raccourcis et Siri

L'application **Raccourcis**, livrée avec macOS, enchaîne des actions. Fouine y
ajoute trois actions, qui apparaissent dès l'installation quand vous tapez
« Fouine » dans la liste des actions.

| Action | Ce qu'elle prend | Ce qu'elle rend |
|---|---|---|
| Rechercher dans Fouine | ce que vous cherchez, et combien de résultats (10 par défaut, 50 au plus) | une liste de pages trouvées |
| Ouvrir dans Fouine | une page trouvée | rien : Fouine s'ouvre sur cette page |
| Obtenir le texte d'une page | une page trouvée | le texte que Fouine a lu sur cette page |

Chaque page trouvée porte son nom de fichier, sa page, un extrait, le dossier
d'où elle vient, son chemin et son lien Fouine : six variables à glisser dans
l'action suivante.

Un premier enchaînement retrouve une page et l'ouvre : *Rechercher dans Fouine* →
« cinétique de réticulation », puis *Choisir dans la liste*, puis *Ouvrir dans
Fouine*. Un second tire des notes d'un cours : *Rechercher dans Fouine* →
« électrolyse », 5 résultats, puis *Répéter chaque élément*, puis *Obtenir le
texte d'une page*, puis *Créer une note* (Notes), ou *Envoyer un courriel*, ou
*Ajouter au presse-papiers*.

Sur macOS 26 et au-delà, ces mêmes actions sont proposées directement dans
Spotlight : ⌘-Espace, tapez « Fouine », et « Rechercher dans Fouine » est là.

Vous pouvez aussi les lancer avec Siri : « Dis Siri, cherche dans Fouine », ou
« Dis Siri, cherche dans mes documents avec Fouine ». Siri lance l'action, puis
Raccourcis demande quoi chercher : une phrase parlée ne peut pas transporter un
mot libre, seulement une liste de choix connue d'avance.

Ces actions ne lisent que l'index, jamais le fichier d'origine : « Obtenir le
texte d'une page » rend le texte extrait ou reconnu par Fouine, pas le PDF. Elles
n'indexent rien et ne modifient rien. Comme la recherche par les mots de la
fenêtre, elles cherchent dans le texte sans la recherche par le sens, dont le
modèle met deux secondes à se charger, ce qui est trop long pour un raccourci.
Seule « Ouvrir dans Fouine » met l'application au premier plan ; les deux autres
travaillent sans rien déranger, même si Fouine n'était pas ouverte.

Si rien n'a encore été indexé, l'action renvoie un message (« Fouine n'a encore
rien lu. Ouvrez Fouine et ajoutez un dossier. ») plutôt qu'une liste vide, qui se
lirait comme « ce mot n'est nulle part ».

---

## 14. Raccourcis clavier

| Raccourci | Action |
|---|---|
| ⌘F | activer et sélectionner le champ de recherche dans la fenêtre |
| ⌥⌘F | raccourci global : afficher Fouine et chercher depuis n'importe quelle application |
| ⇧⌘E | exporter les résultats de la recherche |
| ⇧⌘C | copier la référence de la page sélectionnée (nom, page, lien) |
| ⌥⌘C | copier toutes les références des résultats chargés |
| Tab | donner le focus à la liste des résultats depuis le champ de recherche ; ↑ et ↓ y déplacent la sélection, ⏎ ouvre |
| ⌘⏎ | ouvrir l'aperçu de la page sélectionnée dans sa propre fenêtre |
| Espace | coup d'œil sur le document sélectionné, depuis la liste des résultats |
| ⌘G | aperçu d'un PDF : aller à l'occurrence suivante des mots cherchés sur la page (menu Édition ▸ Occurrence suivante ; après la dernière, retour à la première) |
| ⇧⌘G | aperçu d'un PDF : revenir à l'occurrence précédente |
| ⌘? | ouvrir le guide de Fouine (menu Aide) |
| ⌘, | ouvrir les Réglages |
| ⌘W | fermer la fenêtre principale (l'application reste dans la barre des menus) |
| ⌘0 | rouvrir la fenêtre principale (menu Fenêtre ▸ Ouvrir Fouine) |
| ⌘⇧L | ouvrir « Tous vos documents » (menu Fenêtre) |
| ⌘Q | quitter l'application |

---

## 15. Le menu Aide

Le menu **Aide** contient **Guide de Fouine** (⌘?), qui ouvre la page que vous
lisez dans sa propre fenêtre. Le guide est fourni avec l'application : il
s'affiche sans connexion. Il existe en français et en anglais, et suit la langue
de l'application.

- Les renvois internes restent dans la fenêtre du guide.
- Un lien vers un site s'ouvre dans votre navigateur habituel, jamais dans la
  fenêtre du guide.

**À propos de Fouine** (menu Fouine) affiche la version et la phrase « Fouine lit
vos documents sur ce Mac et rien n'en sort. », puis trois liens : la licence
(source-available, livrée avec l'application), les composants tiers et le code
source du projet. Les deux premiers ouvrent des fichiers fournis dans
l'application ; le troisième ouvre la page du projet dans votre navigateur.
