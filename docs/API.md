# API et structures de données

## Tables (schéma `public`)

Toutes les tables synchronisées partagent ces colonnes :

| Colonne | Type | Rôle |
|---|---|---|
| `id` | uuid | identifiant unique, créé par l'appareil |
| `user_id` | uuid | propriétaire (imposé par le serveur) |
| `created_at`, `updated_at` | timestamptz | dates (affichage uniquement, jamais utilisées pour arbitrer) |
| `device_id` | text | appareil de la dernière modification |
| `version` | bigint | numéro de version, incrémenté par le serveur |
| `server_seq` | bigint | séquence globale de modification (synchronisation différentielle) |
| `server_updated_at` | timestamptz | date serveur de la dernière écriture |

### `notes`

| Colonne | Type | |
|---|---|---|
| `title` | text | titre |
| `content` | jsonb | contenu structuré (voir *Blocs*) |
| `folder_id` | uuid null | dossier |
| `tags` | uuid[] | étiquettes |
| `favorite`, `archived` | boolean | |
| `trashed_at` | timestamptz null | mise à la corbeille (null = active) |
| `purged` | boolean | suppression définitive (pierre tombale, contenu vidé) |

### `folders`

`name`, `parent_id` (sous-dossiers), `color` (`#RRGGBB`), `position`, `deleted`.

### `tags`

`name`, `color`, `deleted`.

### `attachments`

`note_id`, `file_name`, `mime`, `size_bytes`, `sha256`, `storage_path`
(`<user_id>/<attachment_id>/<nom>` dans le bucket privé `attachments`), `deleted`.

### `note_versions` (lecture seule)

Historique : `note_id`, `version`, `title`, `content`, `device_id`, `reason`
(`edit` ou `conflict`), `saved_at`.

## Format du contenu d'une note

```json
{
  "blocks": [
    { "id": "b1", "type": "h1",       "text": "Révisions" },
    { "id": "b2", "type": "todo",     "text": "Exercices **Grafcet**", "checked": true },
    { "id": "b3", "type": "p",        "text": "Voir [la doc](https://exemple.fr)" },
    { "id": "b4", "type": "code",     "text": "IF S1 THEN KM1 := TRUE;" },
    { "id": "b5", "type": "image",    "attachment_id": "…uuid…" },
    { "id": "b6", "type": "table",    "rows": [["Repère", "Désignation"], ["KM1", "Contacteur"]] },
    { "id": "b7", "type": "divider" }
  ]
}
```

Types de blocs : `p`, `h1`, `h2`, `quote`, `bullet`, `numbered`, `todo`,
`code`, `divider`, `image`, `file`, `table`. Chaque bloc a un identifiant stable,
ce qui permet la fusion bloc par bloc. Les champs inconnus sont conservés
(compatibilité avec de futures versions).

Mise en forme en ligne dans `text` : `**gras**`, `*italique*`, `++souligné++`,
`~~barré~~`, `` `code` ``, `[texte](https://lien)`. Le texte reste lisible tel
quel et compatible Markdown.

## Fonctions (RPC)

### `sync_push(p_entity text, p_row jsonb, p_base_version bigint, p_op_id uuid) → jsonb`

Seul moyen d'écrire. `p_entity` ∈ `notes`, `folders`, `tags`, `attachments`.
`p_base_version` = version serveur sur laquelle se base la modification (0 pour
un nouvel élément).

Réponse :

```json
{ "status": "ok",        "row": { …ligne enregistrée… } }
{ "status": "conflict",  "row": { …version actuelle du serveur… } }
{ "status": "duplicate", "row": { …ligne déjà enregistrée par cette opération… } }
```

Erreurs : `28000` non authentifié, `42501` accès refusé (ligne d'un autre
compte), `22023` paramètre invalide.

### `save_note_version(p_note_id, p_title, p_content, p_device_id) → void`

Archive une version locale écartée lors d'une résolution de conflit.

### `delete_my_account() → void`

Supprime le compte connecté et toutes ses données (l'application supprime
d'abord les fichiers du stockage).

### `cleanup_my_ops() → void`

Purge les identifiants d'opérations de plus de 30 jours.

## Lecture différentielle

```
GET /rest/v1/<table>?server_seq=gt.<curseur>&order=server_seq.asc&limit=500
```

La sécurité au niveau des lignes ne renvoie que les lignes du compte connecté.

## Temps réel

Abonnement *Postgres Changes* sur les quatre tables filtrées par `user_id` :
chaque notification déclenche une lecture différentielle.
