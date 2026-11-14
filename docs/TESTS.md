# Tests

Tous les tests sont exécutés automatiquement par GitHub Actions à chaque
modification (onglet **Actions**). Aucun résultat n'est déclaré sans exécution.

## 1. Scénarios du cahier des charges — contre un vrai serveur Supabase

Job **« Bout en bout (vrai backend Supabase) »** du workflow *Tests* : une
instance Supabase complète (PostgreSQL, Auth, Storage, Realtime) est démarrée
avec `supabase start`, la migration est appliquée, puis le code de
synchronisation **embarqué dans les applications** est exécuté par plusieurs
« appareils » indépendants (chacun avec sa base SQLite sur disque, sa propre
session et son propre moteur de synchronisation).

| # | Scénario | Ce qui est vérifié |
|---|---|---|
| 1 | Création | Note créée sur « Android » → présente sur « Windows » avec son contenu et ses cases cochées |
| 2 | Modification | Titre, contenu et favori modifiés sur « Windows » → à jour sur « Android », version 2 |
| 3 | Hors ligne | Note + dossier créés sans réseau, application **redémarrée** hors ligne (file d'attente conservée), puis synchronisés au retour du réseau |
| 4a | Modifications simultanées (blocs différents) | Les deux appareils hors ligne modifient des blocs différents → fusion automatique, rien n'est perdu, identique des deux côtés |
| 4b | Modifications simultanées (même paragraphe) | Conflit détecté, version locale intacte, serveur non écrasé ; « garder les deux » → deux notes identiques sur les deux appareils |
| 4c | « Garder ma version » | La version de l'autre appareil reste dans l'historique du serveur |
| 4d | Modification vs corbeille | Le texte ajouté est conservé, la note reste récupérable dans la corbeille |
| 5 | Suppression | Corbeille propagée, restauration propagée, suppression définitive propagée (et retirée de la recherche) |
| 6 | Pièces jointes | Image ajoutée sur « Android » → téléchargée automatiquement sur « Windows », contenu identique (SHA-256) ; suppression propagée et fichier distant supprimé |
| 7 | Redémarrage | Les deux applications redémarrent : notes, étiquettes conservées ; reprise au curseur sans retéléchargement |
| 8 | Plusieurs appareils | 3 appareils, 12 notes, modifications croisées → états identiques, aucune opération en attente ni conflit |
| 9 | Sécurité | Un autre compte ne reçoit rien, ne peut ni lire ni écraser la note (même en réutilisant son identifiant), ni lire ou écraser ses fichiers |
| — | Réponse perdue | L'opération renvoyée n'est pas appliquée deux fois |
| — | Réponse perdue puis nouvelle modification | Aucune perte, aucun faux conflit |
| — | Pagination / reprise | Coupure pendant la réception : la page reçue est conservée, la suite reprend au curseur |
| — | Dossiers, sous-dossiers, étiquettes | Synchronisés ; suppression d'un dossier → notes conservées à la racine |
| — | Saisie pendant une synchronisation | Rien n'est perdu |
| — | Écriture directe dans les tables | Refusée (tout passe par `sync_push`) |
| — | Accès anonyme | Refusé |
| — | Temps réel | L'autre appareil est notifié en quelques secondes |
| — | Déconnexion de tous les appareils | Les sessions des autres appareils ne peuvent plus être renouvelées ; la reconnexion par mot de passe reste possible |
| — | Suppression du compte | Données et fichiers effacés, autre session sans accès, reconnexion impossible |

**Résultat : 22 / 22 réussis.**

Les mêmes scénarios tournent aussi contre un serveur simulé en mémoire
(job *Noyau de synchronisation*), avec les tests unitaires de fusion, de
recherche, d'export et de mise en forme : **45 / 45 réussis**.

## 2. Backend SQL

Job **« Backend SQL (PostgreSQL) »** : migration appliquée deux fois
(ré-exécutable), puis 29 vérifications — création, version, idempotence,
détection de conflit sans écrasement, historique, écriture directe refusée,
isolation des comptes (lecture, écriture, historique, fichiers), accès anonyme
refusé, pierre tombale, suppression du compte en cascade.
**Résultat : 29 / 29 réussis.**

## 3. Applications

Workflow **Build Android + Windows** :

| Vérification | Résultat |
|---|---|
| Analyse statique de l'application | aucune erreur ni avertissement (15 remarques d'information sur des API signalées comme dépréciées par la dernière version de Flutter) |
| Interface bureau (1440×900) : trois colonnes, saisie, `[] ` → cases à cocher, Entrée → bloc suivant, gras, enregistrement local, file de synchronisation, nouvelle note | réussi |
| Interface téléphone (400×860) : liste, ouverture d'une note, retour, recherche instantanée | réussi |
| Compilation de l'APK Android | réussie |
| Compilation Windows (exécutable natif) | réussie |
| L'exécutable Windows démarre et reste ouvert 12 s sans erreur | réussi |
| Installation silencieuse (sans droits administrateur), présence de l'exécutable, désinstallation, exécutable supprimé | réussi |
| Captures d'écran de l'interface (polices réelles), publiées sur la branche `captures` | générées |

## 4. Ce qui reste à vérifier à la main

Les tests automatisés couvrent le code exact des applications et un vrai
serveur Supabase (la même pile logicielle que l'offre en ligne, démarrée
localement), mais pas :

* **un téléphone physique ni l'écran d'un PC réel** — l'APK est compilé mais
  n'a pas été lancé sur un appareil Android ; l'exécutable Windows est lancé
  et installé en CI, sans interaction à l'écran ;
* **votre projet Supabase en ligne** — il n'existe qu'une fois créé par vous ;
* **les e-mails** (confirmation d'inscription, code de réinitialisation du mot
  de passe) — ils dépendent des modèles d'e-mail de votre projet
  (voir [INSTALLATION.md](INSTALLATION.md)) ;
* l'ajout d'une image depuis la galerie du téléphone et l'export PDF (le
  transfert et l'intégrité des fichiers sont testés, pas le sélecteur de
  fichiers du système).

Après installation, refaites les scénarios 1, 2 et 3 sur votre téléphone et
votre PC (environ 5 minutes) : écrire une note sur le téléphone, la voir sur le
PC, la modifier, puis recommencer en mode avion. Testez aussi une fois « mot de
passe oublié ».

## Lancer les tests soi-même

```bash
# Noyau (Dart) — serveur simulé
cd packages/notes_core && dart pub get && dart test

# Contre un Supabase local (Docker requis)
supabase start
eval "$(supabase status -o env)"
SUPABASE_URL=$API_URL SUPABASE_ANON_KEY=$ANON_KEY dart test test/sync_supabase_test.dart --concurrency=1

# Backend SQL (PostgreSQL local)
psql -v ON_ERROR_STOP=1 -f supabase/tests/stub_supabase.sql \
     -f supabase/migrations/20261114000000_nothing_notes.sql -f supabase/tests/backend_test.sql

# Application
cd app && flutter test
```
