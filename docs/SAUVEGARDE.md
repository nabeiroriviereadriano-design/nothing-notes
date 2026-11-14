# Sauvegarde et restauration

Trois niveaux de protection, tous gratuits.

## 1. Copies sur chaque appareil

Chaque appareil connecté garde une copie complète des notes dans sa base
SQLite. La perte d'un appareil ne fait rien perdre : il suffit de se connecter
sur un autre appareil, tout est retéléchargé depuis le serveur.

## 2. Export depuis l'application

*Paramètres → Données → Exporter toutes les notes* (Markdown ou PDF), ou, pour
une note, l'icône de partage → TXT, Markdown, HTML ou PDF.

## 3. Sauvegarde automatique chiffrée de la base distante

L'offre gratuite de Supabase n'inclut pas de sauvegarde automatique. La tâche
[`backup.yml`](../.github/workflows/backup.yml) en réalise une **chaque
dimanche** (et à la demande) :

* export de la base (`pg_dump` des schémas `public` et `auth`) ;
* **chiffrement AES-256** avec une phrase secrète (le dépôt étant public, la
  sauvegarde n'est jamais stockée en clair) ;
* conservation 90 jours dans les artefacts GitHub Actions.

### Mise en place

1. Supabase → **Connect** (en haut du projet) → **Session pooler** → copiez
   l'URI (`postgresql://postgres.xxxx:[MOT-DE-PASSE]@aws-0-….pooler.supabase.com:5432/postgres`)
   en remplaçant `[MOT-DE-PASSE]` par le mot de passe de la base.
   *Utilisez le « Session pooler » : la connexion directe n'est pas accessible
   depuis GitHub (IPv6).*
2. GitHub → Settings → Secrets → Actions :
   * `SUPABASE_DB_URL` = cette URI ;
   * `BACKUP_PASSPHRASE` = une longue phrase secrète (notez-la hors de GitHub).
3. Actions → **Sauvegarde de la base** → *Run workflow* pour tester.

Les fichiers joints (images, documents) restent dans le stockage Supabase et sur
les appareils ; ils ne sont pas inclus dans cette sauvegarde de base.

### Restauration

1. Téléchargez l'artefact `sauvegarde-AAAA-MM-JJ` depuis l'onglet Actions et
   décompressez-le.
2. Déchiffrez :

   ```bash
   gpg --decrypt --output nothing-notes.sql nothing-notes-AAAA-MM-JJ.sql.gpg
   ```

3. Sur un projet Supabase **neuf** : exécutez d'abord la migration
   (`supabase/migrations/…sql`, comme lors de l'installation), puis :

   ```bash
   psql "URI_SESSION_POOLER_DU_NOUVEAU_PROJET" -v ON_ERROR_STOP=1 -f nothing-notes.sql
   ```

4. Dans l'application : *Paramètres → Serveur* → nouvelle adresse et clé, puis
   reconnectez-vous avec le même compte.

## Suppression des données

* **Corbeille** : une note y reste 30 jours puis est supprimée définitivement
  sur tous les appareils.
* **Suppression définitive** : le contenu est effacé du serveur et de son
  historique ; seule une « pierre tombale » vide (identifiant) est conservée
  pour propager la suppression.
* **Suppression du compte** : fichiers, notes, dossiers, étiquettes, historique
  et compte sont supprimés du serveur. Les sauvegardes chiffrées déjà réalisées
  expirent au bout de 90 jours.
