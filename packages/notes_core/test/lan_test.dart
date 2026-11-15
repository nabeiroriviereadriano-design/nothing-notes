@Timeout(Duration(minutes: 2))
library;

import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:notes_core/notes_core.dart';
import 'package:test/test.dart';

import 'lan_harness.dart';

/// Les scénarios du cahier des charges (§14), avec la synchronisation
/// directe entre appareils : vraies connexions TCP chiffrées sur la boucle
/// locale, bases SQLite séparées, appairage par code.
void main() {
  final devices = <Device>[];
  Future<Device> device(String name, {int udpPort = 0, List<(String, int)> udpTargets = const []}) async {
    final d = await Device.create(name, udpPort: udpPort, udpTargets: udpTargets);
    devices.add(d);
    return d;
  }

  tearDown(() async {
    for (final d in devices) {
      await d.close();
    }
    devices.clear();
  });

  Note edit(Device d, String title, void Function(Note n) change) {
    final n = d.byTitle(title);
    change(n);
    d.repo.saveNote(n);
    return n;
  }

  group('Association par code', () {
    test('code correct : les deux appareils se reconnaissent', () async {
      final pc = await device('PC'), phone = await device('Téléphone');
      expect(phone.node.status.state, SyncState.unpaired);
      final code = pc.node.startPairing();
      expect(code, matches(RegExp(r'^\d{6}$')));
      final peer = await phone.node.joinWithCode(code, address: pc.address);
      expect(peer.name, 'PC');
      await waitFor(() => pc.store.peers().length == 1, 'PC enregistre le téléphone');
      expect(pc.store.peers().single.name, 'Téléphone');
      expect(pc.node.pairingCode, isNull, reason: 'le code ne sert qu\'une fois');
      expect(await pc.keys.read(phone.store.deviceId), await phone.keys.read(pc.store.deviceId),
          reason: 'même clé d\'association des deux côtés');
    });

    test('appareil trouvé automatiquement sur le réseau (annonces UDP)', () async {
      final a = freeUdpPort(), b = a + 1;
      final pc = await device('PC', udpPort: a, udpTargets: [('127.0.0.1', b)]);
      final phone = await device('Téléphone', udpPort: b, udpTargets: [('127.0.0.1', a)]);
      final code = pc.node.startPairing();
      final peer = await phone.node.joinWithCode(code);
      expect(peer.name, 'PC');
    });

    test('code faux refusé ; après 3 essais le code est annulé', () async {
      final pc = await device('PC'), intrus = await device('Intrus');
      final code = pc.node.startPairing();
      final wrong = code == '000000' ? '111111' : '000000';
      for (var i = 0; i < 3; i++) {
        await expectLater(intrus.node.joinWithCode(wrong, address: pc.address),
            throwsA(isA<PairingError>().having((e) => e.code, 'code', 'badcode')));
      }
      expect(pc.node.pairingCode, isNull, reason: 'code annulé après 3 échecs');
      await expectLater(intrus.node.joinWithCode(code, address: pc.address), throwsA(isA<PairingError>()),
          reason: 'même le bon code ne marche plus');
      expect(pc.store.peers(), isEmpty);
      expect(intrus.store.peers(), isEmpty);
    });

    test('code expiré refusé', () async {
      final pc = await device('PC'), phone = await device('Téléphone');
      final code = pc.node.startPairing(validity: const Duration(milliseconds: 200));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await expectLater(phone.node.joinWithCode(code, address: pc.address), throwsA(isA<PairingError>()));
    });

    test('format de code invalide', () async {
      final phone = await device('Téléphone');
      await expectLater(phone.node.joinWithCode('12ab'), throwsA(isA<PairingError>().having((e) => e.code, 'code', 'format')));
    });
  });

  test('Test 1 — création sur Android, apparition sur Windows', () async {
    final windows = await device('Windows'), android = await device('Android');
    await android.pairWith(windows);
    android.repo.createNote(title: 'BTS Électrotechnique', blocks: [
      Block(type: BlockType.todo, text: 'Réviser les schémas de commande'),
      Block(type: BlockType.todo, text: 'Exercices Grafcet', checked: true),
    ]);
    await waitFor(() => windows.maybeByTitle('BTS Électrotechnique') != null, 'note reçue sur Windows');
    final n = windows.byTitle('BTS Électrotechnique');
    expect(n.blocks.map((b) => b.text), ['Réviser les schémas de commande', 'Exercices Grafcet']);
    expect(n.blocks[1].checked, isTrue);
    await waitConverged([android, windows]);
    expect(android.node.status.state, SyncState.synced);
  });

  test('Test 2 — modification sur Windows, actualisation sur Android', () async {
    final windows = await device('Windows'), android = await device('Android');
    await android.pairWith(windows);
    android.repo.createNote(title: 'Liste d\'achats', blocks: [Block(text: 'Bois')]);
    await waitFor(() => windows.maybeByTitle('Liste d\'achats') != null, 'note reçue');
    edit(windows, 'Liste d\'achats', (n) {
      n.title = 'Liste d\'achats (atelier)';
      n.blocks.add(Block(text: 'Vis'));
      n.favorite = true;
    });
    await waitFor(() => android.maybeByTitle('Liste d\'achats (atelier)') != null, 'modification reçue');
    final n = android.byTitle('Liste d\'achats (atelier)');
    expect(n.blocks.map((b) => b.text), ['Bois', 'Vis']);
    expect(n.favorite, isTrue);
    expect(android.repo.allNotes(), hasLength(1));
    await waitConverged([android, windows]);
  });

  test('Test 3 — création hors ligne (et redémarrage), synchronisée au retour du réseau', () async {
    final windows = await device('Windows'), android = await device('Android');
    await android.pairWith(windows);
    await android.goOffline();
    android.repo.createNote(title: 'Idée dans le métro', blocks: [Block(text: 'Haptique')]);
    final f = android.repo.createFolder('Projets');
    android.repo.moveToFolder(android.byTitle('Idée dans le métro').id, f.id);
    expect(android.store.pendingCount(), greaterThan(0));
    expect(android.byTitle('Idée dans le métro').dirty, isTrue);

    // L'application est fermée puis rouverte sans réseau : rien n'est perdu.
    await android.restart();
    await android.goOffline();
    expect(android.maybeByTitle('Idée dans le métro'), isNotNull);
    expect(android.store.pendingCount(), greaterThan(0));
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(windows.maybeByTitle('Idée dans le métro'), isNull);

    await android.goOnline();
    await waitFor(() => windows.maybeByTitle('Idée dans le métro') != null, 'note reçue au retour du réseau');
    await waitConverged([android, windows]);
    expect(windows.repo.folders().single.name, 'Projets');
    expect(windows.byTitle('Idée dans le métro').folderId, windows.repo.folders().single.id);
    expect(android.byTitle('Idée dans le métro').dirty, isFalse);
  });

  group('Test 4 — modifications simultanées hors ligne', () {
    test('blocs différents : fusion automatique, rien n\'est perdu', () async {
      final windows = await device('Windows'), android = await device('Android');
      await android.pairWith(windows);
      android.repo.createNote(title: 'Révisions', blocks: [
        Block(id: 'b1', type: BlockType.todo, text: 'Schémas'),
        Block(id: 'b2', type: BlockType.todo, text: 'Grafcet'),
      ]);
      await waitConverged([android, windows]);

      await android.goOffline();
      await windows.goOffline();
      edit(android, 'Révisions', (n) => n.blocks[0].checked = true);
      edit(windows, 'Révisions', (n) {
        n.blocks[1].text = 'Grafcet (chap. 3)';
        n.blocks.add(Block(id: 'b3', type: BlockType.todo, text: 'TIA Portal'));
      });
      await windows.goOnline();
      await android.goOnline();
      await waitConverged([android, windows]);
      for (final d in [android, windows]) {
        final n = d.byTitle('Révisions');
        expect(n.hasConflict, isFalse, reason: d.name);
        expect(n.blocks.map((b) => b.text), ['Schémas', 'Grafcet (chap. 3)', 'TIA Portal'], reason: d.name);
        expect(n.blocks[0].checked, isTrue, reason: d.name);
      }
    });

    test('même paragraphe : conflit détecté, rien n\'est écrasé, « garder les deux »', () async {
      final windows = await device('Windows'), android = await device('Android');
      await android.pairWith(windows);
      android.repo.createNote(title: 'Compte rendu', blocks: [Block(id: 'b1', text: 'Version initiale')]);
      await waitConverged([android, windows]);

      await android.goOffline();
      await windows.goOffline();
      edit(android, 'Compte rendu', (n) => n.blocks[0].text = 'Version du téléphone');
      edit(windows, 'Compte rendu', (n) => n.blocks[0].text = 'Version du PC');
      await windows.goOnline();
      await android.goOnline();

      // Le conflit est présenté sur l'appareil qui pilote l'échange.
      final judge = android.isDriverFor(windows) ? android : windows;
      final other = judge == android ? windows : android;
      await waitFor(() => judge.byTitle('Compte rendu').hasConflict, 'conflit détecté');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(android.byTitle('Compte rendu').blocks[0].text, 'Version du téléphone', reason: 'rien n\'est écrasé');
      expect(windows.byTitle('Compte rendu').blocks[0].text, 'Version du PC', reason: 'rien n\'est écrasé');
      expect(judge.node.status.conflicts, 1);
      final mine = judge.byTitle('Compte rendu').blocks[0].text;
      final theirs = other.byTitle('Compte rendu').blocks[0].text;

      await judge.repo.resolveConflict(judge.byTitle('Compte rendu').id, ConflictChoice.keepBoth);
      await waitConverged([android, windows]);
      for (final d in [android, windows]) {
        expect(d.byTitle('Compte rendu').blocks[0].text, theirs, reason: d.name);
        expect(d.byTitle('Compte rendu (ma version)').blocks[0].text, mine, reason: d.name);
        expect(d.repo.allNotes().where((n) => n.hasConflict), isEmpty, reason: d.name);
      }
    });

    test('« garder ma version » : l\'autre version reste dans l\'historique', () async {
      final windows = await device('Windows'), android = await device('Android');
      await android.pairWith(windows);
      android.repo.createNote(title: 'Titre commun', blocks: [Block(id: 'b1', text: 'texte')]);
      await waitConverged([android, windows]);
      await android.goOffline();
      await windows.goOffline();
      edit(android, 'Titre commun', (n) => n.title = 'Titre A');
      edit(windows, 'Titre commun', (n) => n.title = 'Titre W');
      await windows.goOnline();
      await android.goOnline();
      final judge = android.isDriverFor(windows) ? android : windows;
      final mine = judge == android ? 'Titre A' : 'Titre W';
      final theirs = judge == android ? 'Titre W' : 'Titre A';
      await waitFor(() => judge.byTitle(mine).hasConflict, 'conflit détecté');
      await judge.repo.resolveConflict(judge.byTitle(mine).id, ConflictChoice.keepMine);
      await waitConverged([android, windows]);
      final other = judge == android ? windows : android;
      expect(other.maybeByTitle(mine), isNotNull);
      expect(other.repo.history(other.byTitle(mine).id).map((v) => v.title), contains(theirs),
          reason: 'version remplacée conservée dans l\'historique');
    });

    test('modifiée d\'un côté, mise à la corbeille de l\'autre : le texte est conservé', () async {
      final windows = await device('Windows'), android = await device('Android');
      await android.pairWith(windows);
      android.repo.createNote(title: 'Brouillon', blocks: [Block(id: 'b1', text: 'a')]);
      await waitConverged([android, windows]);
      await android.goOffline();
      await windows.goOffline();
      windows.repo.trashNote(windows.byTitle('Brouillon').id);
      edit(android, 'Brouillon', (n) => n.blocks[0].text = 'a + suite importante');
      await windows.goOnline();
      await android.goOnline();
      await waitConverged([android, windows]);
      for (final d in [android, windows]) {
        final n = d.byTitle('Brouillon');
        expect(n.blocks[0].text, 'a + suite importante', reason: d.name);
        expect(n.trashed, isTrue, reason: d.name);
      }
    });
  });

  test('Test 5 — suppression propagée (corbeille, restauration, suppression définitive)', () async {
    final windows = await device('Windows'), android = await device('Android');
    await android.pairWith(windows);
    android.repo.createNote(title: 'À jeter');
    android.repo.createNote(title: 'À garder');
    await waitConverged([android, windows]);

    windows.repo.trashNote(windows.byTitle('À jeter').id);
    await waitFor(() => android.byTitle('À jeter').trashed, 'corbeille propagée');
    android.repo.restoreNote(android.byTitle('À jeter').id);
    await waitFor(() => !windows.byTitle('À jeter').trashed, 'restauration propagée');
    windows.repo.trashNote(windows.byTitle('À jeter').id);
    windows.repo.emptyTrash();
    await waitFor(() => android.maybeByTitle('À jeter') == null, 'suppression définitive propagée');
    expect(android.repo.allNotes().map((n) => n.title), ['À garder']);
    expect(android.repo.search('jeter'), isEmpty);
    await waitConverged([android, windows]);
  });

  test('Test 6 — image ajoutée sur Android, disponible sur Windows (vérifiée par SHA-256)', () async {
    final windows = await device('Windows'), android = await device('Android');
    await android.pairWith(windows);
    final note = android.repo.createNote(title: 'Schéma KM1');
    final bytes = fakePng(700 * 1024); // plusieurs morceaux de 256 Ko
    final att = android.repo.addAttachment(note.id, fileName: 'schéma câblage.png', bytes: bytes);
    edit(android, 'Schéma KM1', (n) => n.blocks.add(Block(type: BlockType.image, attachmentId: att.id)));

    await waitFor(() => windows.repo.localPath(att.id) != null, 'image reçue sur Windows');
    final got = File(windows.repo.localPath(att.id)!).readAsBytesSync();
    expect(crypto.sha256.convert(got).toString(), crypto.sha256.convert(bytes).toString());
    expect(windows.byTitle('Schéma KM1').blocks.last.attachmentId, att.id);
    expect(windows.repo.attachmentsOf(note.id).single.fileName, 'schéma câblage.png');

    // Dans l'autre sens, et suppression propagée.
    final pdf = windows.repo.addAttachment(note.id, fileName: 'notice.pdf', bytes: fakePng(3000, 9));
    await waitFor(() => android.repo.localPath(pdf.id) != null, 'fichier reçu sur Android');
    windows.repo.deleteAttachment(att.id);
    await waitFor(() => android.repo.localPath(att.id) == null, 'fichier supprimé sur Android');
    expect(android.repo.attachmentsOf(note.id).map((a) => a.fileName), ['notice.pdf']);
  });

  test('Test 7 — redémarrage des deux applications : données et association conservées', () async {
    final windows = await device('Windows'), android = await device('Android');
    await android.pairWith(windows);
    android.repo.createNote(title: 'Persistante', blocks: [Block(text: 'contenu')]);
    final tag = android.repo.createTag('Travail', color: '#E60012');
    android.repo.setTags(android.byTitle('Persistante').id, [tag.id]);
    await waitConverged([android, windows]);

    await android.restart();
    await windows.restart();
    for (final d in [android, windows]) {
      expect(d.byTitle('Persistante').blocks.single.text, 'contenu', reason: d.name);
      expect(d.repo.tags().single.name, 'Travail', reason: d.name);
      expect(d.store.peers(), hasLength(1), reason: d.name);
    }
    // Les deux se retrouvent seuls (adresses mémorisées) et continuent à se synchroniser.
    await waitFor(() => android.node.connectedCount == 1 && windows.node.connectedCount == 1, 'reconnexion');
    windows.repo.createNote(title: 'Après redémarrage');
    await waitFor(() => android.maybeByTitle('Après redémarrage') != null, 'synchro après redémarrage');
  });

  test('Test 8 — trois appareils : téléphone ↔ PC ↔ tablette restent cohérents', () async {
    final pc = await device('PC'), phone = await device('Téléphone'), tablet = await device('Tablette');
    await phone.pairWith(pc);
    await tablet.pairWith(pc);
    for (var i = 0; i < 4; i++) {
      phone.repo.createNote(title: 'T$i', blocks: [Block(text: 'depuis le téléphone')]);
      pc.repo.createNote(title: 'P$i', blocks: [Block(text: 'depuis le PC')]);
      tablet.repo.createNote(title: 'B$i', blocks: [Block(text: 'depuis la tablette')]);
    }
    final travail = pc.repo.createTag('Travail');
    pc.repo.setTags(pc.byTitle('P0').id, [travail.id]);
    await waitConverged([phone, pc, tablet]);

    edit(phone, 'P1', (n) => n.blocks.add(Block(text: 'ajout téléphone')));
    edit(tablet, 'T2', (n) => n.favorite = true);
    pc.repo.trashNote(pc.byTitle('B3').id);
    await waitConverged([phone, pc, tablet]);

    expect(phone.repo.allNotes(), hasLength(12));
    expect(tablet.byTitle('P1').blocks.map((b) => b.text), ['depuis le PC', 'ajout téléphone']);
    expect(phone.byTitle('T2').favorite, isTrue);
    expect(tablet.byTitle('B3').trashed, isTrue);
    for (final d in [phone, pc, tablet]) {
      expect(d.store.conflictCount(), 0, reason: d.name);
    }
  });

  group('Test 9 — sécurité', () {
    test('un appareil non associé ne reçoit rien et ne peut rien écrire', () async {
      final pc = await device('PC'), phone = await device('Téléphone'), intrus = await device('Intrus');
      await phone.pairWith(pc);
      phone.repo.createNote(title: 'Secret', blocks: [Block(text: 'confidentiel')]);
      await waitConverged([phone, pc]);

      // Connexion directe au PC sans clé d'association : refusée.
      expect(await intrus.node.connectTo('127.0.0.1', pc.node.port), isFalse);
      // L'intrus usurpe l'identifiant du téléphone : sans la clé, l'échange échoue.
      intrus.store.setMeta('device_id', phone.store.deviceId);
      intrus.store.addPeer(pc.store.deviceId, name: 'PC', platform: 'test', address: '127.0.0.1', port: pc.node.port);
      await intrus.keys.write(pc.store.deviceId, List.filled(32, 7));
      expect(await intrus.node.connectTo('127.0.0.1', pc.node.port), isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(intrus.repo.allNotes(), isEmpty);
      expect(pc.node.connectedCount, 1, reason: 'seul le téléphone est connecté');
      expect(pc.store.peers().map((p) => p.name), ['Téléphone']);
    });

    test('appareil retiré : il ne peut plus se synchroniser', () async {
      final pc = await device('PC'), phone = await device('Téléphone');
      await phone.pairWith(pc);
      await pc.node.removePeer(phone.store.deviceId);
      await waitFor(() => phone.store.peers().isEmpty, 'retrait propagé au téléphone');
      phone.repo.createNote(title: 'Après retrait');
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(pc.maybeByTitle('Après retrait'), isNull);
      expect(pc.node.connectedCount, 0);
    });
  });

  group('Robustesse', () {
    test('beaucoup de notes : réception par pages', () async {
      final pc = await device('PC'), phone = await device('Téléphone');
      phone.store.transaction(() {
        for (var i = 0; i < 450; i++) {
          phone.repo.createNote(title: 'N$i', blocks: [Block(text: 'contenu $i')]);
        }
      });
      await phone.pairWith(pc);
      await waitFor(() => pc.repo.allNotes().length == 450, '450 notes reçues', timeout: const Duration(seconds: 40));
      await waitConverged([phone, pc], timeout: const Duration(seconds: 40));
    });

    test('dossiers, sous-dossiers et étiquettes ; suppression d\'un dossier', () async {
      final pc = await device('PC'), phone = await device('Téléphone');
      await phone.pairWith(pc);
      final bts = phone.repo.createFolder('BTS');
      final auto = phone.repo.createFolder('Automatisme', parentId: bts.id);
      final tag = phone.repo.createTag('Perso', color: '#858585');
      phone.repo.createNote(title: 'Grafcet', folderId: auto.id, tags: [tag.id]);
      await waitConverged([phone, pc]);
      expect(pc.repo.folderSubtree(bts.id), {bts.id, auto.id});
      expect(pc.repo.search('perso').single.title, 'Grafcet');
      pc.repo.deleteTag(tag.id);
      pc.repo.deleteFolder(bts.id);
      await waitConverged([phone, pc]);
      expect(phone.repo.tags(), isEmpty);
      expect(phone.repo.folders(), isEmpty);
      expect(phone.byTitle('Grafcet').folderId, isNull);
    });

    test('saisie continue pendant la synchronisation : rien n\'est perdu', () async {
      final pc = await device('PC'), phone = await device('Téléphone');
      await phone.pairWith(pc);
      final n = phone.repo.createNote(title: 'Frappe rapide', blocks: [Block(id: 'b1', text: '')]);
      var text = '';
      for (var i = 0; i < 40; i++) {
        text += 'x';
        final cur = phone.repo.note(n.id)!..blocks[0].text = text;
        phone.repo.saveNote(cur);
        await Future<void>.delayed(const Duration(milliseconds: 15));
      }
      await waitConverged([phone, pc]);
      expect(pc.byTitle('Frappe rapide').blocks[0].text, text);
    });

    test('état « hors de portée » puis retour', () async {
      final pc = await device('PC'), phone = await device('Téléphone');
      await phone.pairWith(pc);
      await waitFor(() => phone.node.status.state == SyncState.synced, 'synchronisé');
      await pc.goOffline();
      await waitFor(() => phone.node.status.state == SyncState.offline, 'hors de portée');
      phone.repo.createNote(title: 'En attente');
      await waitFor(() => phone.node.status.pending > 0, 'en attente');
      await pc.goOnline();
      await waitFor(() => pc.maybeByTitle('En attente') != null, 'envoyée au retour');
      await waitFor(() => phone.node.status.state == SyncState.synced, 'synchronisé à nouveau');
    });
  });
}
