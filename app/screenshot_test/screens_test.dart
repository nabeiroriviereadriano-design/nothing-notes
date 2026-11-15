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
