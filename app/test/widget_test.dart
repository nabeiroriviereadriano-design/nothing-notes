import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes_core/notes_core.dart';
import 'package:nothing_notes/editor/note_editor.dart';
import 'package:nothing_notes/screens/home_shell.dart';
import 'package:nothing_notes/services/update_checker.dart';
import 'package:nothing_notes/state/app_controller.dart';
import 'package:nothing_notes/theme.dart';

({AppController app, NotesRepository repo}) _setup() {
  final store = LocalStore.inMemory();
  final dir = Directory.systemTemp.createTempSync('nn_widget_');
  final repo = NotesRepository(store: store, userId: 'u', filesDir: dir.path);
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

Finder get _focusedField => find.byWidgetPredicate((w) => w is EditableText && w.focusNode.hasFocus);

void main() {
  testWidgets('bureau : trois colonnes, saisie, listes et enregistrement local', (tester) async {
    final s = _setup();
    final tag = s.repo.createTag('BTS', color: '#E60012');
    final n = s.repo.createNote(title: 'BTS Électrotechnique', tags: [tag.id]);
    s.repo.createNote(title: 'Liste d\'achats', blocks: [Block(type: BlockType.todo, text: 'Bois')]);
    s.app.selectedNoteId = n.id;

    await tester.binding.setSurfaceSize(const Size(1440, 900));
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
    expect(s.app.store!.pendingCount, greaterThan(0), reason: 'en file d\'attente de synchronisation');

    // Nouvelle note (Ctrl+N équivalent)
    s.app.newNote();
    await tester.pumpAndSettle();
    expect(s.repo.allNotes(), hasLength(3));
    tester.state<NoteEditorState>(find.byType(NoteEditor)).flush();
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('téléphone : liste, ouverture d\'une note, retour', (tester) async {
    final s = _setup();
    s.repo.createNote(title: 'Projet de jeu', blocks: [Block(text: 'FOREST ECHOES · Animations')]);
    s.repo.createNote(title: 'Idées', blocks: [Block(text: 'Haptique · Bureau · 3DS')]);

    await tester.binding.setSurfaceSize(const Size(400, 860));
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
    await tester.binding.setSurfaceSize(null);
  });

  test('comparaison de versions pour les mises à jour', () {
    expect(isNewer('v1.0.1', '1.0.0'), isTrue);
    expect(isNewer('v1.2.0', '1.10.0'), isFalse);
    expect(isNewer('1.0.0', '1.0.0'), isFalse);
  });
}
