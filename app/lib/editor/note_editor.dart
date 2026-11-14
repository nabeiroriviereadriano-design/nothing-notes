import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:notes_core/notes_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/exporter.dart';
import '../state/app_controller.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/dialogs.dart';
import 'inline_controller.dart';

const _listTypes = {BlockType.bullet, BlockType.numbered, BlockType.todo};
const _noteFields = ['title', 'content', 'folder_id', 'tags', 'favorite', 'archived', 'trashed_at', 'purged'];

/// Bloc de l'éditeur : le bloc de données et ses contrôleurs d'interface.
class _EB {
  _EB(this.block)
      : controller = InlineController(text: block.text, formatting: block.type != BlockType.code),
        focus = FocusNode();

  final Block block;
  final InlineController controller;
  final FocusNode focus;
  List<List<TextEditingController>>? cells;

  void dispose() {
    controller.dispose();
    focus.dispose();
    for (final r in cells ?? const <List<TextEditingController>>[]) {
      for (final c in r) {
        c.dispose();
      }
    }
  }
}

/// Éditeur de note par blocs, commun à Android et Windows.
class NoteEditor extends StatefulWidget {
  const NoteEditor({super.key, required this.noteId, this.onBack});
  final String noteId;

  /// Bouton retour (mise en page mobile).
  final VoidCallback? onBack;

  @override
  State<NoteEditor> createState() => NoteEditorState();
}

class NoteEditorState extends State<NoteEditor> {
  late NotesRepository repo;
  Note? note;
  final _title = TextEditingController();
  final _titleFocus = FocusNode();
  final _blocks = <_EB>[];
  final _scroll = ScrollController();
  Timer? _saveTimer;
  Map<String, dynamic>? _lastSaved;
  StreamSubscription<EntityType>? _sub;
  int _focused = -1;
  bool _applying = false;

  final _undo = <Map<String, dynamic>>[];
  final _redo = <Map<String, dynamic>>[];
  DateTime _lastSnapshot = DateTime.fromMillisecondsSinceEpoch(0);

  bool get _readOnly => note?.trashed ?? true;

  @override
  void initState() {
    super.initState();
    _title.addListener(_onTitleChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final r = AppScope.read(context).repo!;
    if (note == null) {
      repo = r;
      _load();
      _sub = repo.changes.listen((t) {
        if (t == EntityType.notes) _onStoreChange();
      });
    }
  }

  @override
  void didUpdateWidget(NoteEditor old) {
    super.didUpdateWidget(old);
    if (old.noteId != widget.noteId) {
      flush();
      _undo.clear();
      _redo.clear();
      _load();
    }
  }

  @override
  void dispose() {
    flush();
    _sub?.cancel();
    _saveTimer?.cancel();
    for (final b in _blocks) {
      b.dispose();
    }
    _title.dispose();
    _titleFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ chargement
  void _load() {
    final n = repo.note(widget.noteId);
    note = n;
    if (n == null) return;
    _lastSaved = n.toRow();
    _applying = true;
    _title.text = n.title;
    _applying = false;
    for (final b in _blocks) {
      b.dispose();
    }
    _blocks
      ..clear()
      ..addAll(n.blocks.map(_makeEB));
    if (_blocks.isEmpty) {
      final b = Block();
      n.blocks.add(b);
      _blocks.add(_makeEB(b));
    }
    _focused = -1;
    if (mounted) setState(() {});
    // Nouvelle note vide : focus direct sur le titre.
    if (n.title.isEmpty && plainText(n.blocks).isEmpty && !n.trashed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _titleFocus.requestFocus();
      });
    }
  }

  _EB _makeEB(Block b) {
    final eb = _EB(b);
    if (b.type == BlockType.table) {
      b.rows ??= [
        ['', ''],
        ['', ''],
      ];
      eb.cells = [
        for (var r = 0; r < b.rows!.length; r++)
          [for (var c = 0; c < b.rows![r].length; c++) _cellController(eb, r, c)]
      ];
    }
    eb.controller.addListener(() => _onBlockText(eb));
    eb.focus.addListener(() {
      eb.controller.revealMarkers = eb.focus.hasFocus;
      if (eb.focus.hasFocus) {
        final i = _blocks.indexOf(eb);
        if (i != _focused && mounted) setState(() => _focused = i);
      }
    });
    eb.focus.onKeyEvent = (node, event) => _onKey(eb, event);
    return eb;
  }

  TextEditingController _cellController(_EB eb, int r, int c) {
    final ctl = TextEditingController(text: eb.block.rows![r][c]);
    ctl.addListener(() {
      final rows = eb.block.rows!;
      if (r < rows.length && c < rows[r].length && rows[r][c] != ctl.text) {
        _snapshot();
        rows[r][c] = ctl.text;
        _scheduleSave();
      }
    });
    return ctl;
  }

  // ------------------------------------------------------------------ synchro externe
  /// La note a changé dans la base (autre appareil, liste, fusion…).
  void _onStoreChange() {
    if (!mounted || note == null) return;
    final rec = repo.store.get(EntityType.notes, widget.noteId);
    if (rec == null) return;
    final storeRow = rec.data;
    final hadConflict = note!.hasConflict;
    note!.conflictRow = rec.conflict;
    note!.dirty = rec.dirty;
    if (asBool(storeRow['purged'])) {
      setState(() => note = null);
      return;
    }
    final same = _lastSaved != null && _noteFields.every((f) => jsonEq(storeRow[f], _lastSaved![f]));
    if (same) {
      if (hadConflict != note!.hasConflict) setState(() {});
      return;
    }
    Map<String, dynamic> target = storeRow;
    var mustSave = false;
    if (_saveTimer?.isActive ?? false) {
      // Modifications locales pas encore enregistrées : fusion à trois voies.
      _collect();
      final out = mergeRows(EntityType.notes, _lastSaved, note!.toRow(), storeRow);
      target = out.isClean ? out.merged : note!.toRow();
      mustSave = true;
    }
    _lastSaved = storeRow;
    _applyRow(target);
    if (mustSave) _scheduleSave(immediate: true);
  }

  void _applyRow(Map<String, dynamic> row) {
    final fresh = Note.fromRow(row, dirty: note!.dirty, conflict: note!.conflictRow);
    _applying = true;
    if (_title.text != fresh.title) {
      final sel = _title.selection;
      _title.value = TextEditingValue(
        text: fresh.title,
        selection: TextSelection.collapsed(offset: sel.baseOffset.clamp(0, fresh.title.length)),
      );
    }
    final old = {for (final b in _blocks) b.block.id: b};
    final next = <_EB>[];
    for (final b in fresh.blocks) {
      final existing = old.remove(b.id);
      if (existing != null &&
          existing.block.type == b.type &&
          (b.type != BlockType.table || jsonEq(existing.block.rows, b.rows))) {
        existing.block
          ..text = b.text
          ..checked = b.checked
          ..attachmentId = b.attachmentId;
        if (existing.controller.text != b.text) {
          final off = existing.controller.selection.baseOffset.clamp(0, b.text.length);
          existing.controller.value =
              TextEditingValue(text: b.text, selection: TextSelection.collapsed(offset: off));
        }
        next.add(existing);
      } else {
        if (existing != null) old[b.id] = existing;
        next.add(_makeEB(b));
      }
    }
    for (final b in old.values) {
      b.dispose();
    }
    _blocks
      ..clear()
      ..addAll(next);
    note!
      ..title = fresh.title
      ..blocks = [for (final b in _blocks) b.block]
      ..folderId = fresh.folderId
      ..tags = fresh.tags
      ..favorite = fresh.favorite
      ..archived = fresh.archived
      ..trashedAt = fresh.trashedAt
      ..updatedAt = fresh.updatedAt
      ..version = fresh.version;
    _applying = false;
    _focused = _blocks.indexWhere((b) => b.focus.hasFocus);
    setState(() {});
  }

  // ------------------------------------------------------------------ enregistrement
  void _collect() {
    final n = note;
    if (n == null) return;
    n.title = _title.text;
    n.blocks = [for (final b in _blocks) b.block];
  }

  void _scheduleSave({bool immediate = false}) {
    if (note == null || _readOnly) return;
    _saveTimer?.cancel();
    if (immediate) {
      flush();
    } else {
      _saveTimer = Timer(const Duration(milliseconds: 350), flush);
    }
  }

  /// Enregistre immédiatement dans la base locale (Ctrl+S).
  void flush() {
    _saveTimer?.cancel();
    _saveTimer = null;
    final n = note;
    if (n == null || _readOnly) return;
    if (repo.store.isClosed) return;
    _collect();
    repo.saveNote(n);
    _lastSaved = n.toRow();
  }

  // ------------------------------------------------------------------ annuler / rétablir
  Map<String, dynamic> _state() {
    _collect();
    return {'title': note!.title, 'content': contentFromBlocks(note!.blocks)};
  }

  void _snapshot({bool force = false}) {
    if (note == null || _applying) return;
    final now = DateTime.now();
    if (!force && now.difference(_lastSnapshot) < const Duration(milliseconds: 1200)) return;
    _lastSnapshot = now;
    _undo.add(jsonClone(_state()));
    if (_undo.length > 100) _undo.removeAt(0);
    _redo.clear();
  }

  void undo() => _restoreFrom(_undo, _redo);
  void redo() => _restoreFrom(_redo, _undo);

  void _restoreFrom(List<Map<String, dynamic>> from, List<Map<String, dynamic>> to) {
    if (from.isEmpty || note == null) return;
    to.add(jsonClone(_state()));
    final s = from.removeLast();
    final row = note!.toRow()
      ..['title'] = s['title']
      ..['content'] = s['content'];
    _applyRow(row);
    _lastSnapshot = DateTime.now();
    _scheduleSave(immediate: true);
  }

  // ------------------------------------------------------------------ saisie
  void _onTitleChanged() {
    if (_applying || note == null) return;
    if (_title.text.contains('\n')) {
      final t = _title.text.replaceAll('\n', ' ').trimRight();
      _title.value = TextEditingValue(text: t, selection: TextSelection.collapsed(offset: t.length));
      if (_blocks.isNotEmpty) _focusBlock(0, atStart: true);
      return;
    }
    if (_title.text != note!.title) {
      _snapshot();
      _scheduleSave();
    }
  }

  void _onBlockText(_EB eb) {
    if (_applying) return;
    final text = eb.controller.text;
    if (text == eb.block.text) return;
    final i = _blocks.indexOf(eb);
    if (i < 0) return;
    // Entrée : nouveau bloc (sauf dans un bloc de code)
    if (eb.block.type != BlockType.code && text.contains('\n')) {
      final cut = text.indexOf('\n');
      final before = text.substring(0, cut);
      final after = text.substring(cut + 1).replaceAll('\n', ' ');
      _snapshot(force: true);
      _applying = true;
      if (_listTypes.contains(eb.block.type) && before.isEmpty && after.isEmpty) {
        // Entrée sur un élément de liste vide : on sort de la liste
        eb.controller.value = const TextEditingValue(text: '', selection: TextSelection.collapsed(offset: 0));
        eb.block
          ..text = ''
          ..type = BlockType.paragraph;
        _applying = false;
        setState(() {});
        _scheduleSave();
        return;
      }
      eb.controller.value = TextEditingValue(text: before, selection: TextSelection.collapsed(offset: before.length));
      eb.block.text = before;
      _applying = false;
      final type = _listTypes.contains(eb.block.type) ? eb.block.type : BlockType.paragraph;
      _insertBlock(i + 1, Block(type: type, text: after), focusAtStart: true);
      return;
    }
    _snapshot();
    eb.block.text = text;
    _scheduleSave();
    if (eb.block.type == BlockType.paragraph) _autoFormat(eb);
  }

  /// Raccourcis de saisie façon Markdown : « - », « 1. », « [] », « # », « > », « ``` », « --- ».
  void _autoFormat(_EB eb) {
    final t = eb.controller.text;
    const rules = {
      '- ': BlockType.bullet,
      '* ': BlockType.bullet,
      '1. ': BlockType.numbered,
      '[] ': BlockType.todo,
      '[ ] ': BlockType.todo,
      '# ': BlockType.heading1,
      '## ': BlockType.heading2,
      '> ': BlockType.quote,
      '```': BlockType.code,
    };
    for (final e in rules.entries) {
      if (t.startsWith(e.key) && eb.controller.selection.baseOffset == e.key.length) {
        final rest = t.substring(e.key.length);
        _setType(eb, e.value, text: rest);
        return;
      }
    }
    if (t == '---') {
      final i = _blocks.indexOf(eb);
      _setType(eb, BlockType.divider, text: '');
      _insertBlock(i + 1, Block(), focusAtStart: true);
    }
  }

  KeyEventResult _onKey(_EB eb, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final ctrl = HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final key = event.logicalKey;
    final sel = eb.controller.selection;
    final i = _blocks.indexOf(eb);

    if (ctrl && eb.block.type != BlockType.code) {
      String? marker;
      if (key == LogicalKeyboardKey.keyB) marker = '**';
      if (key == LogicalKeyboardKey.keyI) marker = '*';
      if (key == LogicalKeyboardKey.keyU) marker = '++';
      if (key == LogicalKeyboardKey.keyE) marker = '`';
      if (key == LogicalKeyboardKey.keyX && shift) marker = '~~';
      if (marker != null) {
        wrapSelection(marker);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyK) {
        insertLink();
        return KeyEventResult.handled;
      }
    }
    if (ctrl && key == LogicalKeyboardKey.enter && eb.block.type == BlockType.code) {
      _insertBlock(i + 1, Block(), focusAtStart: true);
      return KeyEventResult.handled;
    }
    if (!sel.isValid || !sel.isCollapsed) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.backspace && sel.baseOffset == 0) {
      _backspaceAtStart(eb);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp && sel.baseOffset == 0 && i > 0) {
      _focusBlock(i - 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp && sel.baseOffset == 0 && i == 0) {
      _titleFocus.requestFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown && sel.baseOffset == eb.controller.text.length && i < _blocks.length - 1) {
      _focusBlock(i + 1, atStart: true);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _backspaceAtStart(_EB eb) {
    final i = _blocks.indexOf(eb);
    if (eb.block.type != BlockType.paragraph && eb.block.isTextual) {
      _setType(eb, BlockType.paragraph);
      return;
    }
    if (i <= 0) return;
    final prev = _blocks[i - 1];
    _snapshot(force: true);
    if (!prev.block.isTextual) {
      if (eb.controller.text.isEmpty) {
        _removeAt(i, focusPrevious: false);
      }
      setState(() => _focused = i - 1);
      return;
    }
    final join = prev.controller.text.length;
    final merged = prev.controller.text + eb.controller.text;
    _applying = true;
    prev.controller.value = TextEditingValue(text: merged, selection: TextSelection.collapsed(offset: join));
    prev.block.text = merged;
    _applying = false;
    _removeAt(i, focusPrevious: false);
    prev.focus.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      prev.controller.selection = TextSelection.collapsed(offset: join);
    });
  }

  // ------------------------------------------------------------------ opérations sur les blocs
  void _focusBlock(int i, {bool atStart = false}) {
    if (i < 0 || i >= _blocks.length) return;
    final eb = _blocks[i];
    setState(() => _focused = i);
    if (!eb.block.isTextual) return;
    eb.focus.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final len = eb.controller.text.length;
      eb.controller.selection = TextSelection.collapsed(offset: atStart ? 0 : len);
    });
  }

  void _insertBlock(int index, Block b, {bool focusAtStart = false}) {
    if (_readOnly) return;
    _snapshot(force: true);
    final eb = _makeEB(b);
    setState(() => _blocks.insert(index.clamp(0, _blocks.length), eb));
    _scheduleSave();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusBlock(_blocks.indexOf(eb), atStart: focusAtStart);
    });
  }

  void _removeAt(int i, {bool focusPrevious = true}) {
    if (i < 0 || i >= _blocks.length) return;
    _snapshot(force: true);
    final eb = _blocks.removeAt(i);
    WidgetsBinding.instance.addPostFrameCallback((_) => eb.dispose());
    if (_blocks.isEmpty) _blocks.add(_makeEB(Block()));
    setState(() => _focused = (i - 1).clamp(0, _blocks.length - 1));
    _scheduleSave();
    if (focusPrevious) _focusBlock(_focused);
  }

  void _setType(_EB eb, String type, {String? text}) {
    _snapshot(force: true);
    _applying = true;
    eb.block.type = type;
    eb.controller.formatting = type != BlockType.code;
    if (text != null) {
      eb.block.text = text;
      eb.controller.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
    }
    _applying = false;
    setState(() {});
    _scheduleSave();
  }

  int get _insertIndex => _focused >= 0 && _focused < _blocks.length ? _focused + 1 : _blocks.length;
  _EB? get _current => _focused >= 0 && _focused < _blocks.length ? _blocks[_focused] : null;

  /// Transforme le bloc courant (ou en ajoute un) au type demandé.
  void applyBlockType(String type) {
    if (_readOnly) return;
    final cur = _current;
    if (cur != null && cur.block.isTextual && BlockType.textual.contains(type)) {
      _setType(cur, cur.block.type == type && type != BlockType.paragraph ? BlockType.paragraph : type);
      cur.focus.requestFocus();
    } else {
      _insertBlock(_insertIndex, Block(type: type), focusAtStart: true);
    }
  }

  void insertDivider() {
    final i = _insertIndex;
    _insertBlock(i, Block(type: BlockType.divider));
    _insertBlock(i + 1, Block(), focusAtStart: true);
  }

  void insertTable() {
    _insertBlock(
      _insertIndex,
      Block(type: BlockType.table, rows: [
        ['', '', ''],
        ['', '', ''],
        ['', '', ''],
      ]),
    );
  }

  void wrapSelection(String marker) {
    final eb = _current;
    if (eb == null || !eb.block.isTextual || eb.block.type == BlockType.code) return;
    final sel = eb.controller.selection;
    if (!sel.isValid) return;
    _snapshot(force: true);
    final r = toggleWrap(eb.controller.text, sel.start, sel.end, marker);
    eb.controller.value = TextEditingValue(text: r.text, selection: TextSelection(baseOffset: r.start, extentOffset: r.end));
    eb.focus.requestFocus();
  }

  Future<void> insertLink() async {
    final eb = _current;
    if (eb == null || !eb.block.isTextual || eb.block.type == BlockType.code) {
      toast(context, 'Placez le curseur dans un paragraphe');
      return;
    }
    final sel = eb.controller.selection;
    final selected = sel.isValid && !sel.isCollapsed ? sel.textInside(eb.controller.text) : '';
    final url = await promptText(context, title: 'Ajouter un lien', hint: 'https://…', ok: 'Insérer');
    if (url == null || url.isEmpty) return;
    final fixed = url.contains('://') ? url : 'https://$url';
    final label = selected.isEmpty ? fixed : selected;
    final text = eb.controller.text;
    final start = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;
    final md = '[$label]($fixed)';
    _snapshot(force: true);
    eb.controller.value = TextEditingValue(
      text: text.substring(0, start) + md + text.substring(end),
      selection: TextSelection.collapsed(offset: start + md.length),
    );
    eb.focus.requestFocus();
  }

  Future<void> addAttachment({required bool image}) async {
    if (_readOnly || note == null) return;
    final files = await FilePicker.pickFiles(type: image ? FileType.image : FileType.any);
    if (files.isEmpty) return;
    var index = _insertIndex;
    for (final f in files) {
      final Uint8List bytes;
      try {
        bytes = await f.readAsBytes();
      } catch (_) {
        if (mounted) toast(context, 'Lecture impossible : ${f.name}');
        continue;
      }
      if (!mounted) return;
      if (bytes.length > 50 * 1024 * 1024) {
        if (mounted) toast(context, '${f.name} dépasse 50 Mo');
        continue;
      }
      final a = repo.addAttachment(note!.id, fileName: f.name, bytes: bytes);
      final type = image || a.isImage ? BlockType.image : BlockType.file;
      _insertBlock(index++, Block(type: type, attachmentId: a.id));
    }
  }

  void moveCurrent(int delta) {
    final i = _focused;
    final j = i + delta;
    if (i < 0 || j < 0 || j >= _blocks.length) return;
    _snapshot(force: true);
    setState(() {
      final eb = _blocks.removeAt(i);
      _blocks.insert(j, eb);
      _focused = j;
    });
    _scheduleSave();
  }

  void deleteCurrent() {
    final eb = _current;
    if (eb == null) return;
    if (eb.block.type == BlockType.image || eb.block.type == BlockType.file) {
      if (eb.block.attachmentId != null) repo.deleteAttachment(eb.block.attachmentId!);
    }
    _removeAt(_focused);
  }

  // ------------------------------------------------------------------ interface
  @override
  Widget build(BuildContext context) {
    final n = note;
    final nn = context.nn;
    if (n == null) {
      return const EmptyState(icon: Icons.delete_outline_rounded, title: 'Note supprimée');
    }
    AppScope.of(context); // reconstruit l'éditeur quand les données changent
    final wide = MediaQuery.of(context).size.width >= 700;
    final tags = {for (final t in repo.tags()) t.id: t};
    final folder = repo.folders().where((f) => f.id == n.folderId).firstOrNull;

    return Column(children: [
      _Header(editor: this, note: n, tags: tags, onBack: widget.onBack),
      if (n.hasConflict) _ConflictBanner(onTap: () => showConflictDialog(context, repo, n.id)),
      if (n.trashed) _TrashBanner(repo: repo, note: n),
      Expanded(
        child: Scrollbar(
          controller: _scroll,
          child: ListView(
            controller: _scroll,
            padding: EdgeInsets.fromLTRB(wide ? 28 : 20, 8, wide ? 28 : 20, 120),
            children: [
              TextField(
                controller: _title,
                focusNode: _titleFocus,
                readOnly: _readOnly,
                maxLines: null,
                textInputAction: TextInputAction.next,
                onSubmitted: (_) => _focusBlock(0, atStart: true),
                style: TextStyle(fontSize: wide ? 30 : 26, fontWeight: FontWeight.w500, letterSpacing: 0.2, color: nn.fg),
                cursorWidth: 2.5,
                decoration: InputDecoration(
                  hintText: 'Titre',
                  hintStyle: TextStyle(color: nn.mid),
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Text(
                  [
                    'Modifiée ${formatDate(n.updatedAt)}',
                    if (folder != null) folder.name,
                    n.hasConflict ? 'conflit à résoudre' : (n.dirty ? 'en attente de synchronisation' : 'synchronisée'),
                  ].join('  ·  '),
                  style: TextStyle(fontSize: 12, color: n.hasConflict ? NColors.red : nn.mid),
                ),
              ),
              for (var i = 0; i < _blocks.length; i++) _buildBlock(context, i, tags),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  if (_readOnly) return;
                  final last = _blocks.isEmpty ? null : _blocks.last;
                  if (last != null && last.block.type == BlockType.paragraph && last.controller.text.isEmpty) {
                    _focusBlock(_blocks.length - 1);
                  } else {
                    _insertBlock(_blocks.length, Block(), focusAtStart: true);
                  }
                },
                child: const SizedBox(height: 160),
              ),
            ],
          ),
        ),
      ),
      if (!_readOnly) _Toolbar(editor: this, wide: wide, link: _current?.controller.linkAtCursor()),
    ]);
  }

  int _numberFor(int i) {
    var k = 1;
    for (var j = i - 1; j >= 0 && _blocks[j].block.type == BlockType.numbered; j--) {
      k++;
    }
    return k;
  }

  Widget _buildBlock(BuildContext context, int i, Map<String, Tag> tags) {
    final eb = _blocks[i];
    final b = eb.block;
    final nn = context.nn;
    final selected = _focused == i;

    Widget wrap(Widget child, {EdgeInsets padding = const EdgeInsets.symmetric(vertical: 2)}) => Padding(
          key: ValueKey(b.id),
          padding: padding,
          child: child,
        );

    switch (b.type) {
      case BlockType.divider:
        return wrap(
          GestureDetector(
            onTap: () => setState(() => _focused = i),
            child: Container(
              height: 28,
              alignment: Alignment.center,
              decoration: selected
                  ? BoxDecoration(borderRadius: BorderRadius.circular(8), color: nn.cardHover)
                  : null,
              child: SizedBox(
                height: 2,
                width: double.infinity,
                child: CustomPaint(painter: _DottedLine(nn.mid)),
              ),
            ),
          ),
        );
      case BlockType.image:
        return wrap(
          _ImageBlock(
            repo: repo,
            attachmentId: b.attachmentId,
            selected: selected,
            onSelect: () => setState(() => _focused = i),
            onDelete: _readOnly ? null : () {
              setState(() => _focused = i);
              deleteCurrent();
            },
          ),
          padding: const EdgeInsets.symmetric(vertical: 8),
        );
      case BlockType.file:
        return wrap(
          _FileBlock(
            repo: repo,
            attachmentId: b.attachmentId,
            selected: selected,
            onSelect: () => setState(() => _focused = i),
            onDelete: _readOnly ? null : () {
              setState(() => _focused = i);
              deleteCurrent();
            },
          ),
          padding: const EdgeInsets.symmetric(vertical: 6),
        );
      case BlockType.table:
        return wrap(_tableBlock(context, eb, i), padding: const EdgeInsets.symmetric(vertical: 8));
    }

    // Blocs de texte
    final base = TextStyle(fontSize: 16, height: 1.5, color: nn.fg, fontFamily: kFontBody);
    var style = base;
    Widget? leading;
    var padding = const EdgeInsets.symmetric(vertical: 1);
    switch (b.type) {
      case BlockType.heading1:
        style = base.copyWith(fontSize: 24, fontWeight: FontWeight.w600, height: 1.3);
        padding = const EdgeInsets.only(top: 14, bottom: 4);
        break;
      case BlockType.heading2:
        style = base.copyWith(fontSize: 19, fontWeight: FontWeight.w600, height: 1.35);
        padding = const EdgeInsets.only(top: 10, bottom: 2);
        break;
      case BlockType.quote:
        style = base.copyWith(fontStyle: FontStyle.italic, color: nn.mid);
        leading = Container(width: 3, height: 24, margin: const EdgeInsets.only(right: 12), color: NColors.red);
        break;
      case BlockType.bullet:
        leading = SizedBox(
          width: 26,
          child: Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Align(alignment: Alignment.topLeft, child: RedDot(size: 6, color: nn.fg)),
          ),
        );
        break;
      case BlockType.numbered:
        leading = SizedBox(
          width: 26,
          child: Text('${_numberFor(i)}.', style: base.copyWith(color: nn.mid, fontFeatures: const [FontFeature.tabularFigures()])),
        );
        break;
      case BlockType.todo:
        if (b.checked) style = base.copyWith(color: nn.mid, decoration: TextDecoration.lineThrough, decorationColor: nn.mid);
        leading = SizedBox(
          width: 34,
          height: 24,
          child: Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: 22,
              height: 22,
              child: Checkbox(
                value: b.checked,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
                onChanged: _readOnly
                    ? null
                    : (v) {
                        _snapshot(force: true);
                        setState(() => b.checked = v ?? false);
                        _scheduleSave();
                      },
              ),
            ),
          ),
        );
        break;
      case BlockType.code:
        style = TextStyle(fontFamily: kFontMono, fontSize: 13.5, height: 1.5, color: nn.fg);
        break;
    }

    final field = TextField(
      controller: eb.controller,
      focusNode: eb.focus,
      readOnly: _readOnly,
      maxLines: null,
      keyboardType: TextInputType.multiline,
      style: style,
      cursorWidth: 2,
      decoration: InputDecoration(
        isCollapsed: true,
        filled: false,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        hintText: selected && b.text.isEmpty ? _hintFor(b.type) : null,
        hintStyle: style.copyWith(color: nn.mid.withValues(alpha: 0.6), decoration: TextDecoration.none),
        contentPadding: const EdgeInsets.symmetric(vertical: 2),
      ),
    );

    if (b.type == BlockType.code) {
      return wrap(
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          decoration: BoxDecoration(
            color: nn.card,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: selected ? nn.mid : nn.line),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text('CODE', style: TextStyle(fontFamily: kFontMono, fontSize: 10, letterSpacing: 1.5, color: nn.mid)),
              const Spacer(),
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: eb.controller.text));
                  toast(context, 'Code copié');
                },
                child: Padding(padding: const EdgeInsets.all(2), child: Icon(Icons.copy_rounded, size: 15, color: nn.mid)),
              ),
            ]),
            const SizedBox(height: 6),
            field,
          ]),
        ),
        padding: const EdgeInsets.symmetric(vertical: 6),
      );
    }

    return wrap(
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (leading != null) leading,
        Expanded(child: field),
      ]),
      padding: padding,
    );
  }

  String _hintFor(String type) => switch (type) {
        BlockType.heading1 => 'Titre',
        BlockType.heading2 => 'Sous-titre',
        BlockType.quote => 'Citation',
        BlockType.todo => 'Tâche',
        BlockType.bullet || BlockType.numbered => 'Élément de liste',
        _ => 'Écrire…  (« - » liste, « [] » tâche, « # » titre)',
      };

  Widget _tableBlock(BuildContext context, _EB eb, int i) {
    final nn = context.nn;
    final rows = eb.block.rows!;
    final cols = rows.isEmpty ? 0 : rows.map((r) => r.length).reduce((a, b) => a > b ? a : b);
    for (final r in rows) {
      while (r.length < cols) {
        r.add('');
      }
    }
    void rebuild() {
      for (final r in eb.cells ?? const <List<TextEditingController>>[]) {
        for (final c in r) {
          c.dispose();
        }
      }
      eb.cells = [
        for (var r = 0; r < rows.length; r++) [for (var c = 0; c < rows[r].length; c++) _cellController(eb, r, c)]
      ];
      setState(() => _focused = i);
      _scheduleSave();
    }

    if (eb.cells == null || eb.cells!.length != rows.length || (rows.isNotEmpty && eb.cells!.first.length != cols)) {
      eb.cells = [
        for (var r = 0; r < rows.length; r++) [for (var c = 0; c < rows[r].length; c++) _cellController(eb, r, c)]
      ];
    }
    return GestureDetector(
      onTap: () => setState(() => _focused = i),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _focused == i ? nn.mid : nn.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Table(
              defaultColumnWidth: const FixedColumnWidth(150),
              border: TableBorder.symmetric(inside: BorderSide(color: nn.line)),
              children: [
                for (var r = 0; r < rows.length; r++)
                  TableRow(
                    decoration: BoxDecoration(color: r == 0 ? nn.card : null),
                    children: [
                      for (var c = 0; c < cols; c++)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          child: TextField(
                            controller: eb.cells![r][c],
                            readOnly: _readOnly,
                            maxLines: null,
                            onTap: () => setState(() => _focused = i),
                            style: TextStyle(fontSize: 14, fontWeight: r == 0 ? FontWeight.w600 : FontWeight.w400),
                            decoration: const InputDecoration.collapsed(hintText: ''),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
          if (!_readOnly && _focused == i)
            Container(
              color: nn.card,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Wrap(children: [
                TextButton.icon(
                  onPressed: () {
                    _snapshot(force: true);
                    rows.add(List.filled(cols, '', growable: true));
                    rebuild();
                  },
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Ligne', style: TextStyle(fontSize: 12.5)),
                ),
                TextButton.icon(
                  onPressed: () {
                    _snapshot(force: true);
                    for (final r in rows) {
                      r.add('');
                    }
                    rebuild();
                  },
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Colonne', style: TextStyle(fontSize: 12.5)),
                ),
                if (rows.length > 1)
                  TextButton.icon(
                    onPressed: () {
                      _snapshot(force: true);
                      rows.removeLast();
                      rebuild();
                    },
                    icon: const Icon(Icons.remove, size: 16),
                    label: const Text('Ligne', style: TextStyle(fontSize: 12.5)),
                  ),
                if (cols > 1)
                  TextButton.icon(
                    onPressed: () {
                      _snapshot(force: true);
                      for (final r in rows) {
                        r.removeLast();
                      }
                      rebuild();
                    },
                    icon: const Icon(Icons.remove, size: 16),
                    label: const Text('Colonne', style: TextStyle(fontSize: 12.5)),
                  ),
                TextButton.icon(
                  onPressed: () => _removeAt(i),
                  icon: const Icon(Icons.delete_outline, size: 16),
                  label: const Text('Supprimer', style: TextStyle(fontSize: 12.5)),
                ),
              ]),
            ),
        ]),
      ),
    );
  }
}

// ==================================================================== en-tête
class _Header extends StatelessWidget {
  const _Header({required this.editor, required this.note, required this.tags, this.onBack});
  final NoteEditorState editor;
  final Note note;
  final Map<String, Tag> tags;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final repo = editor.repo;
    final nn = context.nn;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 4),
      child: Row(children: [
        if (onBack != null)
          IconButton(
            tooltip: 'Retour',
            onPressed: () {
              editor.flush();
              onBack!();
            },
            icon: const Icon(Icons.arrow_back_rounded),
          ),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final id in note.tags)
                if (tags[id] != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: TagPill(
                      tag: tags[id]!,
                      onRemove: note.trashed ? null : () => repo.setTags(note.id, note.tags.where((t) => t != id).toList()),
                    ),
                  ),
              if (!note.trashed)
                Tooltip(
                  message: 'Étiquettes',
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => showTagPicker(context, repo, note.id),
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: nn.line)),
                      child: Icon(note.tags.isEmpty ? Icons.label_outline_rounded : Icons.add_rounded, size: 17),
                    ),
                  ),
                ),
            ]),
          ),
        ),
        if (!note.trashed)
          IconButton(
            tooltip: note.favorite ? 'Retirer des favoris' : 'Ajouter aux favoris',
            onPressed: () {
              editor.flush();
              repo.setFavorite(note.id, !note.favorite);
            },
            icon: Icon(note.favorite ? Icons.star_rounded : Icons.star_outline_rounded,
                color: note.favorite ? NColors.red : null),
          ),
        PopupMenuButton<String>(
          tooltip: 'Partager / exporter',
          icon: const Icon(Icons.ios_share_rounded, size: 21),
          onSelected: (v) => _share(context, v),
          itemBuilder: (c) => [
            const PopupMenuItem(value: 'copy', child: Text('Copier le texte')),
            const PopupMenuDivider(),
            for (final f in ExportFormat.values) PopupMenuItem(value: f.name, child: Text('Exporter en ${f.label}')),
          ],
        ),
        PopupMenuButton<String>(
          tooltip: 'Plus',
          icon: const Icon(Icons.more_vert_rounded),
          onSelected: (v) => _menu(context, v),
          itemBuilder: (c) => [
            if (!note.trashed) ...[
              const PopupMenuItem(value: 'folder', child: Text('Déplacer vers un dossier…')),
              PopupMenuItem(value: 'archive', child: Text(note.archived ? 'Désarchiver' : 'Archiver')),
              const PopupMenuItem(value: 'history', child: Text('Historique des versions')),
              const PopupMenuItem(value: 'duplicate', child: Text('Dupliquer')),
              if (note.hasConflict) const PopupMenuItem(value: 'conflict', child: Text('Résoudre le conflit')),
              const PopupMenuDivider(),
              const PopupMenuItem(value: 'trash', child: Text('Mettre à la corbeille', style: TextStyle(color: NColors.red))),
            ] else ...[
              const PopupMenuItem(value: 'restore', child: Text('Restaurer')),
              const PopupMenuItem(
                  value: 'purge', child: Text('Supprimer définitivement', style: TextStyle(color: NColors.red))),
            ],
          ],
        ),
      ]),
    );
  }

  Future<void> _share(BuildContext context, String v) async {
    editor.flush();
    final repo = editor.repo;
    final n = repo.note(note.id);
    if (n == null) return;
    if (v == 'copy') {
      await Clipboard.setData(ClipboardData(text: exportTxt(n)));
      if (context.mounted) toast(context, 'Texte copié');
      return;
    }
    final f = ExportFormat.values.firstWhere((e) => e.name == v);
    try {
      final bytes = await buildExport(repo, n, f);
      final path = await saveBytes(exportFileName(n, f.ext), bytes);
      if (path != null && context.mounted) toast(context, 'Exportée : ${path.split(RegExp(r'[\\/]')).last}');
    } catch (e) {
      if (context.mounted) toast(context, 'Export impossible : $e');
    }
  }

  Future<void> _menu(BuildContext context, String v) async {
    editor.flush();
    final repo = editor.repo;
    final app = AppScope.read(context);
    switch (v) {
      case 'folder':
        final (ok, folder) = await pickFolder(context, repo, current: note.folderId);
        if (ok) repo.moveToFolder(note.id, folder);
        break;
      case 'archive':
        repo.setArchived(note.id, !note.archived);
        if (context.mounted) toast(context, note.archived ? 'Note désarchivée' : 'Note archivée');
        break;
      case 'history':
        await showHistoryDialog(context, repo, note.id);
        break;
      case 'duplicate':
        final copy = repo.duplicateNote(note.id);
        app.select(copy.id);
        break;
      case 'conflict':
        await showConflictDialog(context, repo, note.id);
        break;
      case 'trash':
        repo.trashNote(note.id);
        if (context.mounted) toast(context, 'Note mise à la corbeille');
        if (onBack != null) onBack!();
        break;
      case 'restore':
        repo.restoreNote(note.id);
        break;
      case 'purge':
        if (await confirm(context,
            title: 'Supprimer définitivement ?',
            message: 'La note et ses pièces jointes seront supprimées sur tous vos appareils. Cette action est irréversible.',
            ok: 'Supprimer',
            danger: true)) {
          repo.purgeNote(note.id);
          app.select(null);
          if (onBack != null) onBack!();
        }
        break;
    }
  }
}

class _ConflictBanner extends StatelessWidget {
  const _ConflictBanner({required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(20, 6, 20, 6),
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: NColors.red),
        ),
        child: Row(children: [
          const Icon(Icons.call_split_rounded, color: NColors.red, size: 20),
          const SizedBox(width: 12),
          const Expanded(
            child: Text('Modifiée aussi sur un autre appareil. Aucune version n\'a été écrasée.',
                style: TextStyle(fontSize: 13.5)),
          ),
          TextButton(onPressed: onTap, child: const Text('Comparer')),
        ]),
      );
}

class _TrashBanner extends StatelessWidget {
  const _TrashBanner({required this.repo, required this.note});
  final NotesRepository repo;
  final Note note;
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(20, 6, 20, 6),
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        decoration: BoxDecoration(color: context.nn.card, borderRadius: BorderRadius.circular(16)),
        child: Row(children: [
          Icon(Icons.delete_outline_rounded, color: context.nn.mid, size: 20),
          const SizedBox(width: 12),
          const Expanded(child: Text('Dans la corbeille (supprimée après 30 jours)', style: TextStyle(fontSize: 13.5))),
          TextButton(onPressed: () => repo.restoreNote(note.id), child: const Text('Restaurer')),
        ]),
      );
}

// ==================================================================== barre d'outils
class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.editor, required this.wide, this.link});
  final NoteEditorState editor;
  final bool wide;
  final String? link;

  @override
  Widget build(BuildContext context) {
    final nn = context.nn;
    Widget btn(IconData icon, String tip, VoidCallback onTap) => IconButton(
          tooltip: tip,
          onPressed: onTap,
          icon: Icon(icon, size: 22),
          visualDensity: VisualDensity.compact,
        );
    final textStyles = PopupMenuButton<String>(
      tooltip: 'Style du paragraphe',
      icon: const Icon(Icons.text_fields_rounded, size: 22),
      onSelected: editor.applyBlockType,
      itemBuilder: (c) => const [
        PopupMenuItem(value: BlockType.paragraph, child: Text('Texte')),
        PopupMenuItem(value: BlockType.heading1, child: Text('Titre', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600))),
        PopupMenuItem(value: BlockType.heading2, child: Text('Sous-titre', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
        PopupMenuItem(value: BlockType.quote, child: Text('Citation', style: TextStyle(fontStyle: FontStyle.italic))),
        PopupMenuItem(value: BlockType.bullet, child: Text('•  Liste à puces')),
        PopupMenuItem(value: BlockType.numbered, child: Text('1.  Liste numérotée')),
      ],
    );
    final primary = <Widget>[
      textStyles,
      btn(Icons.checklist_rounded, 'Case à cocher', () => editor.applyBlockType(BlockType.todo)),
      btn(Icons.image_outlined, 'Image', () => editor.addAttachment(image: true)),
      btn(Icons.code_rounded, 'Bloc de code', () => editor.applyBlockType(BlockType.code)),
      btn(Icons.table_chart_outlined, 'Tableau', editor.insertTable),
    ];
    final secondary = <Widget>[
      btn(Icons.format_bold_rounded, 'Gras (Ctrl+B)', () => editor.wrapSelection('**')),
      btn(Icons.format_italic_rounded, 'Italique (Ctrl+I)', () => editor.wrapSelection('*')),
      btn(Icons.format_underlined_rounded, 'Souligné (Ctrl+U)', () => editor.wrapSelection('++')),
      btn(Icons.format_strikethrough_rounded, 'Barré (Ctrl+Maj+X)', () => editor.wrapSelection('~~')),
      btn(Icons.link_rounded, 'Lien (Ctrl+K)', editor.insertLink),
      btn(Icons.attach_file_rounded, 'Pièce jointe', () => editor.addAttachment(image: false)),
      btn(Icons.horizontal_rule_rounded, 'Séparateur', editor.insertDivider),
    ];
    final more = PopupMenuButton<String>(
      tooltip: 'Plus',
      icon: const Icon(Icons.more_horiz_rounded),
      onSelected: (v) {
        switch (v) {
          case 'b':
            editor.wrapSelection('**');
          case 'i':
            editor.wrapSelection('*');
          case 'u':
            editor.wrapSelection('++');
          case 's':
            editor.wrapSelection('~~');
          case 'link':
            editor.insertLink();
          case 'file':
            editor.addAttachment(image: false);
          case 'div':
            editor.insertDivider();
          case 'up':
            editor.moveCurrent(-1);
          case 'down':
            editor.moveCurrent(1);
          case 'del':
            editor.deleteCurrent();
          case 'undo':
            editor.undo();
          case 'redo':
            editor.redo();
        }
      },
      itemBuilder: (c) => [
        if (!wide) ...const [
          PopupMenuItem(value: 'b', child: Text('Gras')),
          PopupMenuItem(value: 'i', child: Text('Italique')),
          PopupMenuItem(value: 'u', child: Text('Souligné')),
          PopupMenuItem(value: 's', child: Text('Barré')),
          PopupMenuItem(value: 'link', child: Text('Lien…')),
          PopupMenuItem(value: 'file', child: Text('Pièce jointe…')),
          PopupMenuItem(value: 'div', child: Text('Séparateur')),
          PopupMenuDivider(),
        ],
        const PopupMenuItem(value: 'up', child: Text('Monter le bloc')),
        const PopupMenuItem(value: 'down', child: Text('Descendre le bloc')),
        const PopupMenuItem(value: 'del', child: Text('Supprimer le bloc')),
        if (!wide) ...const [
          PopupMenuDivider(),
          PopupMenuItem(value: 'undo', child: Text('Annuler')),
          PopupMenuItem(value: 'redo', child: Text('Rétablir')),
        ],
      ],
    );
    return Container(
      decoration: BoxDecoration(border: Border(top: BorderSide(color: nn.line))),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: SafeArea(
        top: false,
        child: Row(children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                ...primary,
                if (wide) ...[
                  Container(width: 1, height: 22, color: nn.line, margin: const EdgeInsets.symmetric(horizontal: 6)),
                  ...secondary,
                ],
                if (link != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: ActionChip(
                      avatar: const Icon(Icons.open_in_new_rounded, size: 15, color: NColors.red),
                      label: const Text('Ouvrir le lien'),
                      onPressed: () => launchUrl(Uri.parse(link!), mode: LaunchMode.externalApplication),
                    ),
                  ),
              ]),
            ),
          ),
          if (wide) ...[
            btn(Icons.undo_rounded, 'Annuler (note)', editor.undo),
            btn(Icons.redo_rounded, 'Rétablir (note)', editor.redo),
          ],
          more,
        ]),
      ),
    );
  }
}

// ==================================================================== blocs média
class _DottedLine extends CustomPainter {
  _DottedLine(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = color;
    for (double x = 2; x < size.width; x += 9) {
      canvas.drawCircle(Offset(x, size.height / 2), 1.3, p);
    }
  }

  @override
  bool shouldRepaint(_DottedLine old) => old.color != color;
}

class _ImageBlock extends StatefulWidget {
  const _ImageBlock({required this.repo, required this.attachmentId, required this.selected, required this.onSelect, this.onDelete});
  final NotesRepository repo;
  final String? attachmentId;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback? onDelete;
  @override
  State<_ImageBlock> createState() => _ImageBlockState();
}

class _ImageBlockState extends State<_ImageBlock> {
  Future<String?>? _path;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  void _resolve() {
    final id = widget.attachmentId;
    _path = id == null ? Future.value(null) : widget.repo.ensureFile(id).catchError((_) => null);
  }

  @override
  void didUpdateWidget(_ImageBlock old) {
    super.didUpdateWidget(old);
    if (old.attachmentId != widget.attachmentId) _resolve();
  }

  @override
  Widget build(BuildContext context) {
    final nn = context.nn;
    final a = widget.attachmentId == null ? null : widget.repo.attachment(widget.attachmentId!);
    return FutureBuilder<String?>(
      future: _path,
      builder: (c, snap) {
        final path = snap.data;
        Widget content;
        if (path != null) {
          content = ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 420),
            child: Image.file(File(path), fit: BoxFit.contain, errorBuilder: (_, __, ___) => _placeholder(nn, 'Image illisible')),
          );
        } else if (snap.connectionState != ConnectionState.done) {
          content = _placeholder(nn, 'Chargement…');
        } else {
          content = _placeholder(nn, a?.deleted == true ? 'Image supprimée' : 'Image disponible après synchronisation',
              retry: () => setState(_resolve));
        }
        return GestureDetector(
          onTap: () {
            widget.onSelect();
            if (path != null) _openViewer(context, path);
          },
          onLongPress: widget.onDelete == null ? null : () => _menu(context, path, a),
          onSecondaryTap: widget.onDelete == null ? null : () => _menu(context, path, a),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: widget.selected ? nn.mid : nn.line),
              color: nn.card,
            ),
            clipBehavior: Clip.antiAlias,
            alignment: Alignment.center,
            child: content,
          ),
        );
      },
    );
  }

  Widget _placeholder(NTheme nn, String text, {VoidCallback? retry}) => SizedBox(
        height: 120,
        child: Center(
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.image_outlined, color: nn.mid),
            const SizedBox(width: 10),
            Text(text, style: TextStyle(color: nn.mid, fontSize: 13)),
            if (retry != null) IconButton(onPressed: retry, icon: Icon(Icons.refresh_rounded, color: nn.mid, size: 18)),
          ]),
        ),
      );

  void _openViewer(BuildContext context, String path) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.92),
      builder: (c) => GestureDetector(
        onTap: () => Navigator.pop(c),
        child: InteractiveViewer(maxScale: 6, child: Center(child: Image.file(File(path)))),
      ),
    );
  }

  Future<void> _menu(BuildContext context, String? path, Attachment? a) async {
    widget.onSelect();
    final v = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (path != null && a != null)
            ListTile(leading: const Icon(Icons.download_rounded), title: const Text('Enregistrer sous…'), onTap: () => Navigator.pop(c, 'save')),
          ListTile(
            leading: const Icon(Icons.delete_outline_rounded, color: NColors.red),
            title: const Text('Supprimer l\'image', style: TextStyle(color: NColors.red)),
            onTap: () => Navigator.pop(c, 'del'),
          ),
        ]),
      ),
    );
    if (v == 'save' && path != null && a != null) {
      await saveBytes(a.fileName, await File(path).readAsBytes());
    } else if (v == 'del') {
      widget.onDelete?.call();
    }
  }
}

class _FileBlock extends StatefulWidget {
  const _FileBlock({required this.repo, required this.attachmentId, required this.selected, required this.onSelect, this.onDelete});
  final NotesRepository repo;
  final String? attachmentId;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback? onDelete;
  @override
  State<_FileBlock> createState() => _FileBlockState();
}

class _FileBlockState extends State<_FileBlock> {
  bool _busy = false;

  Future<String?> _get() async {
    setState(() => _busy = true);
    try {
      return await widget.repo.ensureFile(widget.attachmentId!);
    } catch (e) {
      if (mounted) toast(context, 'Fichier indisponible hors ligne');
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open() async {
    widget.onSelect();
    final path = await _get();
    if (path == null) return;
    if (Platform.isWindows) {
      await launchUrl(Uri.file(path));
    } else {
      final a = widget.repo.attachment(widget.attachmentId!);
      if (a != null) await saveBytes(a.fileName, await File(path).readAsBytes());
    }
  }

  @override
  Widget build(BuildContext context) {
    final nn = context.nn;
    final a = widget.attachmentId == null ? null : widget.repo.attachment(widget.attachmentId!);
    final local = a == null ? null : widget.repo.localPath(a.id);
    return Material(
      color: nn.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: widget.selected ? nn.mid : nn.line),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: a == null ? widget.onSelect : _open,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
          child: Row(children: [
            const Icon(Icons.insert_drive_file_outlined),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(a?.fileName ?? 'Pièce jointe', maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w500)),
                Text(
                  a == null
                      ? 'En attente de synchronisation'
                      : '${formatBytes(a.sizeBytes)} · ${local != null ? 'sur cet appareil' : 'dans le cloud'}',
                  style: TextStyle(fontSize: 12, color: nn.mid),
                ),
              ]),
            ),
            if (_busy) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            IconButton(
              tooltip: Platform.isWindows ? 'Ouvrir' : 'Enregistrer sous…',
              onPressed: a == null ? null : _open,
              icon: Icon(Platform.isWindows ? Icons.open_in_new_rounded : Icons.download_rounded, size: 20),
            ),
            if (widget.onDelete != null)
              IconButton(
                tooltip: 'Supprimer',
                onPressed: widget.onDelete,
                icon: Icon(Icons.close_rounded, size: 18, color: nn.mid),
              ),
          ]),
        ),
      ),
    );
  }
}
