import 'dart:io';

import 'package:notes_core/notes_core.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// Ramène une base 3.0 à l'état exact d'une base 2.0 (même schéma, même
/// version) pour tester la migration sans dépendre d'un fichier externe.
void downgradeToV2(String path) {
  final db = sqlite3.open(path);
  db.execute('DROP TABLE links');
  db.userVersion = 2;
  db.dispose();
}

DataFingerprint fingerprintOf(String path) {
  final db = sqlite3.open(path, mode: OpenMode.readOnly);
  try {
    return DataFingerprint.of(db);
  } finally {
    db.dispose();
  }
}

int userVersionOf(String path) {
  final db = sqlite3.open(path, mode: OpenMode.readOnly);
  try {
    return db.userVersion;
  } finally {
    db.dispose();
  }
}

void main() {
  late Directory dir;
  late String dbPath;
  late String backups;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nn_mig_');
    dbPath = p.join(dir.path, 'notes.db');
    backups = p.join(dir.path, 'backups');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  void seed() {
    final store = LocalStore.open(dbPath);
    store.historyInterval = Duration.zero;
    final repo = NotesRepository(store: store, filesDir: p.join(dir.path, 'files'));
    final f = repo.createFolder('Cours');
    final t = repo.createTag('bts');
    final a = repo.createNote(title: 'Cible', folderId: f.id, tags: [t.id]);
    repo.createNote(title: 'Source', blocks: [Block(text: 'voir [Cible](nn:page:${a.id})')]);
    for (var i = 0; i < 20; i++) {
      final n = repo.createNote(title: 'Note $i', blocks: [Block(text: 'texte $i')]);
      n.blocks.first.text = 'modifié $i';
      repo.saveNote(n);
    }
    store.close();
  }

  group('Migration 2.0 → 3.0', () {
    test('sauvegarde vérifiée créée AVANT, données identiques APRÈS, liens indexés', () {
      seed();
      downgradeToV2(dbPath);
      final before = fingerprintOf(dbPath);
      expect(userVersionOf(dbPath), 2);

      final safety = DataSafety(backups);
      final store = safety.openStore(dbPath);
      expect(DataFingerprint.of(store.database), before);
      expect(store.database.userVersion, 3);
      final repo = NotesRepository(store: store, filesDir: p.join(dir.path, 'files'));
      expect(repo.allNotes().length, 22);
      final cible = repo.allNotes().firstWhere((n) => n.title == 'Cible');
      expect(repo.backlinksOf(cible.id).single.title, 'Source');
      store.close();

      final list = safety.list();
      expect(list, hasLength(1));
      expect(list.single.label, 'v2-avant-migration');
      expect(fingerprintOf(list.single.path), before, reason: 'la sauvegarde contient exactement les données 2.0');
      expect(userVersionOf(list.single.path), 2);
    });

    test('base déjà à jour : aucune sauvegarde inutile', () {
      seed();
      final safety = DataSafety(backups);
      safety.openStore(dbPath).close();
      expect(safety.list(), isEmpty);
    });

    test('première installation : base créée', () {
      final store = DataSafety(backups).openStore(dbPath);
      expect(store.database.userVersion, 3);
      store.close();
    });

    test('échec pendant la migration : la base d\'origine est remise en place, rien n\'est perdu', () {
      seed();
      downgradeToV2(dbPath);
      // Obstacle volontaire : un objet « links » qui n'est pas une table fait échouer la migration.
      final raw = sqlite3.open(dbPath);
      raw.execute('CREATE VIEW links AS SELECT 1 AS src, 2 AS dst');
      raw.dispose();
      final before = fingerprintOf(dbPath);

      final safety = DataSafety(backups);
      expect(() => safety.openStore(dbPath), throwsA(isA<MigrationAborted>()));
      expect(userVersionOf(dbPath), 2, reason: 'version inchangée');
      expect(fingerprintOf(dbPath), before, reason: 'données intactes');
      expect(safety.list(), hasLength(1), reason: 'la sauvegarde est conservée');
    });

    test('base endommagée : aucune migration tentée, fichier laissé tel quel', () {
      seed();
      downgradeToV2(dbPath);
      final bytes = File(dbPath).readAsBytesSync();
      // Corrompt une page de données (pas l'en-tête) pour que l'intégrité échoue.
      final broken = [...bytes];
      for (var i = 4096 + 100; i < 4096 + 1200 && i < broken.length; i++) {
        broken[i] = 0xAB;
      }
      File(dbPath).writeAsBytesSync(broken);
      for (final s in ['-wal', '-shm']) {
        final f = File('$dbPath$s');
        if (f.existsSync()) f.deleteSync();
      }
      expect(() => DataSafety(backups).openStore(dbPath), throwsA(isA<Object>()));
      expect(File(dbPath).readAsBytesSync(), broken, reason: 'le fichier n\'a pas été touché');
    });
  });

  group('Sauvegardes manuelles et restauration', () {
    test('sauvegarder, modifier, restaurer : retour exact à la sauvegarde', () {
      seed();
      final safety = DataSafety(backups);
      var store = safety.openStore(dbPath);
      final saved = DataFingerprint.of(store.database);
      final b = safety.backupNow(store);
      expect(safety.inspect(b.path), saved);
      final repo = NotesRepository(store: store, filesDir: p.join(dir.path, 'files'));
      repo.createNote(title: 'Ajoutée après la sauvegarde');
      store.close();

      safety.restore(b.path, dbPath);
      store = LocalStore.open(dbPath);
      expect(DataFingerprint.of(store.database), saved);
      store.close();
      expect(safety.list().map((x) => x.label), containsAll(['manuelle', 'avant-restauration']));
      final undo = safety.list().firstWhere((x) => x.label == 'avant-restauration');
      final repo2 = NotesRepository(store: LocalStore.open(undo.path), filesDir: p.join(dir.path, 'files'));
      expect(repo2.allNotes().any((n) => n.title == 'Ajoutée après la sauvegarde'), isTrue,
          reason: 'l\'état remplacé reste récupérable');
      repo2.store.close();
    });
  });

  // Base produite par le VRAI code de Nothing Notes 2.0.0 (générée en CI par
  // tool/v2_fixture.dart dans une copie de travail de la version 2.0.0).
  final fixture = Platform.environment['NN_V2_FIXTURE'];
  group('Migration d\'une base produite par Nothing Notes 2.0.0', () {
    test('toutes les données sont conservées et utilisables', () {
      final work = p.join(dir.path, 'v2.db');
      File(fixture!).copySync(work);
      expect(userVersionOf(work), 2);
      final before = fingerprintOf(work);
      expect(before.counts['notes'], 12);
      expect(before.counts['attachments'], 12);

      final store = DataSafety(backups).openStore(work);
      expect(DataFingerprint.of(store.database), before);
      final repo = NotesRepository(store: store, filesDir: Platform.environment['NN_V2_FILES']!);
      final notes = repo.allNotes();
      expect(notes.where((n) => !n.purged).length, 11);
      expect(notes.where((n) => n.trashed && !n.purged).length, 1);
      expect(notes.where((n) => n.favorite).length, 1);
      expect(notes.where((n) => n.archived).length, 1);
      expect(repo.folders().length, 3);
      expect(repo.tags().length, 2);
      expect(store.conflictCount(), 1, reason: 'le conflit en attente est conservé');
      expect(store.peers().single.name, 'Téléphone');
      for (final n in notes.where((n) => !n.purged)) {
        expect(n.blocks.map((b) => b.type).toSet(),
            containsAll([BlockType.heading1, BlockType.table, BlockType.code, BlockType.todo]));
        for (final a in repo.attachmentsOf(n.id)) {
          expect(repo.localPath(a.id), isNotNull, reason: 'fichier ${a.fileName} retrouvé');
        }
      }
      expect(repo.history(notes.firstWhere((n) => n.title.startsWith('Note 3')).id).length, greaterThanOrEqualTo(4));
      expect(repo.search('accentuée').length, notes.where((n) => !n.purged).length);

      // Les notes 2.0 s'éditent normalement en 3.0, sans perte de forme.
      final n = notes.firstWhere((n) => n.title.startsWith('Note 5'));
      final rowBefore = store.get(EntityType.notes, n.id)!.data;
      n.title = 'Note 5 modifiée en 3.0';
      repo.saveNote(n);
      final rowAfter = store.get(EntityType.notes, n.id)!.data;
      expect(rowAfter.keys.toSet(), rowBefore.keys.toSet(), reason: 'aucun champ ajouté à une note ordinaire');
      expect(rowAfter['content'], rowBefore['content']);
      store.close();
    });
  }, skip: fixture == null ? 'NN_V2_FIXTURE non défini (fourni par la CI)' : false);
}
