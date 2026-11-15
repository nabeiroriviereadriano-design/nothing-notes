# Tests

Tous les tests tournent automatiquement dans GitHub Actions à chaque
modification (onglet **Actions**). Aucun résultat n'est annoncé sans avoir été
exécuté.

## 1. Synchronisation entre appareils — 22 / 22

Fichier [`packages/notes_core/test/lan_test.dart`](../packages/notes_core/test/lan_test.dart).
Chaque « appareil » a sa propre base SQLite sur disque, son propre dossier de
fichiers, ses propres clés et un vrai nœud réseau. Les appareils se
connectent par de **vraies connexions TCP chiffrées** (et par de vraies
annonces UDP pour la découverte) sur la boucle locale. C'est exactement le code
embarqué dans les applications.

| # | Scénario du cahier des charges | Ce qui est vérifié |
|---|---|---|
| — | Association | code correct → les deux appareils se reconnaissent et partagent la même clé ; appareil trouvé automatiquement par les annonces UDP ; code faux refusé et **code annulé à la 3e tentative** ; code expiré refusé ; format invalide refusé |
| 1 | Création | note créée sur « Android » → présente sur « Windows » avec ses cases cochées |
| 2 | Modification | titre, contenu et favori modifiés sur « Windows » → à jour sur « Android » |
| 3 | Hors ligne | note + dossier créés sans réseau, application **redémarrée** sans réseau (rien n'est perdu, rien n'est parti), puis envoyés automatiquement au retour du réseau |
| 4 | Modifications simultanées | blocs différents → fusion automatique ; même paragraphe → conflit détecté, aucune version écrasée, « garder les deux » ; « garder ma version » → l'autre reste dans l'historique ; modification contre mise à la corbeille → texte conservé |
| 5 | Suppression | corbeille, restauration et suppression définitive propagées (et retirées de la recherche) |
| 6 | Pièces jointes | image de 700 Ko (plusieurs morceaux) transférée et **identique au SHA-256 près** ; fichier dans l'autre sens ; suppression propagée |
| 7 | Redémarrage | les deux applications redémarrent : notes, étiquettes et association conservées, reconnexion automatique, synchronisation qui continue |
| 8 | Plusieurs appareils | téléphone ↔ PC ↔ tablette : 12 notes, modifications croisées → mêmes données partout, sans conflit |
| 9 | Sécurité | un appareil non associé est refusé, même en **usurpant l'identifiant** d'un appareil associé ; un appareil retiré ne peut plus se synchroniser |
| — | Robustesse | 450 notes reçues par pages ; dossiers, sous-dossiers et étiquettes ; saisie continue pendant la synchronisation ; état « hors de portée » puis retour |

## 2. Cryptographie et canal — 13 / 13

[`crypto_test.dart`](../packages/notes_core/test/crypto_test.dart) :

* le groupe de la RFC 3526 est bien un **nombre premier sûr** (p et (p−1)/2
  premiers, test de Miller-Rabin) ;
* même code → même clé des deux côtés ; code différent → clés différentes ;
  nouvelles clés à chaque session ; valeurs publiques piégées refusées ;
* trames reconstituées quel que soit le découpage TCP ; trame trop grande refusée ;
* messages chiffrés dans l'ordre ; **mauvaise clé, message modifié ou rejoué
  refusés** (connexion coupée) ;
* requêtes, réponses, erreurs et transferts binaires de 300 Ko.

## 3. Logique des notes — 28 / 28

Fusion à trois voies (16 tests : blocs, ordre, étiquettes, suppression,
décision **indépendante de l'heure de modification**), base locale, recherche
sans accents et par préfixe, corbeille de 30 jours, mise en forme, exports
Markdown / TXT / HTML.

**Total du noyau : 63 / 63.**

## 4. Applications

| Vérification | Résultat |
|---|---|
| Analyse statique | aucune erreur ni avertissement (remarques d'information : API de Flutter signalées comme dépréciées par la dernière version) |
| Interface bureau (1440×900) : trois colonnes, saisie, `[] ` → cases à cocher, Entrée → bloc suivant, gras, enregistrement local, nouvelle note | réussi |
| Interface téléphone (400×860) : liste, ouverture d'une note, retour, recherche instantanée | réussi |
| Compilation de l'APK Android | réussie |
| Compilation Windows (exécutable natif) | réussie |
| L'exécutable Windows démarre et reste ouvert 12 s sans erreur | réussi |
| Installation silencieuse sans droits administrateur, puis désinstallation | réussi |
| Captures d'écran réelles (polices et icônes chargées), publiées sur la branche `captures` | générées |

## 5. Ce qui n'est pas testé automatiquement

* **Un vrai téléphone et un vrai PC sur un vrai réseau.** Les tests passent par
  la boucle locale d'une seule machine. Ils ne couvrent ni le Wi-Fi de votre
  box, ni l'isolement des appareils que certaines box ou réseaux invités
  imposent, ni le pare-feu Windows, ni l'économie d'énergie d'Android.
* La recherche de l'autre appareil par balayage du sous-réseau (désactivée
  dans les tests).
* Le sélecteur de fichiers du système et l'export PDF.

À faire une fois après installation (5 minutes) : associer le téléphone et le
PC, écrire une note sur le téléphone et la voir sur le PC, la modifier sur le
PC, puis recommencer avec le téléphone en mode avion.

## Lancer les tests soi-même

```bash
cd packages/notes_core && dart pub get && dart test --concurrency=1
cd app && flutter test
```
