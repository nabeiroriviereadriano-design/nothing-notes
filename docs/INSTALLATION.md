# Installation et association des appareils

Aucun compte, aucun serveur, aucune configuration en ligne : installez
l'application sur chaque appareil, puis associez-les une fois avec un code.

## 1. Installer

Téléchargez les fichiers depuis la page **[Releases](../../../releases/latest)**.

### Windows 10 / 11

1. Lancez `NothingNotes-Setup-x.y.z.exe`. **Aucun droit administrateur** n'est
   demandé : l'application s'installe dans `%LOCALAPPDATA%\Programs\Nothing Notes`.
2. Windows SmartScreen peut afficher « Windows a protégé votre ordinateur »
   (installateur non signé par un certificat payant) : **Informations
   complémentaires → Exécuter quand même**.
3. **Au premier lancement, le pare-feu Windows demande l'autorisation pour
   Nothing Notes : cochez « Réseaux privés » puis Autoriser.** Sans cela, le
   téléphone ne peut pas joindre le PC.

Version sans installation : `NothingNotes-x.y.z-portable.zip`.

### Android (7.0 et plus récent)

Téléchargez `NothingNotes-x.y.z.apk` sur le téléphone, ouvrez-le et autorisez
l'installation depuis cette source si Android le demande.

## 2. Associer le téléphone et le PC (une seule fois)

Les deux appareils doivent être **sur le même réseau** : même box Wi-Fi, PC
branché en Ethernet sur la même box, ou téléphone relié au PC par câble USB
avec le partage de connexion activé.

1. Sur le **PC** : *Paramètres → Appareils associés* (ou cliquez l'icône de
   synchronisation en bas à gauche) → **Afficher un code**. Un code à
   6 chiffres s'affiche (valable 5 minutes).
2. Sur le **téléphone** : *menu ⋮ → Appareils* → **Saisir un code** → tapez
   les 6 chiffres.
3. C'est fait : les notes des deux appareils se rejoignent. L'association est
   mémorisée, il n'y a plus jamais de code à saisir.

On peut aussi faire l'inverse (code affiché sur le téléphone, saisi sur le PC),
et associer autant d'appareils que voulu (tablette, deuxième PC…). Les
modifications circulent de proche en proche : un appareil associé au PC reçoit
aussi ce qui vient du téléphone.

**L'appareil n'est pas trouvé ?** Vérifiez que les deux sont sur le même réseau
et que Nothing Notes est ouvert des deux côtés. Sur le PC, autorisez Nothing
Notes dans le pare-feu (*Sécurité Windows → Pare-feu → Autoriser une
application*). Essayez aussi dans l'autre sens (code affiché sur le
téléphone). En dernier recours, dans la fenêtre « Saisir un code », touchez
*Saisir son adresse* et tapez l'adresse affichée sur l'autre appareil dans
*Appareils → Cet appareil*.

## 3. Au quotidien

* Écrivez sur un appareil : dès que les deux sont sur le même réseau avec
  l'application ouverte, la note apparaît sur l'autre en une à deux secondes.
* Sans réseau commun (dans le train, au travail…), tout reste utilisable. Les
  modifications attendent et partent **automatiquement** dès que les appareils
  se retrouvent.
* L'icône de synchronisation indique l'état : *synchronisé*, *synchronisation
  en cours*, *appareil hors de portée*, *modifications en attente*, *erreur*,
  *conflit à résoudre*, ou *aucun appareil associé*.
* Si la même note a été modifiée au même endroit sur les deux appareils
  pendant qu'ils étaient séparés, rien n'est écrasé : un bandeau propose de
  garder une version, l'autre, ou les deux.

## 4. Mettre à jour

Installez simplement la nouvelle version par-dessus l'ancienne (Windows et
Android) : notes et associations sont conservées. *Paramètres → Rechercher une
mise à jour* indique si une nouvelle version est publiée.

> Android : tant que le dépôt n'a pas de clé de signature fixe (voir plus bas),
> chaque APK publié est signé avec une clé différente et Android refuse la mise
> à jour par-dessus. Il faut alors désinstaller puis réinstaller, et refaire
> l'association ; les notes reviennent depuis le PC à la première synchronisation.

## 5. Désinstaller

* **Windows** : *Paramètres Windows → Applications → Nothing Notes →
  Désinstaller*, ou *Menu Démarrer → Nothing Notes → Désinstaller*. Le
  désinstalleur demande s'il faut **conserver ou effacer** les notes stockées
  sur ce PC (`%APPDATA%\NothingNotes`).
* **Android** : appui long sur l'icône → *Désinstaller* (efface les notes du
  téléphone ; celles déjà synchronisées restent sur le PC).

Pensez à retirer l'appareil désinstallé dans *Appareils* sur les autres.

## 6. Sauvegarde

Chaque appareil associé garde **une copie complète** de toutes les notes : la
perte d'un appareil ne fait rien perdre tant qu'un autre a été synchronisé.
Pour une copie supplémentaire : *Paramètres → Exporter toutes les notes*
(Markdown ou PDF).

## Pour le développeur

### Compiler soi-même

Prérequis : [Flutter](https://docs.flutter.dev/get-started/install) (canal
stable), Visual Studio 2022 « Développement Desktop en C++ » pour Windows,
Android Studio pour Android, [Inno Setup 6](https://jrsoftware.org/isinfo.php)
pour l'installateur.

```bash
tools/prepare_platforms.sh          # génère android/ et windows/ (modèle Flutter officiel)
cd app
flutter build windows --release
flutter build apk --release
cd .. && iscc installer\NothingNotes.iss
```

### Publier une version

Augmentez `version:` dans [`app/pubspec.yaml`](../app/pubspec.yaml) et envoyez
sur `main` : GitHub Actions compile, teste et publie la release automatiquement.

### Signature Android stable (recommandé)

```bash
keytool -genkeypair -v -keystore nothingnotes.jks -alias nothingnotes -keyalg RSA -keysize 4096 -validity 10000
base64 -w0 nothingnotes.jks > nothingnotes.jks.b64
```

Dans le dépôt GitHub : *Settings → Secrets and variables → Actions* → ajoutez
`ANDROID_KEYSTORE_BASE64` (contenu du `.b64`), `ANDROID_KEYSTORE_PASSWORD` et
`ANDROID_KEY_ALIAS` (`nothingnotes`). Conservez le fichier `.jks` en lieu sûr.
