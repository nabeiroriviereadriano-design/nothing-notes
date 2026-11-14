import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:notes_core/notes_core.dart';
import 'package:test/test.dart';

import 'harness.dart';

/// Les scénarios du cahier des charges (§14), exécutés à l'identique contre
/// le serveur simulé et contre un vrai backend Supabase.
///
/// « android » et « windows » sont deux appareils indépendants : chacun a sa
/// propre base SQLite, sa propre session et son propre moteur de
/// synchronisation — exactement le code embarqué dans les applications.
void defineScenarios(Backend Function() makeBackend) {
  late Backend backend;
  final devices = <Device>[];

  Future<Device> device(String name, {String account = 'alice', int pageSize = 500}) async {
    final d = await Device.create(name, await backend.connect(account), pageSize: pageSize);
    devices.add(d);
    return d;
  }

  setUp(() => backend = makeBackend());
  tearDown(() async {
    for (final d in devices) {
      await d.close();
    }
    devices.clear();
    await backend.close();
  });

  Note edit(Device d, String title, void Function(Note n) change) {
    final n = d.byTitle(title);
    change(n);
    d.repo.saveNote(n);
    return n;
  }

  test('Test 1 — création sur Android, apparition sur Windows', () async {
    final android = await device('android'), windows = await device('windows');
    android.repo.createNote(title: 'BTS Électrotechnique', blocks: [
      Block(type: BlockType.todo, text: 'Réviser les schémas de commande'),
      Block(type: BlockType.todo, text: 'Exercices Grafcet', checked: true),
    ]);
    expect(android.engine.status.pending, 1);
    await android.sync();
    expect(android.engine.status.state, SyncState.synced);
    await windows.sync();

    final n = windows.byTitle('BTS Électrotechnique');
    expect(n.blocks.map((b) => b.text), ['Réviser les schémas de commande', 'Exercices Grafcet']);
    expect(n.blocks[1].checked, isTrue);
    expect(n.dirty, isFalse);
    expect(n.version, 1);
  });

  test('Test 2 — modification sur Windows, actualisation sur Android', () async {
    final android = await device('android'), windows = await device('windows');
    android.repo.createNote(title: 'Liste d\'achats', blocks: [Block(text: 'Bois')]);
    await android.sync();
    await windows.sync();

    edit(windows, 'Liste d\'achats', (n) {
      n.title = 'Liste d\'achats (atelier)';
      n.blocks.add(Block(text: 'Vis'));
      n.favorite = true;
    });
    await windows.sync();
    await android.sync();

    final n = android.byTitle('Liste d\'achats (atelier)');
    expect(n.blocks.map((b) => b.text), ['Bois', 'Vis']);
    expect(n.favorite, isTrue);
    expect(n.version, 2);
    expect(android.repo.allNotes(), hasLength(1));
  });

  test('Test 3 — création hors ligne puis synchronisation au retour du réseau', () async {
    final android = await device('android'), windows = await device('windows');
    android.net.online = false;
    android.repo.createNote(title: 'Idée dans le métro', blocks: [Block(text: 'Haptique')]);
    final f = android.repo.createFolder('Projets');
    android.repo.moveToFolder(android.byTitle('Idée dans le métro').id, f.id);
    await android.sync();
    expect(android.engine.status.state, SyncState.offline);
    expect(android.engine.status.pending, 2, reason: 'note + dossier en file d\'attente');
    expect(android.byTitle('Idée dans le métro').dirty, isTrue);

    // L'application est fermée puis rouverte, toujours sans réseau :
    // la file d'attente est persistante.
    await android.restart();
    android.net.online = false;
    expect(android.store.pendingCount, 2);
    expect(android.maybeByTitle('Idée dans le métro'), isNotNull);

    await windows.sync();
    expect(windows.repo.allNotes(), isEmpty);

    android.net.online = true;
    await android.sync();
    expect(android.engine.status.state, SyncState.synced);
    expect(android.store.pendingCount, 0);
    await windows.sync();
    final n = windows.byTitle('Idée dans le métro');
    expect(windows.repo.folders().single.name, 'Projets');
    expect(n.folderId, windows.repo.folders().single.id);
  });

  group('Test 4 — modifications simultanées hors ligne', () {
    test('blocs différents : fusion automatique, rien n\'est perdu', () async {
      final android = await device('android'), windows = await device('windows');
      android.repo.createNote(title: 'Révisions', blocks: [
        Block(id: 'b1', type: BlockType.todo, text: 'Schémas'),
        Block(id: 'b2', type: BlockType.todo, text: 'Grafcet'),
      ]);
      await android.sync();
      await windows.sync();

      android.net.online = false;
      windows.net.online = false;
      edit(android, 'Révisions', (n) => n.blocks[0].checked = true);
      edit(windows, 'Révisions', (n) {
        n.blocks[1].text = 'Grafcet (chap. 3)';
        n.blocks.add(Block(id: 'b3', type: BlockType.todo, text: 'TIA Portal'));
      });
      android.net.online = true;
      windows.net.online = true;
      await android.sync();
      await windows.sync();
      await android.sync();

      for (final d in [android, windows]) {
        final n = d.byTitle('Révisions');
        expect(n.hasConflict, isFalse, reason: d.name);
        expect(n.blocks.map((b) => b.text), ['Schémas', 'Grafcet (chap. 3)', 'TIA Portal'], reason: d.name);
        expect(n.blocks[0].checked, isTrue, reason: d.name);
        expect(n.dirty, isFalse, reason: d.name);
      }
    });

    test('même paragraphe : conflit détecté, aucune version écrasée, les deux conservées', () async {
      final android = await device('android'), windows = await device('windows');
      android.repo.createNote(title: 'Compte rendu', blocks: [Block(id: 'b1', text: 'Version initiale')]);
      await android.sync();
      await windows.sync();

      android.net.online = false;
      windows.net.online = false;
      edit(android, 'Compte rendu', (n) => n.blocks[0].text = 'Version du téléphone');
      edit(windows, 'Compte rendu', (n) => n.blocks[0].text = 'Version du PC');
      android.net.online = true;
      windows.net.online = true;

      await windows.sync(); // le PC arrive en premier
      await android.sync(); // le téléphone découvre le conflit

      final conflicted = android.byTitle('Compte rendu');
      expect(conflicted.hasConflict, isTrue);
      expect(conflicted.blocks[0].text, 'Version du téléphone', reason: 'la version locale reste intacte');
      expect(Note.fromRow(conflicted.conflictRow!).blocks[0].text, 'Version du PC');
      expect(android.engine.status.conflicts, 1);

      // Le serveur n'a pas été écrasé :
      await windows.sync();
      expect(windows.byTitle('Compte rendu').blocks[0].text, 'Version du PC');

      // L'utilisateur choisit de garder les deux.
      await android.repo.resolveConflict(conflicted.id, ConflictChoice.keepBoth);
      await android.sync();
      await windows.sync();
      for (final d in [android, windows]) {
        expect(d.byTitle('Compte rendu').blocks[0].text, 'Version du PC', reason: d.name);
        expect(d.byTitle('Compte rendu (ma version)').blocks[0].text, 'Version du téléphone', reason: d.name);
        expect(d.repo.allNotes().where((n) => n.hasConflict), isEmpty, reason: d.name);
      }
    });

    test('« garder ma version » : l\'autre version reste dans l\'historique', () async {
      final android = await device('android'), windows = await device('windows');
      android.repo.createNote(title: 'Titre commun', blocks: [Block(id: 'b1', text: 'texte')]);
      await android.sync();
      await windows.sync();

      android.net.online = false;
      edit(android, 'Titre commun', (n) => n.title = 'Titre du téléphone');
      edit(windows, 'Titre commun', (n) => n.title = 'Titre du PC');
      await windows.sync();
      android.net.online = true;
      await android.sync();

      final c = android.byTitle('Titre du téléphone');
      expect(c.hasConflict, isTrue);
      await android.repo.resolveConflict(c.id, ConflictChoice.keepMine);
      await android.sync();
      await windows.sync();
      expect(windows.maybeByTitle('Titre du téléphone'), isNotNull);
      expect(windows.maybeByTitle('Titre du PC'), isNull);

      final history = await windows.repo.history(c.id);
      expect(history.map((v) => v.title), contains('Titre du PC'));
    });

    test('modification pendant que l\'autre appareil met la note à la corbeille', () async {
      final android = await device('android'), windows = await device('windows');
      android.repo.createNote(title: 'Brouillon', blocks: [Block(id: 'b1', text: 'a')]);
      await android.sync();
      await windows.sync();
      windows.repo.trashNote(windows.byTitle('Brouillon').id);
      edit(android, 'Brouillon', (n) => n.blocks[0].text = 'a + suite importante');
      await windows.sync();
      await android.sync();
      await windows.sync();
      for (final d in [android, windows]) {
        final n = d.byTitle('Brouillon');
        expect(n.blocks[0].text, 'a + suite importante', reason: 'le texte ajouté est conservé (${d.name})');
        expect(n.trashed, isTrue, reason: 'récupérable depuis la corbeille (${d.name})');
      }
    });
  });

  test('Test 5 — suppression propagée (corbeille puis suppression définitive)', () async {
    final android = await device('android'), windows = await device('windows');
    android.repo.createNote(title: 'À jeter');
    android.repo.createNote(title: 'À garder');
    await android.sync();
    await windows.sync();

    windows.repo.trashNote(windows.byTitle('À jeter').id);
    await windows.sync();
    await android.sync();
    expect(android.byTitle('À jeter').trashed, isTrue);

    android.repo.restoreNote(android.byTitle('À jeter').id);
    await android.sync();
    await windows.sync();
    expect(windows.byTitle('À jeter').trashed, isFalse, reason: 'restauration propagée');

    windows.repo.trashNote(windows.byTitle('À jeter').id);
    windows.repo.emptyTrash();
    await windows.sync();
    await android.sync();
    expect(android.maybeByTitle('À jeter'), isNull, reason: 'suppression définitive propagée');
    expect(android.repo.allNotes().map((n) => n.title), ['À garder']);
    expect(android.repo.search('jeter'), isEmpty);
  });

  test('Test 6 — image ajoutée sur Android, disponible sur Windows', () async {
    final android = await device('android'), windows = await device('windows');
    final note = android.repo.createNote(title: 'Schéma KM1');
    final bytes = fakePng(48 * 1024);
    final att = android.repo.addAttachment(note.id, fileName: 'schéma câblage.png', bytes: bytes);
    edit(android, 'Schéma KM1', (n) => n.blocks.add(Block(type: BlockType.image, attachmentId: att.id)));
    await android.sync();
    expect(android.store.localFile(att.id)!.uploaded, isTrue);
    await windows.sync();

    final w = windows.byTitle('Schéma KM1');
    final imageBlock = w.blocks.firstWhere((b) => b.type == BlockType.image);
    final path = windows.repo.localPath(imageBlock.attachmentId!);
    expect(path, isNotNull, reason: 'image téléchargée automatiquement');
    final got = File(path!).readAsBytesSync();
    expect(crypto.sha256.convert(got).toString(), crypto.sha256.convert(bytes).toString());
    expect(windows.repo.attachmentsOf(w.id).single.fileName, 'schéma câblage.png');

    // Suppression de la pièce jointe propagée, fichier distant supprimé.
    windows.repo.deleteAttachment(att.id);
    await windows.sync();
    await android.sync();
    expect(android.repo.attachmentsOf(note.id), isEmpty);
    expect(android.repo.localPath(att.id), isNull);
    await expectLater(android.net.downloadFile(att.storagePath!), throwsA(isA<RemoteError>()));
  });

  test('Test 7 — redémarrage des deux applications, données conservées', () async {
    final android = await device('android'), windows = await device('windows');
    android.repo.createNote(title: 'Persistante', blocks: [Block(text: 'contenu')]);
    final tag = android.repo.createTag('Travail', color: '#E60012');
    android.repo.setTags(android.byTitle('Persistante').id, [tag.id]);
    await android.sync();
    await windows.sync();

    await android.restart();
    await windows.restart();
    for (final d in [android, windows]) {
      final n = d.byTitle('Persistante');
      expect(n.blocks.single.text, 'contenu', reason: d.name);
      expect(d.repo.tags().single.name, 'Travail', reason: d.name);
      expect(n.tags, [d.repo.tags().single.id], reason: d.name);
    }
    // Après redémarrage, la synchro reprend au curseur : rien n'est retéléchargé.
    final before = windows.net.pullCount;
    await windows.sync();
    expect(windows.net.pullCount - before, EntityType.values.length, reason: 'une requête vide par table');
    expect(windows.repo.allNotes(), hasLength(1));
  });

  test('Test 8 — plusieurs appareils sur le même compte restent cohérents', () async {
    final a = await device('android'), w = await device('windows'), t = await device('tablette');
    for (var i = 0; i < 4; i++) {
      a.repo.createNote(title: 'A$i', blocks: [Block(text: 'depuis android')]);
      w.repo.createNote(title: 'W$i', blocks: [Block(text: 'depuis windows')]);
      t.repo.createNote(title: 'T$i', blocks: [Block(text: 'depuis tablette')]);
    }
    final travail = w.repo.createTag('Travail');
    w.repo.setTags(w.byTitle('W0').id, [travail.id]);
    for (final d in [a, w, t, a, w, t]) {
      await d.sync();
    }
    edit(a, 'W1', (n) => n.blocks.add(Block(text: 'ajout android')));
    edit(t, 'A2', (n) => n.favorite = true);
    w.repo.trashNote(w.byTitle('T3').id);
    for (final d in [a, w, t, a, w, t]) {
      await d.sync();
    }

    String snapshot(Device d) {
      final notes = d.repo.allNotes()..sort((x, y) => x.title.compareTo(y.title));
      return notes
          .map((n) => '${n.title}|v${n.version}|${n.favorite}|${n.trashed}|${n.tags.length}|'
              '${n.blocks.map((b) => b.text).join(',')}')
          .join('\n');
    }

    expect(a.repo.allNotes(), hasLength(12));
    expect(snapshot(w), snapshot(a));
    expect(snapshot(t), snapshot(a));
    expect(t.byTitle('W1').blocks.map((b) => b.text), ['depuis windows', 'ajout android']);
    expect(w.byTitle('A2').favorite, isTrue);
    expect(a.byTitle('T3').trashed, isTrue);
    for (final d in [a, w, t]) {
      expect(d.store.pendingCount, 0, reason: d.name);
      expect(d.store.conflictCount, 0, reason: d.name);
    }
  });

  test('Test 9 — un compte ne peut ni lire ni modifier les notes d\'un autre', () async {
    final alice = await device('alice-android');
    final bob = await device('bob-windows', account: 'bob');
    final secret = alice.repo.createNote(title: 'Secret d\'Alice', blocks: [Block(text: 'confidentiel')]);
    final att = alice.repo.addAttachment(secret.id, fileName: 'privé.png', bytes: fakePng(2048));
    await alice.sync();

    await bob.sync();
    expect(bob.repo.allNotes(), isEmpty, reason: 'Bob ne reçoit pas les notes d\'Alice');
    expect(await bob.net.pull(EntityType.notes, 0, 100), isEmpty);
    expect(await bob.net.pull(EntityType.attachments, 0, 100), isEmpty);
    expect(await bob.net.noteHistory(secret.id), isEmpty);

    // Bob tente d'écraser la note d'Alice en réutilisant son identifiant.
    final forged = Note(id: secret.id, title: 'piraté').toRow();
    await expectLater(bob.net.push(EntityType.notes, forged, 1, newId()), throwsA(isA<RemoteError>()));
    await expectLater(bob.net.push(EntityType.notes, forged, 0, newId()), throwsA(isA<RemoteError>()));
    // ... et de lire ou d'écraser son fichier.
    await expectLater(bob.net.downloadFile(att.storagePath!), throwsA(isA<RemoteError>()));
    await expectLater(
        bob.net.uploadFile(att.storagePath!, fakePng(16), 'image/png'), throwsA(isA<RemoteError>()));

    await alice.sync();
    expect(alice.byTitle('Secret d\'Alice').blocks.single.text, 'confidentiel');
    expect(alice.byTitle('Secret d\'Alice').version, 1, reason: 'aucune écriture étrangère');
  });

  group('Robustesse de la synchronisation', () {
    test('réponse perdue : l\'opération renvoyée n\'est pas appliquée deux fois', () async {
      final android = await device('android'), windows = await device('windows');
      android.net.dropNextPushResponse = true;
      android.repo.createNote(title: 'Une seule fois', blocks: [Block(text: 'x')]);
      await android.sync();
      expect(android.engine.status.state, SyncState.offline);
      expect(android.store.pendingCount, 1);
      await android.sync();
      expect(android.engine.status.state, SyncState.synced);
      await windows.sync();
      expect(windows.repo.allNotes(), hasLength(1));
      expect(windows.byTitle('Une seule fois').version, 1, reason: 'pas de double application');
      expect(android.byTitle('Une seule fois').dirty, isFalse);
    });

    test('réponse perdue puis nouvelle modification locale', () async {
      final android = await device('android'), windows = await device('windows');
      android.repo.createNote(title: 'Note', blocks: [Block(id: 'b1', text: 'un')]);
      await android.sync();
      android.net.dropNextPushResponse = true;
      edit(android, 'Note', (n) => n.blocks.add(Block(id: 'b2', text: 'deux')));
      await android.sync();
      edit(android, 'Note', (n) => n.blocks.add(Block(id: 'b3', text: 'trois')));
      await android.sync();
      await windows.sync();
      expect(windows.byTitle('Note').blocks.map((b) => b.text), ['un', 'deux', 'trois']);
      expect(android.byTitle('Note').hasConflict, isFalse);
      expect(android.store.pendingCount, 0);
    });

    test('pagination et reprise après interruption', () async {
      final android = await device('android');
      for (var i = 0; i < 7; i++) {
        android.repo.createNote(title: 'N$i');
      }
      await android.sync();

      final windows = await device('windows', pageSize: 3);
      windows.net.pullsBeforeCut = 3; // dossiers, étiquettes, 1re page de notes puis coupure
      await windows.sync();
      expect(windows.engine.status.state, SyncState.offline);
      expect(windows.repo.allNotes(), hasLength(3), reason: 'première page conservée');
      expect(windows.store.cursor(EntityType.notes), greaterThan(0), reason: 'curseur sauvegardé');

      windows.net.pullsBeforeCut = null;
      final before = windows.net.pullCount;
      await windows.sync();
      expect(windows.repo.allNotes(), hasLength(7));
      // reprise au curseur : 2 tables vides + notes (3 + 1) + pièces jointes
      expect(windows.net.pullCount - before, 5, reason: 'la première page n\'est pas retéléchargée');
    });

    test('dossiers, sous-dossiers et étiquettes synchronisés', () async {
      final android = await device('android'), windows = await device('windows');
      final bts = android.repo.createFolder('BTS');
      final auto = android.repo.createFolder('Automatisme', parentId: bts.id);
      final tag = android.repo.createTag('Perso', color: '#858585');
      android.repo.createNote(title: 'Grafcet', folderId: auto.id, tags: [tag.id]);
      await android.sync();
      await windows.sync();
      expect(windows.repo.folders().map((f) => f.name), containsAll(['BTS', 'Automatisme']));
      expect(windows.repo.folderSubtree(bts.id), {bts.id, auto.id});
      expect(windows.repo.search('perso').single.title, 'Grafcet', reason: 'recherche par étiquette');
      expect(windows.repo.search('automat').single.title, 'Grafcet', reason: 'recherche par dossier');

      windows.repo.deleteTag(tag.id);
      windows.repo.deleteFolder(bts.id);
      await windows.sync();
      await android.sync();
      expect(android.repo.tags(), isEmpty);
      expect(android.repo.folders(), isEmpty);
      final n = android.byTitle('Grafcet');
      expect(n.tags, isEmpty);
      expect(n.folderId, isNull, reason: 'la note revient à la racine, elle n\'est pas supprimée');
    });

    test('modification juste après le lancement d\'une synchronisation : rien n\'est perdu', () async {
      final android = await device('android'), windows = await device('windows');
      android.repo.createNote(title: 'Frappe rapide', blocks: [Block(id: 'b1', text: 'a')]);
      final syncing = android.sync();
      edit(android, 'Frappe rapide', (n) => n.blocks[0].text = 'ab');
      await syncing;
      await android.sync();
      await windows.sync();
      expect(windows.byTitle('Frappe rapide').blocks[0].text, 'ab');
      expect(android.store.pendingCount, 0);
    });
  });
}
