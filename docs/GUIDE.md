# Guide d'utilisation — Nothing Notes 3.0

Ce guide couvre les nouveautés de la version 3.0. Pour l'installation et
l'association des appareils, voir [INSTALLATION.md](INSTALLATION.md).

> **Vos notes sont conservées.** À la première ouverture de la 3.0, une copie
> complète de vos données est créée et vérifiée avant la mise à jour. Les
> notes, dossiers, étiquettes, pièces jointes, l'historique et les appareils
> associés sont contrôlés un par un après la mise à jour. Au moindre écart,
> l'ancienne base est remise en place et l'application vous le dit. Les
> détails sont dans [MIGRATION-3.0.md](MIGRATION-3.0.md).

## Pages et sous-pages

Chaque note est maintenant une **page**, qui peut contenir des **sous-pages**.

| Pour… | Faire |
|---|---|
| Créer une sous-page | dans la page : **Sous-pages → Nouvelle sous-page**, ou menu **⋮ → Nouvelle sous-page**, ou `/` → *Sous-page* |
| Remonter vers la page parente | toucher un élément du **fil d'Ariane** au-dessus du titre |
| Déplacer une page dans une autre | **⋮ → Déplacer dans une page…** (ou appui long sur la page dans la liste). Choisir *Premier niveau* pour la ressortir |
| Dupliquer | **⋮ → Dupliquer** : la page **et ses sous-pages** sont copiées |
| Mettre à la corbeille | la page et ses sous-pages partent ensemble et reviennent ensemble à la restauration |
| Donner une icône | toucher le petit visage à gauche du titre |

* La liste principale ne montre que les pages de premier niveau. Le nombre de
  sous-pages est indiqué sous chaque page. La recherche, elle, trouve aussi les
  sous-pages.
* **Pages** (barre latérale) : l'arborescence des pages qui ont des sous-pages
  et des bases de données.
* **Récents** : les dernières pages ouvertes sur cet appareil.
* Les **dossiers** restent disponibles, comme avant. Une page peut être dans un
  dossier et avoir des sous-pages.

## Écrire : l'éditeur par blocs

* Tapez **`/`** dans une ligne vide, ou touchez le **⊕ rouge** de la barre
  d'outils, pour insérer un bloc : texte, titres 1 à 3, listes, case à cocher,
  tâche suivie, **bloc repliable**, citation, séparateur, code, tableau, image,
  pièce jointe, lien vers une page, sous-page, base de données. Sur téléphone,
  les choix sont de grands boutons.
* Raccourcis de saisie : `# ` `## ` `### ` titres, `- ` liste, `1. ` liste
  numérotée, `[] ` case à cocher, `> ` citation, ` ``` ` code, `---` séparateur.
* **Bloc repliable** : touchez la flèche pour replier ou déplier le contenu.
* **Réorganiser** : faites glisser la poignée ⋮⋮ à gauche d'un bloc. Sur
  téléphone, elle apparaît sur le bloc sélectionné. Sur PC, vous pouvez aussi
  utiliser `Ctrl+Maj+↑` / `Ctrl+Maj+↓`.

## Liens entre pages

* Tapez **`@`** (après un espace ou en début de ligne), puis choisissez la page.
  Le bouton **@** de la barre d'outils fait la même chose.
* Pour suivre un lien, placez le curseur dessus et touchez **Ouvrir la page**.
* En bas de chaque page, la section **Mentionnée dans** liste les pages qui la
  citent (rétroliens).
* La recherche globale porte sur les titres, le contenu, les étiquettes, les
  dossiers et les **propriétés** des bases de données.
* `Ctrl+P` sur PC (**⋮ → Aller à une page…** sur téléphone) ouvre une recherche
  rapide de page.

## Tâches

1. Dans une page, créez une case à cocher.
2. **Appui long sur la case**, ou bouton calendrier à droite du bloc sélectionné, puis
   **Suivre comme tâche**.
3. Réglez le **statut** (à faire, en cours, terminée), l'**échéance**
   (facultative) et la **priorité** (basse, moyenne, haute).

La tâche **n'est pas dupliquée** : c'est la case de votre page. La cocher
termine la tâche ; la décocher la rouvre.

La vue **Tâches** (barre latérale) regroupe toutes les tâches suivies. Filtres
disponibles : ouvertes, à faire, en cours, terminées, **en retard** (en rouge),
toutes. Touchez une tâche pour ouvrir sa page.

*Il n'y a pas de rappel par notification : l'application n'en avait pas, et
cette version n'en ajoute pas.*

## Bases de données

Une base de données est une page qui contient des **entrées**. Chaque entrée
est une sous-page qui a des **propriétés**.

* Créer une base : bouton **+ → Base de données**, ou `/` → *Base de données*
  dans une page.
* Types de propriétés : texte, nombre, date, case à cocher, statut, sélection,
  lien (URL).
* Vues : **Tableau** (sur PC ; les cellules se modifient d'un toucher),
  **Liste** (cartes lisibles sur téléphone), **Calendrier** (par mois, selon une
  propriété date ; toucher un jour crée une entrée à cette date).
* **Trier**, **filtrer** et **rechercher** depuis l'en-tête de la base. Le tri
  et les filtres sont enregistrés avec la vue.
* En ouvrant une entrée, ses propriétés s'affichent en tête de page.
* Retirer une propriété retire la colonne, mais **les valeurs déjà saisies ne
  sont pas effacées** : elles restent dans chaque page.
* **Modèles d'entrée** : ouvrez une entrée, puis **⋮ → Enregistrer comme
  modèle**. Le modèle est proposé au prochain **+ Entrée** de cette base.

## Modèles

Le bouton **+** propose : page vide, base de données, ou un modèle (note
rapide, cours, réunion, projet, liste de tâches, journal, fiche de révision).
`Ctrl+N` crée directement une page vide ; `Ctrl+Maj+N` ouvre le choix.

* **Mes modèles** : **⋮ → Enregistrer comme modèle** depuis n'importe quelle
  page, ou bouton **+** dans la vue **Modèles**. Ils sont synchronisés entre
  vos appareils.
* **⋮ → Ajouter le contenu d'un modèle…** sur une page existante : si la page
  est vide, le modèle la remplit. Sinon, son contenu est **ajouté à la fin**.
  Un modèle ne remplace jamais ce que vous avez écrit.

## Importer et partager

* **Importer des fichiers Markdown** : Paramètres → Données. Chaque fichier
  `.md`, `.markdown` ou `.txt` devient une nouvelle page. Les titres, listes,
  cases, citations, code, tableaux et blocs `<details>` sont reconnus. Aucune
  page existante n'est modifiée.
* **Android** : dans une autre application, **Partager → Nothing Notes** crée
  une page avec le texte ou le fichier Markdown partagé. Depuis une note,
  **Partager… → Partager…** envoie son texte à l'application de votre choix.
  Rien n'est jamais partagé automatiquement.
* **Exporter** une page en TXT, Markdown, HTML ou PDF. Les nouveaux blocs, les
  propriétés, le tableau d'une base et la liste des sous-pages sont inclus.

## Sauvegardes

**Paramètres → Données → Sauvegardes et restauration.**

* Une sauvegarde **vérifiée** est créée automatiquement avant chaque mise à jour
  des données. Elle n'est jamais supprimée automatiquement.
* **Créer une sauvegarde maintenant** : à tout moment.
* **Restaurer** : l'écran indique d'abord ce que contient la sauvegarde. L'état
  actuel est lui-même sauvegardé avant d'être remplacé, vous pouvez donc
  revenir en arrière. Si des appareils sont associés, ils pourront ensuite
  renvoyer les modifications plus récentes qu'ils possèdent.

Emplacement : `%APPDATA%\NothingNotes\backups` sur Windows, et le dossier privé
de l'application sur Android.

## Synchronisation et versions

Les pages, sous-pages, bases de données, tâches, modèles et blocs repliables se
synchronisent comme les notes. Si deux appareils modifient deux propriétés
différentes d'une même entrée, les deux valeurs sont gardées. S'ils modifient
la même, un conflit vous est proposé : rien n'est écrasé.

**Mettez à jour tous vos appareils en 3.0.** Un appareil resté en 2.0 perdrait
les nouveaux champs. La 3.0 refuse donc de se synchroniser avec lui et affiche
« Mettez à jour Nothing Notes sur … ». La synchronisation reprend dès que les
deux appareils ont la même version.

## Raccourcis clavier (Windows)

| | |
|---|---|
| `Ctrl+N` / `Ctrl+Maj+N` | page vide / choisir un modèle |
| `Ctrl+P` | aller à une page |
| `Ctrl+F` | rechercher |
| `Ctrl+S` | enregistrer et synchroniser |
| `Ctrl+B` `Ctrl+I` `Ctrl+U` `Ctrl+E` `Ctrl+Maj+X` `Ctrl+K` | gras, italique, souligné, code, barré, lien |
| `Ctrl+Maj+↑` / `Ctrl+Maj+↓` | monter / descendre le bloc |
| `/` · `@` | insérer un bloc · lier une page |
