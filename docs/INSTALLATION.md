# Installation complète (100 % gratuite)

Durée : environ 15 minutes, une seule fois. Tout repose sur des offres gratuites :
**Supabase Free** (base de données, comptes, fichiers, temps réel) et
**GitHub Actions** (compilation de l'APK et de l'installateur Windows, gratuite et
illimitée pour un dépôt public).

---

## 1. Créer le serveur Supabase

1. Créez un compte sur <https://supabase.com> (gratuit, sans carte bancaire).
2. **New project** → nom `nothing-notes`, choisissez un mot de passe de base de
   données (gardez-le, il sert aux sauvegardes) et la région **West EU (Paris)**
   ou la plus proche → **Create new project**.
3. Une fois le projet prêt : **SQL Editor** → **New query** → collez tout le
   contenu de [`supabase/migrations/20261114000000_nothing_notes.sql`](../supabase/migrations/20261114000000_nothing_notes.sql)
   → **Run**. Le message `Success. No rows returned` confirme l'installation
   (tables, règles de sécurité, fonctions de synchronisation, stockage des
   pièces jointes, temps réel). Le script peut être relancé sans risque.

### Comptes et e-mails

Dans **Authentication** :

* **Sign In / Providers → Email** : laissez *Email* activé.
* Choisissez **l'une** des deux options pour la confirmation d'inscription :
  * **Simple** : désactivez *Confirm email*. Le compte est utilisable
    immédiatement après l'inscription.
  * **Avec vérification** : laissez-la activée et ajoutez le code dans le
    modèle d'e-mail (étape suivante) ; l'application demande alors le code reçu.
* **Emails → Templates** : pour que la réinitialisation du mot de passe
  fonctionne depuis l'application (Android comme Windows), ajoutez le code au
  modèle **Reset Password** (et **Confirm signup** si la vérification est
  activée), par exemple :

  ```html
  <h2>Nothing Notes</h2>
  <p>Votre code : <strong>{{ .Token }}</strong></p>
  ```

> L'offre gratuite limite l'envoi d'e-mails à quelques messages par heure, ce
> qui suffit pour un usage personnel. Pour davantage, configurez un serveur SMTP
> gratuit (Brevo, Resend…) dans *Authentication → Emails → SMTP Settings*.

### Récupérer l'adresse et la clé publique

**Project Settings → API** (ou *Data API* / *API Keys*) :

* **Project URL** : `https://xxxxxxxx.supabase.co`
* **anon / publishable key** : la clé **publique** (commence par `eyJ…` ou `sb_publishable_…`).

⚠️ N'utilisez jamais la clé `service_role` / `secret` dans l'application ni sur
GitHub : elle contourne toutes les règles de sécurité. L'application n'en a pas
besoin.

---

## 2. Relier GitHub au serveur

Dans le dépôt GitHub : **Settings → Secrets and variables → Actions → New repository secret** :

| Secret | Valeur | Rôle |
|---|---|---|
| `SUPABASE_URL` | Project URL | intégrée à l'APK et à l'installateur |
| `SUPABASE_ANON_KEY` | clé publique anon | idem (clé publique, sans danger) |

Ces deux secrets sont facultatifs : sans eux, l'application demande l'adresse
du serveur au premier lancement (écran *Serveur de synchronisation*).

Ils activent aussi la tâche gratuite [`keepalive.yml`](../.github/workflows/keepalive.yml)
qui interroge le serveur tous les 3 jours : les projets Supabase gratuits sont
mis en pause après une semaine sans activité.

### Signature Android stable (recommandé)

Pour pouvoir installer les mises à jour de l'APK par-dessus l'ancienne
version, l'APK doit toujours être signé avec la même clé. Créez-la une fois
(Java installé) :

```bash
keytool -genkeypair -v -keystore nothingnotes.jks -alias nothingnotes \
  -keyalg RSA -keysize 4096 -validity 10000
base64 -w0 nothingnotes.jks > nothingnotes.jks.b64   # Windows : certutil -encode nothingnotes.jks nothingnotes.jks.b64
```

Puis ajoutez les secrets `ANDROID_KEYSTORE_BASE64` (contenu du fichier `.b64`
sans les lignes `-----BEGIN/END-----`), `ANDROID_KEYSTORE_PASSWORD` et
`ANDROID_KEY_ALIAS` (`nothingnotes`). Conservez le fichier `.jks` en lieu sûr.

---

## 3. Compiler et publier

Les compilations sont automatiques à chaque envoi sur `main` (onglet
**Actions**). Lorsqu'une compilation réussit avec une version qui n'a pas encore
été publiée (champ `version:` de [`app/pubspec.yaml`](../app/pubspec.yaml)),
elle est publiée automatiquement. Pour sortir une mise à jour, augmentez
simplement ce numéro (par exemple `1.0.1+2`) et envoyez la modification ; un
tag `v1.0.1` fonctionne aussi.

Une **Release GitHub** est créée avec :

* `NothingNotes-Setup-1.0.0.exe` — installateur Windows 10/11 ;
* `NothingNotes-1.0.0-portable.zip` — version sans installation ;
* `NothingNotes-1.0.0.apk` — Android 7.0 et plus récent.

### Compiler soi-même (facultatif)

Prérequis : [Flutter](https://docs.flutter.dev/get-started/install) (canal stable),
Visual Studio 2022 « Développement Desktop en C++ » pour Windows, Android Studio
pour Android.

```bash
tools/prepare_platforms.sh          # génère android/ et windows/ (modèle Flutter officiel)
cd app
flutter build windows --release --dart-define=SUPABASE_URL=https://xxx.supabase.co --dart-define=SUPABASE_ANON_KEY=eyJ...
flutter build apk --release        --dart-define=SUPABASE_URL=https://xxx.supabase.co --dart-define=SUPABASE_ANON_KEY=eyJ...
iscc installer\NothingNotes.iss     # installateur (Inno Setup 6, gratuit)
```

---

## 4. Installer les applications

### Windows 10 / 11

1. Téléchargez `NothingNotes-Setup-x.y.z.exe` depuis la page *Releases*.
2. Double-cliquez. **Aucun droit administrateur n'est demandé** : l'application
   s'installe dans `%LOCALAPPDATA%\Programs\Nothing Notes`, avec un raccourci
   dans le menu Démarrer (et sur le bureau si vous le cochez).
3. Windows SmartScreen peut afficher « Windows a protégé votre ordinateur »
   (installateur non signé par un certificat payant) : **Informations
   complémentaires → Exécuter quand même**.

**Mise à jour** : lancez simplement le nouvel installateur, il remplace
l'ancienne version et conserve vos notes. *Paramètres → Rechercher une mise à
jour* indique si une nouvelle version est publiée.

**Désinstallation** : *Paramètres Windows → Applications → Nothing Notes →
Désinstaller*, ou *Menu Démarrer → Nothing Notes → Désinstaller Nothing Notes*.
Le désinstalleur demande s'il faut **conserver ou effacer** les notes stockées
sur ce PC (`%APPDATA%\NothingNotes`). Les notes synchronisées restent sur votre
compte dans tous les cas.

### Android

1. Téléchargez l'APK sur le téléphone, ouvrez-le et autorisez l'installation
   depuis cette source si Android le demande.
2. Mise à jour : installez le nouvel APK par-dessus (même clé de signature).
3. Désinstallation : appui long sur l'icône → *Désinstaller* (efface les
   données locales du téléphone ; les notes synchronisées restent sur le compte).

---

## 5. Premier lancement

1. Ouvrez Nothing Notes sur le téléphone → **Créer un compte** (e-mail + mot de passe).
2. Ouvrez Nothing Notes sur le PC → **Se connecter** avec le même compte.
3. Écrivez une note sur le téléphone : elle apparaît sur le PC en une ou deux
   secondes (temps réel), et inversement. Hors ligne, tout reste utilisable ;
   les modifications partent automatiquement au retour du réseau.

L'icône de nuage indique l'état : synchronisé, synchronisation en cours, hors
ligne, modifications en attente, erreur, ou conflit à résoudre.
