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

**Depuis l'application** (à partir de la 3.1) : au démarrage, au plus une fois
par jour, Nothing Notes demande à GitHub s'il existe une version plus récente.
Rien n'est envoyé, et on peut désactiver cette vérification dans
*Paramètres → À propos*. Quand une version est disponible, un message propose
**Installer** ; on peut aussi passer par *Paramètres → Rechercher une mise à jour*.

1. La nouvelle version est téléchargée depuis les releases du dépôt uniquement.
   Sa taille et son empreinte SHA-256, publiées par GitHub, sont vérifiées.
2. Les notes ouvertes sont enregistrées, puis une **sauvegarde** est faite. Les 5
   dernières sont gardées dans *Sauvegardes*.
3. **Windows** : l'application se ferme, l'installateur remplace les fichiers
   sans rien demander, puis relance Nothing Notes.
   **Android** : l'installateur d'Android demande confirmation. La première fois,
   il faut autoriser Nothing Notes à installer des applications.
4. Au redémarrage, si la base de notes doit évoluer, la migration sûre
   s'applique (voir [MIGRATION-3.0.md](MIGRATION-3.0.md)).

La version portable (.zip) se met à jour à la main : l'application ouvre la
page de téléchargement.

**À la main** : installez la nouvelle version par-dessus l'ancienne, sur
Windows comme sur Android. Les notes et les associations sont conservées.

> **Android, une seule fois : passage de la 3.0 à la 3.1.** Jusqu'à la 3.0, les
> APK étaient signés avec une clé temporaire différente à chaque version. À
> partir de la 3.1, ils sont tous signés avec **la même clé**, et la CI refuse
> de publier un APK signé autrement : Android acceptera donc toutes les mises à
> jour suivantes par-dessus. Pour passer de la 3.0 à la 3.1, il faut encore
> désinstaller une dernière fois. Désinstaller efface les notes du téléphone :
> synchronisez d'abord avec le PC, puis suivez l'ordre décrit dans
> [MIGRATION-3.0.md](MIGRATION-3.0.md).

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

### Signature Android (obligatoire pour publier)

Les APK publiés sont signés avec une clé fixe. L'empreinte de son certificat
est enregistrée dans [`tools/android/signing-cert.sha256`](../tools/android/signing-cert.sha256).
Sur `main`, la CI **refuse de publier** un APK sans clé ou signé avec une autre
clé.

La clé n'est pas dans le dépôt : elle est fournie à GitHub par trois secrets
(*Settings → Secrets and variables → Actions*) :

* `ANDROID_KEYSTORE_BASE64` : le fichier `.jks` encodé en base64 ;
* `ANDROID_KEYSTORE_PASSWORD` : son mot de passe ;
* `ANDROID_KEY_ALIAS` : `nothingnotes`.

**Gardez une copie du fichier de clé en lieu sûr.** Si elle est perdue, Android
refusera toute mise à jour par-dessus : il faudrait désinstaller l'application
partout, avec le risque de perdre les notes du téléphone.
