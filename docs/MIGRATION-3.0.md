# Passage de la 2.0 à la 3.0 : données et migration

Principe : **aucune donnée existante n'est supprimée, vidée, recréée ni
réécrite.** La migration ajoute, elle ne transforme pas.

## ⚠️ Android : l'ordre à suivre pour passer de la 2.0 à la 3.0

L'APK publié n'a pas de clé de signature fixe (voir INSTALLATION.md). Android
refuse donc d'installer la 3.0 **par-dessus** la 2.0. Il faut désinstaller la
2.0, et **désinstaller une appli Android efface ses données**. Pour ne rien
perdre :

1. **Les deux appareils encore en 2.0**, sur le même réseau : ouvrez Nothing
   Notes sur le téléphone **et** sur le PC, et attendez « Synchronisé » des deux
   côtés. Toutes les notes du téléphone sont alors aussi sur le PC.
2. Vérifiez sur le PC que vos dernières notes du téléphone y sont.
3. **Mettez à jour le PC** en 3.0 (installation par-dessus, sans rien
   désinstaller). Il sauvegarde et migre sa base.
4. Sur le téléphone : désinstallez la 2.0, installez la 3.0, puis associez-le à
   nouveau au PC (*Appareils → Saisir un code*). Les notes reviennent depuis le PC.

Sans PC associé, exportez d'abord vos notes depuis la 2.0 (*Paramètres →
Exporter toutes les notes (Markdown)*). Réimportez-les ensuite dans la 3.0
(*Paramètres → Importer des fichiers Markdown*). Les pièces jointes et
l'historique ne sont pas repris par cette voie.

Sur Windows, aucune précaution n'est nécessaire : la 3.0 s'installe par-dessus
la 2.0 et migre la base en gardant tout.

## Ce qui change dans la base (`notes.db`)

| Élément | Changement | Nature |
|---|---|---|
| `PRAGMA user_version` | 2 → 3 | numéro de version |
| Table `links (src, dst)` + index `links_dst` | **créée** | index des liens entre pages, recalculable à tout moment à partir des notes |
| Tables `entities`, `history`, `files`, `peers`, `peer_state`, `meta`, `notes_fts` | **inchangées** | aucune ligne n'est modifiée par la migration |

Les nouveautés sont stockées comme **champs facultatifs** dans les données des
notes, déjà en JSON. Ils ne sont écrits que s'ils servent :

| Champ de la note | Rôle |
|---|---|
| `parent_id` | page parente (sous-page) |
| `kind` | `database` ou `template` (absent = page ordinaire) |
| `icon` | emoji de la page |
| `props` | valeurs des propriétés d'une entrée de base |
| `db` | définition d'une base : propriétés et vues |
| `template_for` | modèle d'entrée : base visée |

| Champ d'un bloc | Rôle |
|---|---|
| `type: "h3"`, `type: "toggle"` | titre 3, bloc repliable |
| `body`, `collapsed` | contenu et état d'un bloc repliable |
| `task: {status, due, priority}` | case à cocher suivie comme tâche |

Une note créée en 2.0 et jamais modifiée garde **exactement** la même forme. Une
note 2.0 modifiée en 3.0 aussi, tant que les nouvelles fonctions ne lui sont pas
appliquées : c'est vérifié par un test.

**Champs inconnus conservés.** Les notes, blocs, dossiers, étiquettes, pièces
jointes, le contenu des notes et la définition des bases gardent tel quel tout
champ qu'ils ne connaissent pas. Une future version pourra donc ajouter des
champs sans qu'une 3.0 les efface.

## Procédure exécutée au démarrage

Code : `DataSafety.openStore` ([safety.dart](../packages/notes_core/lib/src/safety.dart)).

1. Si la base est déjà en version 3 : ouverture normale, sans sauvegarde.
2. Contrôle d'intégrité SQLite (`PRAGMA integrity_check`). Si la base est
   endommagée, **aucune migration n'est tentée** et le fichier n'est pas touché.
3. **Empreinte complète des données** (SHA-256 de chaque note, dossier,
   étiquette, pièce jointe, fichier, version d'historique, appareil associé,
   état de synchronisation, identité de l'appareil et compteur du journal) et
   comptage de chaque catégorie.
4. **Sauvegarde** `backups/notes-v2-avant-migration-AAAAMMJJ-HHMMSS.db`
   (`VACUUM INTO`, ce qui inclut le journal WAL). La sauvegarde est ensuite
   **rouverte et vérifiée** : intégrité et empreinte identique à l'original.
   Sinon, arrêt.
5. Migration dans **une seule transaction** : création de `links`, calcul des
   liens, `user_version = 3`. En cas d'erreur, `ROLLBACK`.
6. **Vérification après migration** : l'empreinte doit être identique à celle
   de l'étape 3.
7. Au moindre écart ou erreur : la base d'origine est **remise en place**
   depuis la sauvegarde, et l'application s'arrête sur un écran d'explication
   avec le chemin de la sauvegarde. Elle ne démarre jamais sur des données
   douteuses.

Les sauvegardes d'avant mise à jour et les sauvegardes manuelles ne sont
**jamais supprimées automatiquement**. Seules les copies « avant restauration »
sont limitées aux 5 plus récentes.

## Vérifications effectuées

| Vérification | Comment | Résultat |
|---|---|---|
| Copie réelle de vos données (`notes.db`, gardée privée, jamais publiée) | rejeu de la migration sur une copie, empreinte avant/après | **identique** : 12 notes, 2 dossiers, 1 étiquette, 19 pièces jointes, 15 fichiers, 76 versions d'historique, 1 appareil, 33 états de synchro ; sauvegarde identique ; intégrité OK |
| Mêmes données passées par les modèles 3.0 | lecture puis réécriture de chaque ligne | 34 / 34 lignes et 360 blocs identiques |
| Base produite par le **vrai code 2.0.0** (CI) | générée par `tool/v2_fixture.dart` dans une copie de la version 2.0.0, puis migrée | toutes les données conservées et utilisables : conflit en attente, appareil associé, historique, pièces jointes retrouvées, recherche |
| Échec forcé pendant la migration | test automatique | base d'origine remise en place, version 2 inchangée, données identiques |
| Base endommagée | test automatique | aucune migration, fichier non modifié |
| Restauration d'une sauvegarde | test automatique | retour exact aux données sauvegardées ; l'état remplacé est lui-même sauvegardé ; le journal des changements ne recule jamais |

## Revenir en arrière

* **Dans l'application** : Paramètres → Données → Sauvegardes et restauration
  → *Avant la mise à jour* → Restaurer.
* **À la main** (application fermée) : copiez le fichier
  `notes-v2-avant-migration-….db` à la place de `notes.db` dans le dossier de
  l'application, supprimez `notes.db-wal` et `notes.db-shm`, puis réinstallez la
  version 2.0.0.

La 2.0 peut aussi ouvrir une base 3.0, car elle ignore la table `links`. Mais
elle ne connaît pas les nouveaux champs et les effacerait en enregistrant une
page qui en contient. Pour revenir en 2.0, utilisez donc la sauvegarde
d'avant migration.

## Synchronisation entre versions

Le protocole de synchronisation passe en version 2. Un appareil 3.0 **refuse**
de se synchroniser avec un appareil 2.0, dans les deux sens, pour que la 2.0
n'efface pas les nouveaux champs. Le message affiché est « Mettez à jour
Nothing Notes sur … ». Rien n'est échangé tant que les deux appareils ne sont
pas en 3.0 ; ensuite la synchronisation reprend normalement.

## Désinstallation

Le désinstalleur Windows demande toujours s'il faut supprimer
`%APPDATA%\NothingNotes`. Ce dossier contient aussi `backups\`. Répondez
**Non** pour garder vos notes et vos sauvegardes.
