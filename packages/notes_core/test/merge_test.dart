import 'package:notes_core/notes_core.dart';
import 'package:test/test.dart';

Map<String, dynamic> note(String title, List<Map<String, dynamic>> blocks,
        {int version = 1, List<String> tags = const [], bool favorite = false, String? folder, bool purged = false}) =>
    {
      'id': 'n1',
      'title': title,
      'content': {'blocks': blocks},
      'folder_id': folder,
      'tags': tags,
      'favorite': favorite,
      'archived': false,
      'trashed_at': null,
      'purged': purged,
      'updated_at': '2026-11-14T10:00:00.000Z',
      'version': version,
    };

Map<String, dynamic> b(String id, String text, {String type = 'p'}) => {'id': id, 'type': type, 'text': text};

void main() {
  group('jsonEq', () {
    test('ordre des clés et format des dates sans importance', () {
      expect(jsonEq({'a': 1, 'b': [1, 2]}, {'b': [1, 2], 'a': 1}), isTrue);
      expect(jsonEq('2026-11-14T10:00:00.000Z', '2026-11-14T10:00:00+00:00'), isTrue);
      expect(jsonEq('2026-11-14T10:00:00.000Z', '2026-11-14T11:00:00+01:00'), isTrue);
      expect(jsonEq('2026-11-14T10:00:00.000Z', '2026-11-14T10:00:01+00:00'), isFalse);
      expect(jsonEq({'a': null}, <String, dynamic>{}), isTrue);
      expect(jsonEq([1, 2], [2, 1]), isFalse);
    });
  });

  group('mergeBlocks', () {
    test('modifications sur des blocs différents', () {
      final r = mergeBlocks([b('1', 'a'), b('2', 'b')], [b('1', 'A'), b('2', 'b')], [b('1', 'a'), b('2', 'B')]);
      expect(r!.map((x) => x['text']), ['A', 'B']);
    });
    test('ajouts des deux côtés, ordre conservé', () {
      final r = mergeBlocks([b('1', 'a'), b('2', 'b')], [b('1', 'a'), b('L', 'local'), b('2', 'b')],
          [b('1', 'a'), b('2', 'b'), b('S', 'serveur')]);
      expect(r!.map((x) => x['id']), ['1', 'L', '2', 'S']);
    });
    test('suppression d\'un côté, autre bloc modifié de l\'autre', () {
      final r = mergeBlocks([b('1', 'a'), b('2', 'b')], [b('2', 'b')], [b('1', 'a'), b('2', 'B')]);
      expect(r!.map((x) => x['text']), ['B']);
    });
    test('même bloc modifié différemment : conflit', () {
      expect(mergeBlocks([b('1', 'a')], [b('1', 'x')], [b('1', 'y')]), isNull);
    });
    test('même bloc modifié à l\'identique : pas de conflit', () {
      expect(mergeBlocks([b('1', 'a')], [b('1', 'x')], [b('1', 'x')])!.single['text'], 'x');
    });
    test('modifié d\'un côté, supprimé de l\'autre : conflit', () {
      expect(mergeBlocks([b('1', 'a')], [b('1', 'x')], []), isNull);
      expect(mergeBlocks([b('1', 'a')], [], [b('1', 'x')]), isNull);
    });
    test('réorganisation locale conservée avec ajout serveur', () {
      final r = mergeBlocks([b('1', 'a'), b('2', 'b'), b('3', 'c')], [b('3', 'c'), b('1', 'a'), b('2', 'b')],
          [b('1', 'a'), b('2', 'b'), b('3', 'c'), b('4', 'd')]);
      expect(r!.map((x) => x['id']), ['3', '4', '1', '2'], reason: '4 suit toujours 3, son prédécesseur');
    });
  });

  group('mergeRows (notes)', () {
    final base = note('Titre', [b('1', 'a')], tags: ['t1']);

    test('titre modifié localement, contenu modifié sur le serveur', () {
      final local = note('Nouveau titre', [b('1', 'a')], tags: ['t1']);
      final server = note('Titre', [b('1', 'a'), b('2', 'b')], version: 2, tags: ['t1']);
      final out = mergeRows(EntityType.notes, base, local, server);
      expect(out.isClean, isTrue);
      expect(out.merged['title'], 'Nouveau titre');
      expect((out.merged['content']['blocks'] as List).length, 2);
      expect(out.merged['version'], 2);
    });

    test('titres différents des deux côtés : conflit à arbitrer', () {
      final out = mergeRows(EntityType.notes, base, note('L', [b('1', 'a')]), note('S', [b('1', 'a')], version: 2));
      expect(out.isClean, isFalse);
      expect(out.hardConflicts, contains('title'));
    });

    test('étiquettes : ajouts et retraits fusionnés', () {
      final local = note('Titre', [b('1', 'a')], tags: ['t1', 't2']);
      final server = note('Titre', [b('1', 'a')], version: 2, tags: ['t3']);
      final out = mergeRows(EntityType.notes, base, local, server);
      expect(out.isClean, isTrue);
      expect(out.merged['tags'], unorderedEquals(['t2', 't3']));
    });

    test('favori et dossier : la modification locale est retenue', () {
      final local = note('Titre', [b('1', 'a')], tags: ['t1'], favorite: true, folder: 'f-local');
      final server = note('Titre', [b('1', 'a')], version: 2, tags: ['t1'], folder: 'f-serveur');
      final out = mergeRows(EntityType.notes, base, local, server);
      expect(out.isClean, isTrue);
      expect(out.merged['favorite'], isTrue);
      expect(out.merged['folder_id'], 'f-local');
      expect(out.softConflicts, ['folder_id']);
    });

    test('supprimée définitivement d\'un côté, modifiée de l\'autre : conflit', () {
      final local = note('Titre', [b('1', 'a modifié')], tags: ['t1']);
      final server = note('', [], version: 2, purged: true);
      expect(mergeRows(EntityType.notes, base, local, server).hardConflicts, contains('purged'));
    });

    test('supprimée définitivement d\'un côté, intacte de l\'autre : suppression', () {
      final local = note('Titre', [b('1', 'a')], tags: ['t1'], favorite: true);
      final server = note('', [], version: 2, purged: true);
      final out = mergeRows(EntityType.notes, base, local, server);
      expect(out.isClean, isTrue);
      expect(out.merged['purged'], isTrue);
    });

    test('la décision ne dépend pas de l\'heure de modification', () {
      final local = note('L', [b('1', 'a')])..['updated_at'] = '2020-01-01T00:00:00.000Z';
      final server = note('S', [b('1', 'a')], version: 2)..['updated_at'] = '2030-01-01T00:00:00.000Z';
      expect(mergeRows(EntityType.notes, base, local, server).isClean, isFalse);
      final local2 = note('L', [b('1', 'a')])..['updated_at'] = '2030-01-01T00:00:00.000Z';
      final server2 = note('S', [b('1', 'a')], version: 2)..['updated_at'] = '2020-01-01T00:00:00.000Z';
      expect(mergeRows(EntityType.notes, base, local2, server2).isClean, isFalse);
    });
  });

  test('mergeRows (dossiers) : champs indépendants fusionnés', () {
    final base = {'id': 'f', 'name': 'A', 'color': null, 'parent_id': null, 'position': 0, 'deleted': false, 'version': 1};
    final local = {...base, 'name': 'B'};
    final server = {...base, 'color': '#E60012', 'version': 2};
    final out = mergeRows(EntityType.folders, base, local, server);
    expect(out.isClean, isTrue);
    expect(out.merged['name'], 'B');
    expect(out.merged['color'], '#E60012');
  });
}
