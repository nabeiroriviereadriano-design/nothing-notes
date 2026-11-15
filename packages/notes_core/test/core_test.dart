import 'dart:io';

import 'package:notes_core/notes_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('Mise en forme en ligne', () {
    String rebuilt(String s) => parseInline(s).map((t) => t.text).join();
    String visible(String s) => parseInline(s).where((t) => !t.marker).map((t) => t.text).join();

    test('le découpage redonne exactement le texte d\'origine', () {
      for (final s in [
        'simple',
        '**gras** et *italique* et ++souligné++ et ~~barré~~',
        'du `code` et un [lien](https://exemple.fr/a?b=1)',
        '**gras *et italique* imbriqués**',
        'astérisque seul * ou 2 * 3 * 4',
        '** pas fermé',
        '',
      ]) {
        expect(rebuilt(s), s);
      }
    });

    test('styles reconnus', () {
      final t = parseInline('a **b** *c* ++d++ ~~e~~ `f` [g](http://h)');
      InlineToken tok(String text) => t.firstWhere((x) => x.text == text && !x.marker);
      expect(tok('b').styles, {InlineStyle.bold});
      expect(tok('c').styles, {InlineStyle.italic});
      expect(tok('d').styles, {InlineStyle.underline});
      expect(tok('e').styles, {InlineStyle.strike});
      expect(tok('f').styles, {InlineStyle.code});
      expect(tok('g').link, 'http://h');
      expect(visible('a **b** *c* ++d++ ~~e~~ `f` [g](http://h)'), 'a b c d e f g');
    });

    test('imbrication', () {
      final t = parseInline('**gras *les deux***');
      expect(t.firstWhere((x) => x.text == 'les deux').styles, {InlineStyle.bold, InlineStyle.italic});
    });

    test('toggleWrap ajoute puis retire le marquage', () {
      final a = toggleWrap('un mot ici', 3, 6, '**');
      expect(a.text, 'un **mot** ici');
      expect((a.start, a.end), (5, 8));
      final b = toggleWrap(a.text, a.start, a.end, '**');
      expect(b.text, 'un mot ici');
      expect((b.start, b.end), (3, 6));
    });
  });

  group('Base locale', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('nn_store_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('les données et le journal des changements survivent à un redémarrage', () {
      final path = p.join(dir.path, 'a.db');
      var store = LocalStore.open(path);
      final device = store.deviceId;
      var repo = NotesRepository(store: store, filesDir: dir.path);
      final n = repo.createNote(title: 'Persistance', blocks: [Block(text: 'texte')]);
      expect(store.currentSeq, 1);
      store.close();

      store = LocalStore.open(path);
      repo = NotesRepository(store: store, filesDir: dir.path);
      expect(store.deviceId, device);
      expect(repo.note(n.id)!.title, 'Persistance');
      expect(store.currentSeq, 1, reason: 'journal des changements conservé');
      expect(store.get(EntityType.notes, n.id)!.rev, 1);
      store.close();
    });

    test('recherche instantanée : titre, contenu, accents, préfixes', () {
      final store = LocalStore.inMemory();
      final repo = NotesRepository(store: store, filesDir: dir.path);
      repo.createNote(title: 'BTS Électrotechnique', blocks: [Block(text: 'TIA Portal · **Grafcet** · Schémas')]);
      repo.createNote(title: 'Liste d\'achats', blocks: [Block(type: BlockType.todo, text: 'Bois'), Block(text: 'Vis')]);
      repo.createNote(title: 'Projet de jeu', blocks: [Block(text: 'FOREST ECHOES — level design')]);

      expect(repo.search('electro').single.title, 'BTS Électrotechnique');
      expect(repo.search('ÉLECTROTECHNIQUE').single.title, 'BTS Électrotechnique');
      expect(repo.search('grafcet').single.title, 'BTS Électrotechnique');
      expect(repo.search('schema').single.title, 'BTS Électrotechnique');
      expect(repo.search('bois').single.title, 'Liste d\'achats');
      expect(repo.search('forest lev').single.title, 'Projet de jeu');
      expect(repo.search('introuvable'), isEmpty);
      expect(repo.search('"'), isEmpty);
      expect(repo.search('d\'achats').single.title, 'Liste d\'achats');
      store.close();
    });

    test('enregistrer sans changement ne crée pas d\'opération', () {
      final store = LocalStore.inMemory();
      final repo = NotesRepository(store: store, filesDir: dir.path);
      final n = repo.createNote(title: 'Stable');
      final rev = store.get(EntityType.notes, n.id)!.rev;
      expect(repo.saveNote(repo.note(n.id)!), isFalse);
      expect(store.get(EntityType.notes, n.id)!.rev, rev);
      store.close();
    });

    test('corbeille : purge automatique après 30 jours', () {
      final store = LocalStore.inMemory();
      final repo = NotesRepository(store: store, filesDir: dir.path);
      final old = repo.createNote(title: 'Vieille');
      final recent = repo.createNote(title: 'Récente');
      final o = repo.note(old.id)!..trashedAt = DateTime.now().toUtc().subtract(const Duration(days: 31));
      repo.saveNote(o);
      repo.trashNote(recent.id);
      expect(repo.purgeExpiredTrash(), 1);
      expect(repo.note(old.id), isNull);
      expect(repo.note(recent.id)!.trashed, isTrue);
      store.close();
    });
  });

  group('Export', () {
    final n = Note(id: 'n', title: 'BTS Électrotechnique', blocks: [
      Block(type: BlockType.heading1, text: 'Révisions'),
      Block(type: BlockType.todo, text: 'Exercices **Grafcet**', checked: true),
      Block(type: BlockType.todo, text: 'TIA Portal'),
      Block(type: BlockType.numbered, text: 'un'),
      Block(type: BlockType.numbered, text: 'deux'),
      Block(type: BlockType.quote, text: 'citation ++soulignée++'),
      Block(type: BlockType.code, text: 'IF S1 THEN KM1 := TRUE;'),
      Block(type: BlockType.divider),
      Block(type: BlockType.table, rows: [
        ['Repère', 'Désignation'],
        ['KM1', 'Contacteur <moteur>'],
      ]),
      Block(text: 'Voir [la doc](https://exemple.fr)'),
    ]);
    final ctx = ExportContext(tagNames: ['BTS', 'Travail'], folderName: 'Cours');

    test('Markdown', () {
      final md = exportMarkdown(n, ctx);
      expect(md, startsWith('# BTS Électrotechnique'));
      expect(md, contains('## Révisions'));
      expect(md, contains('- [x] Exercices **Grafcet**'));
      expect(md, contains('- [ ] TIA Portal'));
      expect(md, contains('1. un\n2. deux'));
      expect(md, contains('> citation <u>soulignée</u>'));
      expect(md, contains('```\nIF S1 THEN KM1 := TRUE;\n```'));
      expect(md, contains('| Repère | Désignation |\n| --- | --- |\n| KM1 | Contacteur <moteur> |'));
      expect(md, contains('#BTS #Travail'));
    });

    test('TXT sans balises de mise en forme', () {
      final txt = exportTxt(n, ctx);
      expect(txt, contains('[x] Exercices Grafcet'));
      expect(txt, contains('> citation soulignée'));
      expect(txt, contains('Voir la doc'));
      expect(txt, isNot(contains('**')));
    });

    test('HTML échappé et structuré', () {
      final html = exportHtml(n, ctx);
      expect(html, contains('<h1>BTS Électrotechnique</h1>'));
      expect(html, contains('<strong>Grafcet</strong>'));
      expect(html, contains('<u>soulignée</u>'));
      expect(html, contains('Contacteur &lt;moteur&gt;'));
      expect(html, contains('<a href="https://exemple.fr">la doc</a>'));
      expect(html, contains('<ol>'));
      expect(html, contains('<pre><code>IF S1 THEN KM1 := TRUE;</code></pre>'));
    });

    test('nom de fichier sûr', () {
      expect(exportFileName(Note(id: 'x', title: 'a/b:c?'), 'md'), 'a b c.md');
      expect(exportFileName(Note(id: 'x', title: ''), 'txt'), 'Sans titre.txt');
    });
  });
}
