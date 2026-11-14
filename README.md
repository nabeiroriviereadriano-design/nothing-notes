<p align="center">
  <img src="app/assets/branding/logo_256.png" width="112" alt="Logo Nothing Notes">
</p>

<h1 align="center">NOTHING NOTES</h1>

<p align="center">
  Prise de notes minimaliste · Android + Windows · synchronisation réelle, hors ligne, gratuite
</p>

<p align="center">
  <a href="../../actions/workflows/tests.yml"><img src="../../actions/workflows/tests.yml/badge.svg" alt="Tests"></a>
  <a href="../../actions/workflows/build.yml"><img src="../../actions/workflows/build.yml/badge.svg" alt="Build"></a>
  <a href="../../releases/latest"><img src="https://img.shields.io/github/v/release/nabeiroriviereadriano-design/nothing-notes?label=t%C3%A9l%C3%A9charger&color=E60012" alt="Télécharger"></a>
</p>

---

Écrivez une note sur votre téléphone, posez-le, ouvrez Nothing Notes sur votre
PC : la note est là. Modifiez-la sur le PC, elle est à jour sur le téléphone.
Sans export, sans copier-coller, même après avoir travaillé hors ligne.

## Fonctionnalités

**Synchronisation**
- Bidirectionnelle et automatique entre tous les appareils d'un même compte (temps réel)
- Entièrement utilisable **hors ligne** : file d'attente persistante, envoi automatique au retour du réseau
- **Conflits** détectés sans jamais écraser une version : fusion automatique quand c'est sans risque, choix proposé sinon
- Synchronisation différentielle et paginée, reprise après coupure, anti-doublons
- Images et pièces jointes synchronisées
- Indicateur d'état permanent : synchronisé, en cours, hors ligne, en attente, erreur, conflit

**Éditeur**
- Titres, sous-titres, citations, listes à puces et numérotées, cases à cocher
- **Gras**, *italique*, souligné, ~~barré~~, `code`, liens, séparateurs
- Images, pièces jointes, tableaux, blocs de code
- Raccourcis de saisie : `- ` liste, `[] ` tâche, `# ` titre, `> ` citation, ` ``` ` code, `---` séparateur
- Historique des versions et restauration

**Organisation**
- Dossiers et sous-dossiers, étiquettes colorées, favoris, archives, corbeille (30 jours)
- Recherche instantanée dans les titres, le contenu, les étiquettes et les dossiers (sans accents, par préfixe)
- Tri et filtres

**Windows** : application de bureau native en trois colonnes, redimensionnable,
raccourcis `Ctrl+N` `Ctrl+S` `Ctrl+F` `Ctrl+B` `Ctrl+I` `Ctrl+U` `Ctrl+Z` `Ctrl+Maj+Z`,
installateur sans droits administrateur, mise à jour et **désinstalleur** propres.

**Android** : interface tactile, ouverture des notes en plein écran, thème clair et sombre.

**Export** : TXT, Markdown, HTML et PDF.

**Comptes** : inscription, connexion, mot de passe oublié, déconnexion de tous
les appareils, suppression du compte.

## Démarrer

1. **Serveur** (gratuit, 10 min) : créez un projet Supabase et exécutez le script SQL
   → [docs/INSTALLATION.md](docs/INSTALLATION.md)
2. **Applications** : téléchargez l'installateur Windows et l'APK depuis
   [Releases](../../releases/latest).
3. Créez votre compte sur un appareil, connectez-vous sur l'autre. C'est tout.

## Coût

**0 €.** Supabase Free (500 Mo de notes, 1 Go de fichiers) et GitHub Actions
(compilation gratuite pour un dépôt public). Aucune carte bancaire.

## Documentation

| | |
|---|---|
| [INSTALLATION.md](docs/INSTALLATION.md) | serveur, secrets GitHub, compilation, installation, mise à jour, désinstallation |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | choix techniques comparés, synchronisation, conflits, sécurité |
| [API.md](docs/API.md) | tables, format des notes, fonctions serveur |
| [TESTS.md](docs/TESTS.md) | scénarios testés et résultats |
| [SAUVEGARDE.md](docs/SAUVEGARDE.md) | sauvegarde chiffrée automatique et restauration |

## Technologies

Flutter (une seule base de code native pour Android et Windows) · Dart ·
SQLite + FTS5 · Supabase (PostgreSQL, Auth, Storage, Realtime) · Inno Setup ·
GitHub Actions.

## Confidentialité

Les notes transitent en HTTPS et chaque compte n'accède qu'à ses propres données
(règles de sécurité vérifiées par la base). Elles ne sont **pas chiffrées de bout
en bout** : l'administrateur du projet Supabase peut techniquement y accéder.

## Identité graphique

Inspirée de l'esthétique Nothing OS (noir, blanc, gris, rouge en accent,
motifs de points) sans en reprendre les éléments propriétaires : polices
libres [Doto](https://github.com/oliverlalan/Doto), [Inter](https://rsms.me/inter/)
et [JetBrains Mono](https://www.jetbrains.com/lp/mono/) (licence OFL), logo et
icônes originaux. Projet indépendant, sans lien avec Nothing Technology Ltd.

## Licence

MIT
