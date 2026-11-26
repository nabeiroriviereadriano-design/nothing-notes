# Tests

Tous les tests tournent automatiquement dans GitHub Actions à chaque
modification (onglet **Actions**). Aucun résultat n'est annoncé sans avoir été
exécuté.

## 1. Synchronisation entre appareils — 26 / 26

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
| — | **3.0** | appareil en ancienne version : association **refusée**, rien n'est échangé ; appareil associé revenu à une ancienne version : synchro suspendue avec le message « Mettez à jour… », puis reprise après mise à jour ; sous-pages, base de données, propriétés, tâches (statut, échéance, priorité) et blocs repliables transmis intacts ; deux propriétés différentes modifiées hors ligne sur deux appareils → **les deux valeurs gardées**, sans conflit |

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

## 4. Fonctions 3.0 — 31 / 31

[`v3_test.dart`](../packages/notes_core/test/v3_test.dart) :

* **compatibilité** : une note ordinaire garde exactement la forme 2.0 ; les
  champs inconnus (note, contenu, blocs) sont conservés ; changer seulement une
  propriété, une icône ou le parent est bien enregistré ;
* **pages** : arborescence, fil d'Ariane, déplacement sans boucle, corbeille et
  restauration en cascade (sans toucher aux sous-pages supprimées avant),
  suppression définitive en cascade, duplication profonde, récents propres à
  l'appareil ;
* **liens** : rétroliens mis à jour et retirés, liens dans les blocs repliables
  et les tableaux, recherche de page pour une mention ;
* **modèles** : les 7 modèles intégrés ; appliquer un modèle **n'écrase jamais**
  le contenu ; page vide remplie ; modèle personnalisé hors des listes et de la
  recherche ;
* **tâches** : suivi sans doublon, statut, échéance, priorité, filtres (dont en
  retard), case ⇔ terminée, tâche en corbeille masquée ;
* **bases** : propriétés de chaque type, tri (vides à la fin), filtres nombre,
  statut, case et date, recherche dans les propriétés, retirer une propriété
  garde les valeurs, champs inconnus du schéma conservés ;
* **import Markdown** : éléments courants, aller-retour export → import, import
  sans modifier l'existant, texte partagé ;
* **export** : Titre 3, blocs repliables, liens internes et propriétés en
  Markdown, HTML et TXT ;
* **fusion** : propriétés différentes fusionnées, même propriété → conflit,
  parent d'un côté et titre de l'autre → les deux gardés.

## 5. Migration et sauvegardes — 7 / 7

[`migration_test.dart`](../packages/notes_core/test/migration_test.dart) :

* **base produite par le vrai code de la version 2.0.0** : générée en CI par
  [`tool/v2_fixture.dart`](../packages/notes_core/tool/v2_fixture.dart) dans
  une copie de travail de la 2.0.0 (12 notes avec tous les types de blocs, 12
  pièces jointes, note purgée, corbeille, historique, appareil associé, conflit
  en attente), puis migrée : empreinte identique, tout est retrouvé et
  modifiable, une note 2.0 modifiée en 3.0 garde sa forme ;
* sauvegarde vérifiée créée **avant**, données identiques **après**, liens indexés ;
* base déjà à jour : pas de sauvegarde inutile ; première installation ;
* **échec forcé pendant la migration** → base d'origine remise en place ;
* **base endommagée** → aucune migration, fichier non modifié ;
* sauvegarder, modifier, restaurer → retour exact ; l'état remplacé reste
  récupérable ; le journal de synchronisation ne recule jamais ; les
  sauvegardes manuelles ne sont jamais supprimées.

En plus, hors CI (données privées, jamais publiées) : migration rejouée sur la
**copie réelle de votre base** → empreinte identique (12 notes, 19 pièces
jointes, 76 versions d'historique…), et relecture/réécriture des 34 lignes et
360 blocs par les modèles 3.0 → identiques.

**Total du noyau : 105 / 105.**

## 6. Applications

| Vérification | Résultat |
|---|---|
| Analyse statique | aucune erreur ni avertissement (remarques d'information : API de Flutter signalées comme dépréciées par la dernière version) |
| Interface bureau (1440×900) : trois colonnes, saisie, `[] ` → cases à cocher, Entrée → bloc suivant, gras, enregistrement local, nouvelle note | réussi |
| Interface téléphone (400×860) : liste, ouverture d'une note, retour, recherche instantanée | réussi |
| Pages : sous-page absente de la liste principale, fil d'Ariane, « Mentionnée dans », navigation parent ↔ sous-page | réussi |
| `/` dans un bloc vide → menu → Titre 3 (le `/` est retiré) | réussi |
| **L'éditeur ouvert ne réécrit jamais un champ modifié ailleurs** (parent, icône, propriété), puis saisie | réussi |
| Base de données : tableau, valeur de statut affichée, nouvelle entrée ouverte avec ses propriétés | réussi |
| Vue Tâches : tâches ouvertes par défaut, case non suivie absente, filtre « Terminées » | réussi |
| Téléphone : bouton + → modèle « Réunion » → page créée avec sa structure | réussi |
| Mise à jour : comparaison des versions, choix de l'APK ou de l'installateur (jamais le .zip), refus d'un fichier hébergé hors des releases du dépôt, empreinte SHA-256 lue, nouveautés extraites | réussi |
| **Windows, mise à jour réelle** (CI, sur l'installateur compilé) : application installée et ouverte → installateur silencieux `/RELAUNCH=1` lancé comme le fait l'application → ancienne instance fermée, fichiers remplacés, **application relancée**, base de notes conservée | réussi |
| Android : la CI refuse de publier un APK sans la clé fixe, ou signé avec un autre certificat que celui enregistré dans le dépôt | vérifié à la publication |
| Compilation de l'APK Android | réussie |
| Compilation Windows (exécutable natif) | réussie |
| L'exécutable Windows démarre et reste ouvert 12 s sans erreur | réussi |
| Installation silencieuse sans droits administrateur, puis désinstallation | réussi |
| Captures d'écran réelles (polices et icônes chargées), publiées sur la branche `captures` | générées |

## 7. Ce qui n'est pas testé automatiquement

* **Un vrai téléphone et un vrai PC sur un vrai réseau.** Les tests passent par
  la boucle locale d'une seule machine. Ils ne couvrent ni le Wi-Fi de votre
  box, ni l'isolement des appareils que certaines box ou réseaux invités
  imposent, ni le pare-feu Windows, ni l'économie d'énergie d'Android.
* La recherche de l'autre appareil par balayage du sous-réseau (désactivée
  dans les tests).
* Le sélecteur de fichiers du système (import Markdown, pièces jointes) et l'export PDF.
* Le partage Android et l'installation d'une mise à jour sur Android (canal natif) : compilés, mais pas exécutés sur un téléphone.
* Le glisser-déposer des blocs, à la souris comme au doigt.
* L'affichage des emojis d'icône de page (dépend des polices du système).

À faire une fois après installation (5 minutes) : associer le téléphone et le
PC, écrire une note sur le téléphone et la voir sur le PC, la modifier sur le
PC, puis recommencer avec le téléphone en mode avion.

## Lancer les tests soi-même

```bash
cd packages/notes_core && dart pub get && dart test --concurrency=1
cd app && flutter test
```
