// Captures d'écran de l'interface réelle (polices et icônes chargées),
// générées en CI : flutter test --update-goldens screenshot_test/
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes_core/notes_core.dart';
import 'package:nothing_notes/screens/devices_screen.dart';
import 'package:nothing_notes/screens/home_shell.dart';
import 'package:nothing_notes/state/app_controller.dart';
import 'package:nothing_notes/theme.dart';

Future<void> _loadFonts() async {
  Future<void> load(String family, List<String> files) async {
    final l = FontLoader(family);
    for (final f in files) {
      l.addFont(rootBundle.load('assets/fonts/$f'));
    }
    await l.load();
  }

  await load('Inter', ['Inter-Regular.ttf', 'Inter-Medium.ttf', 'Inter-SemiBold.ttf', 'Inter-Italic.ttf']);
  await load('Doto', ['Doto-Bold.ttf', 'Doto-Black.ttf']);
  await load('JetBrainsMono', ['JetBrainsMono-Regular.ttf']);
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null) {
    final f = File('$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
    if (f.existsSync()) {
      final l = FontLoader('MaterialIcons')..addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
      await l.load();
    }
  }
}

late ({String projet, String etape, String db}) demoIds;

AppController _demo() {
  final store = LocalStore.inMemory();
  final dir = Directory.systemTemp.createTempSync('nn_shots_');
  final repo = NotesRepository(store: store, filesDir: dir.path);
  final travail = repo.createTag('Travail', color: '#E60012');
  final bts = repo.createTag('BTS', color: '#858585');
  final perso = repo.createTag('Perso', color: '#F5F5F5');
  final projets = repo.createTag('Projets', color: '#4A4A4A');
  final cours = repo.createFolder('Cours');
  repo.createFolder('Automatisme', parentId: cours.id);
  repo.createFolder('Atelier');
  repo.createNote(title: 'Idées', tags: [perso.id], blocks: [
    Block(type: BlockType.bullet, text: 'Haptique'),
    Block(type: BlockType.bullet, text: 'Bureau'),
    Block(type: BlockType.bullet, text: '3DS'),
  ]);
  repo.createNote(title: 'Liste d\'achats', tags: [perso.id], blocks: [
    Block(type: BlockType.todo, text: 'Bois'),
    Block(type: BlockType.todo, text: 'Vis', checked: true),
    Block(type: BlockType.todo, text: 'Ampli · DAC'),
  ]);
  final jeu = repo.createNote(title: 'Projet de jeu', tags: [projets.id], blocks: [
    Block(text: 'FOREST ECHOES · Animations · Level design'),
  ]);
  repo.setFavorite(jeu.id, true);
  final main = repo.createNote(title: 'BTS Électrotechnique', folderId: cours.id, tags: [bts.id, travail.id], blocks: [
    Block(type: BlockType.todo, text: 'Réviser les schémas de commande'),
    Block(type: BlockType.todo, text: 'Exercices **Grafcet**', checked: true),
    Block(type: BlockType.todo, text: 'TIA Portal (API / IHM)'),
    Block(type: BlockType.todo, text: 'Questions types d\'examen'),
    Block(type: BlockType.heading2, text: 'Démarrage moteur'),
    Block(text: 'Appui sur ++S2++ : enclenchement de *KM1*, auto-maintien. Voir [la fiche](https://exemple.fr).'),
    Block(type: BlockType.code, text: 'IF S2 AND NOT S1 THEN\n  KM1 := TRUE;\nEND_IF;'),
    Block(type: BlockType.table, rows: [
      ['Repère', 'Désignation'],
      ['KM1', 'Contacteur moteur'],
      ['S1', 'Arrêt (NF)'],
    ]),
  ]);
  // Pages, sous-pages, base de données et tâches (données de démonstration).
  final projet = repo.createNote(title: 'Projet atelier', blocks: [
    Block(type: BlockType.heading1, text: 'Objectif'),
    Block(text: 'Remettre en service le tapis convoyeur · voir ${pageLink('BTS Électrotechnique', main.id)}'),
    Block(type: BlockType.heading3, text: 'Étapes'),
    Block(type: BlockType.toggle, text: 'Points de contrôle', extra: {'body': 'Serrage bornier · Test arrêt d\'urgence'}),
  ]);
  final t1 = Block(type: BlockType.todo, text: 'Commander le variateur')
    ..task = TaskInfo(status: TaskStatus.doing, due: DateTime.now().add(const Duration(days: 2)), priority: 3);
  final t2 = Block(type: BlockType.todo, text: 'Câbler le capteur inductif')
    ..task = TaskInfo(status: TaskStatus.todo, due: DateTime.now().subtract(const Duration(days: 1)), priority: 2);
  final t3 = Block(type: BlockType.todo, text: 'Mettre à jour le schéma', checked: true)..task = TaskInfo(status: TaskStatus.done);
  final etape = repo.createSubPage(projet.id, title: 'Câblage', blocks: [t1, t2, t3]);
  repo.createSubPage(projet.id, title: 'Programme API');
  final db = repo.createDatabase(title: 'Révisions BTS', parentId: projet.id);
  final schema = repo.schemaOf(db.id);
  final status = schema.props[0], date = schema.props[1];
  final coef = repo.addProp(db.id, 'Coefficient', PropType.number);
  for (final (t, st, d, c) in [
    ('Électrotechnique', 2, '2026-12-03', 6),
    ('Mathématiques', 1, '2026-12-08', 3),
    ('Physique appliquée', 0, '2026-12-15', 4),
    ('Anglais', 0, '2026-12-17', 2),
  ]) {
    repo.addEntry(db.id, title: t, props: {status.id: status.options[st].id, date.id: d, coef.id: c});
  }
  demoIds = (projet: projet.id, etape: etape.id, db: db.id);
  final app = AppController()
    ..store = store
    ..repo = repo
    ..selectedNoteId = main.id
    ..syncStatus = SyncStatus(SyncState.synced, peers: 1, connected: 1, lastSync: DateTime.now());
  return app;
}

Future<void> _shot(WidgetTester tester, String name, Size size, Brightness b, Widget home, AppController app) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(AppScope(
    controller: app,
    child: ListenableBuilder(
      listenable: app,
      builder: (c, _) => MaterialApp(debugShowCheckedModeBanner: false, theme: buildTheme(b), home: home),
    ),
  ));
  await tester.pumpAndSettle();
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
}

void main() {
  setUpAll(_loadFonts);

  testWidgets('windows-sombre', (t) => _shot(t, 'windows-sombre', const Size(1440, 900), Brightness.dark, const HomeShell(), _demo()));
  testWidgets('windows-clair', (t) => _shot(t, 'windows-clair', const Size(1440, 900), Brightness.light, const HomeShell(), _demo()));
  testWidgets('android-liste-sombre', (t) {
    final app = _demo()..selectedNoteId = null;
    return _shot(t, 'android-liste-sombre', const Size(400, 860), Brightness.dark, const HomeShell(), app);
  });
  testWidgets('android-note-clair', (t) => _shot(t, 'android-note-clair', const Size(400, 860), Brightness.light, const HomeShell(), _demo()));
  testWidgets('android-appareils', (t) => _shot(t, 'android-appareils', const Size(400, 860), Brightness.dark, const DevicesScreen(), _demo()));
  testWidgets('windows-page-sous-pages', (t) {
    final app = _demo();
    app.selectedNoteId = demoIds.projet;
    return _shot(t, 'windows-page-sous-pages', const Size(1440, 900), Brightness.dark, const HomeShell(), app);
  });
  testWidgets('windows-base-de-donnees', (t) {
    final app = _demo();
    app.selectedNoteId = demoIds.db;
    return _shot(t, 'windows-base-de-donnees', const Size(1440, 900), Brightness.light, const HomeShell(), app);
  });
  testWidgets('windows-taches', (t) {
    final app = _demo()..view = NavView.tasks;
    app.selectedNoteId = demoIds.etape;
    return _shot(t, 'windows-taches', const Size(1440, 900), Brightness.dark, const HomeShell(), app);
  });
  testWidgets('android-base-de-donnees', (t) {
    final app = _demo();
    app.selectedNoteId = demoIds.db;
    return _shot(t, 'android-base-de-donnees', const Size(400, 860), Brightness.dark, const HomeShell(), app);
  });
  testWidgets('android-insertion-bloc', (t) async {
    final app = _demo();
    app.selectedNoteId = demoIds.projet;
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(400, 860);
    addTearDown(t.view.reset);
    await t.pumpWidget(AppScope(
      controller: app,
      child: ListenableBuilder(
        listenable: app,
        builder: (c, _) => MaterialApp(debugShowCheckedModeBanner: false, theme: buildTheme(Brightness.dark), home: const HomeShell()),
      ),
    ));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('insert-block')));
    await t.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/android-insertion-bloc.png'));
  });
  testWidgets('android-nouvelle-page', (t) async {
    final app = _demo()..selectedNoteId = null;
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(400, 860);
    addTearDown(t.view.reset);
    await t.pumpWidget(AppScope(
      controller: app,
      child: ListenableBuilder(
        listenable: app,
        builder: (c, _) => MaterialApp(debugShowCheckedModeBanner: false, theme: buildTheme(Brightness.light), home: const HomeShell()),
      ),
    ));
    await t.pumpAndSettle();
    await t.tap(find.byType(FloatingActionButton));
    await t.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/android-nouvelle-page.png'));
  });
  testWidgets('windows-code', (t) => _shot(
      t,
      'windows-code',
      const Size(900, 560),
      Brightness.dark,
      const Scaffold(
        body: Center(
          child: Card(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: PairingCodeView(code: '482915', remaining: Duration(minutes: 4, seconds: 37)),
            ),
          ),
        ),
      ),
      _demo()));
}
