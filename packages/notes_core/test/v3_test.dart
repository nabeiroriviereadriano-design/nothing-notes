import 'dart:convert';
import 'dart:io';

import 'package:notes_core/notes_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late LocalStore store;
  late NotesRepository repo;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nn_v3_');
    store = LocalStore.open(p.join(dir.path, 'notes.db'));
    store.historyInterval = Duration.zero;
    repo = NotesRepository(store: store, filesDir: p.join(dir.path, 'files'));
  });
  tearDown(() {
    store.close();
    dir.deleteSync(recursive: true);
  });

  group('Compatibilité des données', () {
    test('une note ordinaire garde exactement la forme de la version 2.0', () {
      final n = repo.createNote(title: 'Simple', blocks: [Block(text: 'x')]);
      final row = store.get(EntityType.notes, n.id)!.data;
      expect(row.keys.toSet(), {
        'id', 'title', 'content', 'folder_id', 'tags', 'favorite', 'archived', 'trashed_at', 'purged',
        'created_at', 'updated_at', 'device_id',
      });
    });

    test('les champs inconnus (version future) sont conservés à l\'enregistrement', () {
      final n = repo.createNote(title: 'Futur');
      final row = Map<String, dynamic>.from(store.get(EntityType.notes, n.id)!.data)
        ..['champ_futur'] = {'a': 1}
        ..['content'] = jsonEncode([
          {'id': 'b1', 'type': 'p', 'text': 'x', 'couleur': 'rouge'},
          {'id': 'b2', 'type': 'bloc_futur', 'donnees': [1, 2]},
        ]);
      store.saveLocal(EntityType.notes, row);
      final loaded = repo.note(n.id)!..title = 'Futur modifié';
      repo.saveNote(loaded);
      final saved = store.get(EntityType.notes, n.id)!.data;
      expect(saved['champ_futur'], {'a': 1});
      final blocks = jsonDecode(saved['content'] as String) as List;
      expect(blocks[0]['couleur'], 'rouge');
      expect(blocks[1], {'id': 'b2', 'type': 'bloc_futur', 'donnees': [1, 2]});
    });

    test('changer uniquement une propriété, une icône ou le parent est bien enregistré', () {
      final a = repo.createNote(title: 'A');
      final b = repo.createNote(title: 'B');
      final rev = store.get(EntityType.notes, b.id)!.rev;
      repo.movePage(b.id, a.id);
      expect(store.get(EntityType.notes, b.id)!.rev, greaterThan(rev));
      repo.setIcon(b.id, '🎯');
      expect(repo.note(b.id)!.icon, '🎯');
      repo.setProp(b.id, 'p1', 42);
      expect(repo.note(b.id)!.props['p1'], 42);
    });
  });

  group('Pages et sous-pages', () {
    test('arborescence, fil d\'Ariane et déplacement sans boucle', () {
      final root = repo.createNote(title: 'Racine');
      final a = repo.createSubPage(root.id, title: 'A');
      final a1 = repo.createSubPage(a.id, title: 'A1');
      expect(repo.childrenOf(root.id).map((n) => n.title), ['A']);
      expect(repo.ancestorsOf(a1.id).map((n) => n.title), ['Racine', 'A']);
      expect(repo.descendantIds(root.id), {a.id, a1.id});
      expect(repo.canMoveUnder(root.id, a1.id), isFalse);
      expect(() => repo.movePage(a.id, a1.id), throwsArgumentError);
      repo.movePage(a1.id, null);
      expect(repo.note(a1.id)!.parentId, isNull);
      expect(repo.ancestorsOf(a1.id), isEmpty);
    });

    test('corbeille et restauration en cascade, sans toucher aux sous-pages supprimées avant', () async {
      final root = repo.createNote(title: 'Racine');
      final a = repo.createSubPage(root.id, title: 'A');
      final b = repo.createSubPage(root.id, title: 'B');
      repo.trashNote(b.id);
      await Future<void>.delayed(const Duration(seconds: 3));
      repo.trashNote(root.id);
      expect(repo.note(a.id)!.trashed, isTrue);
      repo.restoreNote(root.id);
      expect(repo.note(root.id)!.trashed, isFalse);
      expect(repo.note(a.id)!.trashed, isFalse);
      expect(repo.note(b.id)!.trashed, isTrue, reason: 'B avait été mise à la corbeille séparément');
    });

    test('suppression définitive en cascade', () {
      final root = repo.createNote(title: 'Racine');
      final a = repo.createSubPage(root.id, title: 'A');
      repo.trashNote(root.id);
      repo.purgeNote(root.id);
      expect(repo.note(root.id), isNull);
      expect(repo.note(a.id), isNull);
    });

    test('duplication profonde', () {
      final root = repo.createNote(title: 'Racine', blocks: [Block(text: 'texte')]);
      repo.createSubPage(root.id, title: 'A', blocks: [Block(text: 'a')]);
      final copy = repo.duplicateNote(root.id);
      expect(copy.title, 'Racine (copie)');
      final kids = repo.childrenOf(copy.id);
      expect(kids.single.title, 'A');
      expect(kids.single.blocks.single.text, 'a');
      expect(kids.single.blocks.single.id, isNot(repo.childrenOf(root.id).single.blocks.single.id));
    });

    test('pages récentes propres à l\'appareil', () {
      final a = repo.createNote(title: 'A'), b = repo.createNote(title: 'B');
      repo.markOpened(a.id);
      repo.markOpened(b.id);
      repo.markOpened(a.id);
      expect(repo.recentPages().map((n) => n.title), ['A', 'B']);
      expect(store.all(EntityType.notes).length, 2, reason: 'les récents ne sont pas une donnée synchronisée');
    });
  });

  group('Liens internes', () {
    test('rétroliens indexés, mis à jour et retirés', () {
      final cible = repo.createNote(title: 'Cible');
      final src = repo.createNote(title: 'Source', blocks: [Block(text: 'voir ${pageLink('Cible', cible.id)}')]);
      expect(repo.backlinksOf(cible.id).map((n) => n.title), ['Source']);
      final n = repo.note(src.id)!..blocks = [Block(text: 'plus de lien')];
      repo.saveNote(n);
      expect(repo.backlinksOf(cible.id), isEmpty);
    });

    test('liens dans un bloc repliable et dans un tableau', () {
      final cible = repo.createNote(title: 'Cible');
      repo.createNote(title: 'T', blocks: [
        Block(type: BlockType.toggle, text: 'r', extra: {'body': pageLink('x', cible.id)}),
      ]);
      repo.createNote(title: 'Tab', blocks: [
        Block(type: BlockType.table, rows: [
          ['a'],
          [pageLink('c', cible.id)]
        ]),
      ]);
      expect(repo.backlinksOf(cible.id).map((n) => n.title).toSet(), {'T', 'Tab'});
    });

    test('recherche de pages pour une mention', () {
      repo.createNote(title: 'Électronique de puissance');
      repo.createNote(title: 'Puissance active');
      repo.createNote(title: 'Autre');
      expect(repo.findPages('puiss').map((n) => n.title), ['Puissance active', 'Électronique de puissance']);
      expect(repo.findPages('elec').single.title, 'Électronique de puissance');
    });
  });

  group('Modèles', () {
    test('les modèles intégrés existent', () {
      expect(builtInTemplates.map((t) => t.name), [
        'Note rapide', 'Cours', 'Réunion', 'Projet', 'Liste de tâches', 'Journal', 'Fiche de révision',
      ]);
    });

    test('appliquer un modèle n\'écrase jamais le contenu existant', () {
      final n = repo.createNote(title: 'Mon titre', blocks: [Block(text: 'mon texte')]);
      repo.applyTemplate(n.id, builtInTemplates.firstWhere((t) => t.name == 'Réunion'));
      final after = repo.note(n.id)!;
      expect(after.title, 'Mon titre');
      expect(after.blocks.first.text, 'mon texte');
      expect(after.blocks[1].type, BlockType.divider);
      expect(after.blocks.length, greaterThan(3));
    });

    test('page vide : le modèle la remplit', () {
      final n = repo.createNote();
      repo.applyTemplate(n.id, builtInTemplates.firstWhere((t) => t.name == 'Projet'));
      expect(repo.note(n.id)!.blocks.first.text, 'Objectif');
    });

    test('modèle personnalisé : enregistré, proposé, absent des listes et de la recherche', () {
      final src = repo.createNote(title: 'Ma structure', blocks: [Block(type: BlockType.heading1, text: 'Partie')]);
      final t = repo.saveAsTemplate(src.id);
      expect(repo.templates().map((x) => x.name), contains('Ma structure'));
      expect(repo.search('Partie').map((n) => n.id), isNot(contains(t.id)));
      final page = repo.createFromTemplate(repo.templateById(t.id)!);
      expect(page.blocks.single.text, 'Partie');
      expect(page.blocks.single.id, isNot(src.blocks.single.id));
    });
  });

  group('Tâches', () {
    test('une case à cocher devient une tâche suivie, sans doublon', () {
      final todo = Block(type: BlockType.todo, text: 'Réviser');
      final n = repo.createNote(title: 'Page', blocks: [todo]);
      expect(repo.tasks(), isEmpty);
      repo.setTracked(n.id, todo.id, true);
      expect(repo.tasks().single.text, 'Réviser');
      expect(repo.note(n.id)!.blocks.length, 1);
    });

    test('statut, échéance, priorité et filtres', () {
      final now = DateTime(2026, 11, 25);
      final t1 = Block(type: BlockType.todo, text: 'en retard');
      final t2 = Block(type: BlockType.todo, text: 'en cours');
      final t3 = Block(type: BlockType.todo, text: 'faite');
      final n = repo.createNote(title: 'P', blocks: [t1, t2, t3]);
      for (final b in [t1, t2, t3]) {
        repo.setTracked(n.id, b.id, true);
      }
      repo.updateTask(n.id, t1.id, due: DateTime(2026, 11, 20), priority: 2);
      repo.updateTask(n.id, t2.id, status: TaskStatus.doing);
      repo.updateTask(n.id, t3.id, status: TaskStatus.done);
      expect(repo.tasks(filter: TaskFilter.overdue, now: now).single.text, 'en retard');
      expect(repo.tasks(filter: TaskFilter.doing, now: now).single.text, 'en cours');
      expect(repo.tasks(filter: TaskFilter.done, now: now).single.text, 'faite');
      expect(repo.tasks(filter: TaskFilter.open, now: now).length, 2);
      expect(repo.tasks(filter: TaskFilter.open, now: now).first.text, 'en retard');
      expect(repo.note(n.id)!.blocks[2].checked, isTrue, reason: 'terminée ⇔ cochée');
    });

    test('cocher la case termine la tâche, décocher la rouvre', () {
      final t = Block(type: BlockType.todo, text: 't');
      final n = repo.createNote(blocks: [t]);
      repo.setTracked(n.id, t.id, true);
      repo.setChecked(n.id, t.id, true);
      expect(repo.tasks(filter: TaskFilter.done).length, 1);
      repo.setChecked(n.id, t.id, false);
      expect(repo.tasks(filter: TaskFilter.todo).length, 1);
    });

    test('une tâche en corbeille n\'apparaît plus', () {
      final t = Block(type: BlockType.todo, text: 't');
      final n = repo.createNote(blocks: [t]);
      repo.setTracked(n.id, t.id, true);
      repo.trashNote(n.id);
      expect(repo.tasks(filter: TaskFilter.all), isEmpty);
    });
  });

  group('Bases de données', () {
    test('création, entrées, propriétés, tri, filtres et recherche', () {
      final db = repo.createDatabase(title: 'Cours');
      var s = repo.schemaOf(db.id);
      final status = s.props[0], date = s.props[1];
      final coef = repo.addProp(db.id, 'Coefficient', PropType.number);
      final lien = repo.addProp(db.id, 'Lien', PropType.url);
      final fait = repo.addProp(db.id, 'Rendu', PropType.checkbox);
      s = repo.schemaOf(db.id);
      expect(s.props.map((p) => p.type), [PropType.status, PropType.date, PropType.number, PropType.url, PropType.checkbox]);

      final a = repo.addEntry(db.id, title: 'Maths', props: {coef.id: 3, date.id: '2026-12-10', status.id: status.options[0].id});
      final b = repo.addEntry(db.id, title: 'Physique', props: {coef.id: 5, date.id: '2026-12-01', status.id: status.options[2].id});
      repo.addEntry(db.id, title: 'Anglais', props: {coef.id: 1, lien.id: 'https://exemple.fr', fait.id: true});

      final view = DbView(name: 'v', sortProp: coef.id, sortDesc: true);
      expect(repo.queryEntries(db.id, view).map((n) => n.title), ['Physique', 'Maths', 'Anglais']);
      view
        ..sortProp = date.id
        ..sortDesc = false;
      expect(repo.queryEntries(db.id, view).map((n) => n.title), ['Physique', 'Maths', 'Anglais'],
          reason: 'les dates vides sont à la fin');
      view.filters = [DbFilter(prop: coef.id, op: 'gt', value: 2)];
      expect(repo.queryEntries(db.id, view).map((n) => n.title).toSet(), {'Maths', 'Physique'});
      view.filters = [DbFilter(prop: status.id, op: 'is', value: status.options[2].id)];
      expect(repo.queryEntries(db.id, view).single.title, 'Physique');
      view.filters = [DbFilter(prop: fait.id, op: 'checked')];
      expect(repo.queryEntries(db.id, view).single.title, 'Anglais');
      view.filters = [DbFilter(prop: date.id, op: 'before', value: '2026-12-05')];
      expect(repo.queryEntries(db.id, view).single.title, 'Physique');
      view.filters = [];
      expect(repo.queryEntries(db.id, view, search: 'terminé').single.title, 'Physique',
          reason: 'la recherche porte aussi sur les propriétés');
      expect(repo.queryEntries(db.id, view, search: 'phys').single.id, b.id);
      expect(repo.search('Maths').map((n) => n.id), contains(a.id));
    });

    test('supprimer une propriété ne supprime pas les valeurs saisies', () {
      final db = repo.createDatabase();
      final p1 = repo.addProp(db.id, 'Note', PropType.number);
      final e = repo.addEntry(db.id, title: 'E', props: {p1.id: 12});
      repo.removeProp(db.id, p1.id);
      expect(repo.schemaOf(db.id).prop(p1.id), isNull);
      expect(repo.note(e.id)!.props[p1.id], 12);
    });

    test('valeurs affichées', () {
      final p = DbProp(name: 'd', type: PropType.date);
      expect(displayValue(p, '2026-03-07'), '07/03/2026');
      expect(displayValue(DbProp(name: 'n', type: PropType.number), 2.5), '2,5');
      expect(displayValue(DbProp(name: 'c', type: PropType.checkbox), true), '✓');
    });

    test('champs inconnus du schéma conservés', () {
      final db = repo.createDatabase();
      final n = repo.note(db.id)!..db = {...n0(repo.note(db.id)!.db!), 'futur': 1};
      repo.saveNote(n);
      repo.addProp(db.id, 'X', PropType.text);
      expect(repo.note(db.id)!.db!['futur'], 1);
    });
  });

  group('Import Markdown', () {
    test('conversion des éléments courants', () {
      const md = '''# Mon cours

## Partie 1
Texte **gras** et <u>souligné</u>.
Suite.

- puce
* autre
1. un
2) deux
- [ ] à faire
- [x] fait

> citation
> sur deux lignes

```dart
void main() {}
```

---

| A | B |
|---|---|
| 1 | 2 \\| 3 |

<details>
<summary>Question</summary>

Réponse
</details>

### Détail
''';
      final doc = parseMarkdown(md);
      expect(doc.title, 'Mon cours');
      final types = doc.blocks.map((b) => b.type).toList();
      expect(types, [
        BlockType.heading1, BlockType.paragraph, BlockType.bullet, BlockType.bullet, BlockType.numbered,
        BlockType.numbered, BlockType.todo, BlockType.todo, BlockType.quote, BlockType.code, BlockType.divider,
        BlockType.table, BlockType.toggle, BlockType.heading2,
      ]);
      expect(doc.blocks[1].text, 'Texte **gras** et ++souligné++.\nSuite.');
      expect(doc.blocks[7].checked, isTrue);
      expect(doc.blocks[8].text, 'citation\nsur deux lignes');
      expect(doc.blocks[9].text, 'void main() {}');
      expect(doc.blocks[11].rows, [
        ['A', 'B'],
        ['1', '2 | 3'],
      ]);
      expect(doc.blocks[12].text, 'Question');
      expect(doc.blocks[12].body, 'Réponse');
    });

    test('aller-retour : export Markdown puis import', () {
      final n = repo.createNote(title: 'Aller-retour', blocks: [
        Block(type: BlockType.heading1, text: 'H1'),
        Block(type: BlockType.heading2, text: 'H2'),
        Block(type: BlockType.heading3, text: 'H3'),
        Block(text: 'texte *italique*'),
        Block(type: BlockType.todo, text: 'case', checked: true),
        Block(type: BlockType.toggle, text: 'Résumé', extra: {'body': 'corps'}),
      ]);
      final back = parseMarkdown(exportMarkdown(n));
      expect(back.title, 'Aller-retour');
      expect(back.blocks.map((b) => '${b.type}:${b.text}').toList(),
          ['h1:H1', 'h2:H2', 'h3:H3', 'p:texte *italique*', 'todo:case', 'toggle:Résumé']);
      expect(back.blocks.last.body, 'corps');
    });

    test('import = nouvelle page, rien d\'existant n\'est modifié', () {
      final existing = repo.createNote(title: 'Existante', blocks: [Block(text: 'intact')]);
      final rev = store.get(EntityType.notes, existing.id)!.rev;
      final n = repo.importMarkdown('Juste du texte', fileName: 'Mon fichier.md');
      expect(n.title, 'Mon fichier');
      expect(store.get(EntityType.notes, existing.id)!.rev, rev);
    });

    test('texte partagé depuis une autre appli', () {
      final n = repo.importSharedText('Courses\nlait\npain');
      expect(n.title, 'Courses');
      expect(n.blocks.single.text, 'lait\npain');
      final m = repo.importSharedText('https://exemple.fr', subject: 'Article');
      expect(m.title, 'Article');
      expect(m.blocks.single.text, 'https://exemple.fr');
    });
  });

  group('Export', () {
    test('H3, blocs repliables, liens internes et propriétés', () {
      final cible = repo.createNote(title: 'Cible');
      final n = repo.createNote(title: 'Page', blocks: [
        Block(type: BlockType.heading3, text: 'Niveau 3'),
        Block(type: BlockType.toggle, text: 'Résumé', extra: {'body': 'caché'}),
        Block(text: 'voir ${pageLink('Cible', cible.id)}'),
      ]);
      final ctx = ExportContext(properties: [('Statut', 'En cours')], subPages: ['Enfant']);
      final md = exportMarkdown(n, ctx);
      expect(md, contains('#### Niveau 3'));
      expect(md, contains('<summary>Résumé</summary>'));
      expect(md, contains('voir **Cible**'));
      expect(md, isNot(contains('nn:page:')));
      expect(md, contains('- **Statut** : En cours'));
      expect(md, contains('- Enfant'));
      final html = exportHtml(n, ctx);
      expect(html, contains('<h4>Niveau 3</h4>'));
      expect(html, contains('<details open><summary>Résumé</summary>'));
      expect(html, contains('<span class="pagelink">Cible</span>'));
      expect(html, isNot(contains('nn:page:')));
      final txt = exportTxt(n, ctx);
      expect(txt, contains('Statut : En cours'));
      expect(txt, contains('▸ Résumé'));
      expect(txt, contains('    caché'));
      expect(txt, contains('voir Cible'));
    });
  });

  group('Fusion des nouveaux champs', () {
    Map<String, dynamic> row(Note n) => n.toRow();

    test('deux propriétés différentes modifiées : fusion sans conflit', () {
      final base = Note(id: 'n', title: 't', props: {'a': 1, 'b': 1});
      final l = Note(id: 'n', title: 't', props: {'a': 2, 'b': 1});
      final r = Note(id: 'n', title: 't', props: {'a': 1, 'b': 3});
      final m = mergeRows(EntityType.notes, row(base), row(l), row(r));
      expect(m.isClean, isTrue);
      expect(m.merged['props'], {'a': 2, 'b': 3});
    });

    test('même propriété modifiée différemment : conflit, rien n\'est écrasé', () {
      final base = Note(id: 'n', title: 't', props: {'a': 1});
      final l = Note(id: 'n', title: 't', props: {'a': 2});
      final r = Note(id: 'n', title: 't', props: {'a': 3});
      expect(mergeRows(EntityType.notes, row(base), row(l), row(r)).hardConflicts, contains('props'));
    });

    test('parent modifié d\'un côté, titre de l\'autre : les deux sont gardés', () {
      final base = Note(id: 'n', title: 't');
      final l = Note(id: 'n', title: 't', parentId: 'p');
      final r = Note(id: 'n', title: 'nouveau');
      final m = mergeRows(EntityType.notes, row(base), row(l), row(r));
      expect(m.isClean, isTrue);
      expect(m.merged['parent_id'], 'p');
      expect(m.merged['title'], 'nouveau');
    });
  });
}

Map<String, dynamic> n0(Map<String, dynamic> m) => Map<String, dynamic>.from(m);
