import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes_core/notes_core.dart';
import 'package:nothing_notes/editor/note_editor.dart';
import 'package:nothing_notes/screens/home_shell.dart';
import 'package:nothing_notes/services/update_checker.dart';
import 'package:nothing_notes/state/app_controller.dart';
import 'package:nothing_notes/theme.dart';
import 'package:nothing_notes/widgets/note_list.dart';

({AppController app, NotesRepository repo}) _setup() {
  final store = LocalStore.inMemory();
  final dir = Directory.systemTemp.createTempSync('nn_widget_');
  final repo = NotesRepository(store: store, filesDir: dir.path);
  final app = AppController()
    ..store = store
    ..repo = repo;
  return (app: app, repo: repo);
}

Widget _wrap(AppController app, {Brightness b = Brightness.dark}) => AppScope(
      controller: app,
      child: ListenableBuilder(
        listenable: app,
        builder: (c, _) => MaterialApp(theme: buildTheme(b), home: const HomeShell()),
      ),
    );

void _size(WidgetTester tester, Size logical) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = logical;
  addTearDown(tester.view.reset);
}

Finder get _focusedField => find.byWidgetPredicate((w) => w is EditableText && w.focusNode.hasFocus);

void main() {
  testWidgets('bureau : trois colonnes, saisie, listes et enregistrement local', (tester) async {
    final s = _setup();
    final tag = s.repo.createTag('BTS', color: '#E60012');
    final n = s.repo.createNote(title: 'BTS Électrotechnique', tags: [tag.id]);
    s.repo.createNote(title: 'Liste d\'achats', blocks: [Block(type: BlockType.todo, text: 'Bois')]);
    s.app.selectedNoteId = n.id;

    _size(tester, const Size(1440, 900));
    await tester.pumpWidget(_wrap(s.app));
    await tester.pumpAndSettle();

    expect(find.text('Toutes les notes'), findsOneWidget);
    expect(find.text('Liste d\'achats'), findsOneWidget);
    expect(find.byType(NoteEditor), findsOneWidget);

    // Titre → Entrée → premier bloc
    await tester.tap(find.widgetWithText(TextField, 'BTS Électrotechnique'));
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pumpAndSettle();

    // « [] » transforme le paragraphe en case à cocher, Entrée crée la suivante
    await tester.enterText(_focusedField, '[] ');
    await tester.pumpAndSettle();
    await tester.enterText(_focusedField, 'Réviser les schémas\nExercices Grafcet');
    await tester.pumpAndSettle();
    expect(find.byType(Checkbox), findsNWidgets(2));

    // Gras via la barre d'outils
    final editor = tester.state<NoteEditorState>(find.byType(NoteEditor));
    final field = tester.widget<EditableText>(_focusedField);
    field.controller.selection = const TextSelection(baseOffset: 0, extentOffset: 9);
    editor.wrapSelection('**');
    await tester.pumpAndSettle();

    editor.flush();
    final saved = s.repo.note(n.id)!;
    expect(saved.blocks.map((b) => b.type), [BlockType.todo, BlockType.todo]);
    expect(saved.blocks.map((b) => b.text), ['Réviser les schémas', '**Exercices** Grafcet']);
    expect(s.app.store!.get(EntityType.notes, n.id)!.rev, greaterThan(1), reason: 'enregistré dans la base locale');

    // Nouvelle note (Ctrl+N équivalent)
    s.app.newNote();
    await tester.pumpAndSettle();
    expect(s.repo.allNotes(), hasLength(3));
    tester.state<NoteEditorState>(find.byType(NoteEditor)).flush();
  });

  testWidgets('téléphone : liste, ouverture d\'une note, retour', (tester) async {
    final s = _setup();
    s.repo.createNote(title: 'Projet de jeu', blocks: [Block(text: 'FOREST ECHOES · Animations')]);
    s.repo.createNote(title: 'Idées', blocks: [Block(text: 'Haptique · Bureau · 3DS')]);

    _size(tester, const Size(400, 860));
    await tester.pumpWidget(_wrap(s.app, b: Brightness.light));
    await tester.pumpAndSettle();

    expect(find.text('Toutes'), findsOneWidget);
    expect(find.text('Projet de jeu'), findsOneWidget);
    expect(find.byType(NoteEditor), findsNothing);

    await tester.tap(find.text('Projet de jeu'));
    await tester.pumpAndSettle();
    expect(find.byType(NoteEditor), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Projet de jeu'), findsOneWidget);

    await tester.tap(find.byTooltip('Retour'));
    await tester.pumpAndSettle();
    expect(find.byType(NoteEditor), findsNothing);

    // Recherche instantanée
    s.app.setQuery('haptique');
    await tester.pumpAndSettle();
    expect(find.text('Idées'), findsOneWidget);
    expect(find.text('Projet de jeu'), findsNothing);
  });

  testWidgets('pages : sous-pages, fil d\'Ariane et rétroliens', (tester) async {
    final s = _setup();
    final parent = s.repo.createNote(title: 'Projet atelier');
    final child = s.repo.createSubPage(parent.id, title: 'Câblage');
    s.repo.createNote(title: 'Journal', blocks: [Block(text: 'voir ${pageLink('Câblage', child.id)}')]);
    s.app.selectedNoteId = child.id;
    _size(tester, const Size(1440, 900));
    await tester.pumpWidget(_wrap(s.app));
    await tester.pumpAndSettle();

    // Fil d'Ariane et « Mentionnée dans »
    expect(find.descendant(of: find.byType(NoteEditor), matching: find.text('Projet atelier')), findsOneWidget);
    expect(find.text('MENTIONNÉE DANS'), findsOneWidget);
    expect(find.descendant(of: find.byType(NoteEditor), matching: find.text('Journal')), findsOneWidget);
    // La sous-page n'encombre pas la liste principale
    expect(find.descendant(of: find.byType(NoteCard), matching: find.text('Câblage')), findsNothing);

    // Retour à la page parente par le fil d'Ariane, puis ouverture de la sous-page depuis la section
    await tester.tap(find.descendant(of: find.byType(NoteEditor), matching: find.text('Projet atelier')));
    await tester.pumpAndSettle();
    expect(s.app.selectedNoteId, parent.id);
    expect(find.text('SOUS-PAGES'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(NoteEditor), matching: find.text('Câblage')));
    await tester.pumpAndSettle();
    expect(s.app.selectedNoteId, child.id);
    tester.state<NoteEditorState>(find.byType(NoteEditor)).flush();
  });

  testWidgets('« / » ouvre le menu d\'insertion et crée un Titre 3', (tester) async {
    final s = _setup();
    final n = s.repo.createNote(title: 'Page', blocks: [Block(text: '')]);
    s.app.selectedNoteId = n.id;
    _size(tester, const Size(1440, 900));
    await tester.pumpWidget(_wrap(s.app));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextField, 'Page'));
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pumpAndSettle();
    await tester.enterText(_focusedField, '/');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('insert-h3')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('insert-h3')));
    await tester.pumpAndSettle();
    final editor = tester.state<NoteEditorState>(find.byType(NoteEditor));
    editor.flush();
    expect(s.repo.note(n.id)!.blocks.first.type, BlockType.heading3);
    expect(s.repo.note(n.id)!.blocks.first.text, '', reason: 'le « / » est retiré');
  });

  testWidgets('l\'éditeur ouvert ne réécrit jamais un champ modifié ailleurs (parent, icône, propriétés)', (tester) async {
    final s = _setup();
    final parent = s.repo.createNote(title: 'Parent');
    final n = s.repo.createNote(title: 'Enfant', blocks: [Block(text: 'texte')]);
    s.app.selectedNoteId = n.id;
    _size(tester, const Size(1440, 900));
    await tester.pumpWidget(_wrap(s.app));
    await tester.pumpAndSettle();

    // Modifications faites hors de l'éditeur (menu, autre appareil…)
    s.repo.movePage(n.id, parent.id);
    s.repo.setIcon(n.id, '🎯');
    s.repo.setProp(n.id, 'p1', 'valeur');
    await tester.pumpAndSettle();

    // Puis saisie dans l'éditeur
    await tester.enterText(find.widgetWithText(TextField, 'Enfant'), 'Enfant modifié');
    await tester.pumpAndSettle();
    tester.state<NoteEditorState>(find.byType(NoteEditor)).flush();
    final saved = s.repo.note(n.id)!;
    expect(saved.title, 'Enfant modifié');
    expect(saved.parentId, parent.id);
    expect(saved.icon, '🎯');
    expect(saved.props['p1'], 'valeur');
  });

  testWidgets('base de données : tableau, nouvelle entrée et ses propriétés', (tester) async {
    final s = _setup();
    final db = s.repo.createDatabase(title: 'Révisions');
    final st = s.repo.schemaOf(db.id).props.first;
    s.repo.addEntry(db.id, title: 'Maths', props: {st.id: st.options[1].id});
    s.app.selectedNoteId = db.id;
    _size(tester, const Size(1440, 900));
    await tester.pumpWidget(_wrap(s.app));
    await tester.pumpAndSettle();
    expect(find.text('Maths'), findsWidgets);
    expect(find.text('En cours'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('db-add-entry')));
    await tester.pumpAndSettle();
    final entry = s.repo.note(s.app.selectedNoteId!)!;
    expect(entry.parentId, db.id);
    expect(find.byKey(ValueKey('prop-${st.id}')), findsOneWidget, reason: 'propriétés affichées en tête de l\'entrée');
    tester.state<NoteEditorState>(find.byType(NoteEditor)).flush();
  });

  testWidgets('tâches : vue dédiée et filtres', (tester) async {
    final s = _setup();
    final a = Block(type: BlockType.todo, text: 'Commander le variateur')..task = TaskInfo(status: TaskStatus.doing, priority: 3);
    final b = Block(type: BlockType.todo, text: 'Mettre à jour le schéma', checked: true)..task = TaskInfo(status: TaskStatus.done);
    final c = Block(type: BlockType.todo, text: 'Case non suivie');
    s.repo.createNote(title: 'Atelier', blocks: [a, b, c]);
    s.app.view = NavView.tasks;
    _size(tester, const Size(1440, 900));
    await tester.pumpWidget(_wrap(s.app));
    await tester.pumpAndSettle();
    expect(find.text('Commander le variateur'), findsOneWidget);
    expect(find.text('Mettre à jour le schéma'), findsNothing, reason: 'filtre par défaut : tâches ouvertes');
    expect(find.text('Case non suivie'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('task-filter-done')));
    await tester.pumpAndSettle();
    expect(find.text('Mettre à jour le schéma'), findsOneWidget);
    expect(find.text('Commander le variateur'), findsNothing);
  });

  testWidgets('téléphone : nouvelle page à partir d\'un modèle', (tester) async {
    final s = _setup();
    _size(tester, const Size(400, 860));
    await tester.pumpWidget(_wrap(s.app));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('new-tpl:builtin:meeting')));
    await tester.pumpAndSettle();
    final n = s.repo.note(s.app.selectedNoteId!)!;
    expect(n.title, startsWith('Réunion du'));
    expect(n.blocks.first.text, 'Participants');
    tester.state<NoteEditorState>(find.byType(NoteEditor)).flush();
  });

  test('comparaison de versions pour les mises à jour', () {
    expect(isNewer('v1.0.1', '1.0.0'), isTrue);
    expect(isNewer('v1.2.0', '1.10.0'), isFalse);
    expect(isNewer('1.0.0', '1.0.0'), isFalse);
  });
}
