import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:notes_core/notes_core.dart';

import '../editor/note_editor.dart';
import '../state/app_controller.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/note_list.dart';
import '../widgets/pages_ui.dart';
import '../widgets/sidebar.dart';
import '../widgets/tasks_pane.dart';
import '../widgets/update_dialog.dart';
import 'devices_screen.dart';
import 'settings_screen.dart';

/// Écran principal, adapté à la largeur disponible :
///  * ≥ 1000 px : trois colonnes (navigation · liste · éditeur) — Windows, tablettes ;
///  * 700–1000 px : liste + éditeur, navigation dans un tiroir ;
///  * < 700 px : téléphone, la note s'ouvre en plein écran.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  final _editorKey = GlobalKey<NoteEditorState>();
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  bool _mobileSearch = false;
  AppController? _app;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = AppScope.read(context);
    if (_app != app) {
      _app?.notice.removeListener(_onNotice);
      _app?.updateNotice.removeListener(_onUpdate);
      _app = app;
      app.notice.addListener(_onNotice);
      app.updateNotice.addListener(_onUpdate);
    }
  }

  void _onUpdate() {
    final u = _app?.updateNotice.value;
    if (u == null || !mounted) return;
    _app?.updateNotice.value = null;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: const Duration(seconds: 12),
      content: Text('Nouvelle version ${u.cleanVersion} disponible'),
      action: SnackBarAction(
        label: 'Installer',
        textColor: NColors.red,
        onPressed: () {
          _editorKey.currentState?.flush();
          showUpdateDialog(context, u);
        },
      ),
    ));
  }

  void _onNotice() {
    final m = _app?.notice.value;
    if (m != null && mounted) toast(context, m);
    _app?.notice.value = null;
  }

  @override
  void dispose() {
    _app?.notice.removeListener(_onNotice);
    _app?.updateNotice.removeListener(_onUpdate);
    super.dispose();
  }

  void _newNote() {
    _editorKey.currentState?.flush();
    AppScope.read(context).newNote();
  }

  /// Bouton + : page vide, base de données ou modèle.
  Future<void> _newFromSheet() async {
    _editorKey.currentState?.flush();
    final app = AppScope.read(context);
    if (app.view == NavView.templates) {
      app.newNote();
      return;
    }
    await showNewPageSheet(context);
  }

  Future<void> _quickOpen() async {
    _editorKey.currentState?.flush();
    await showQuickSwitcher(context);
  }

  void _openId(String id) {
    _editorKey.currentState?.flush();
    AppScope.read(context).openPage(id);
  }

  void _saveNow() {
    _editorKey.currentState?.flush();
    final app = AppScope.read(context);
    app.syncNow();
    toast(context, app.peers.isEmpty ? 'Enregistré sur cet appareil' : 'Enregistré sur cet appareil · synchronisation lancée');
  }

  void _search() {
    final w = MediaQuery.of(context).size.width;
    if (w < 700) {
      final app = AppScope.read(context);
      app.select(null);
      setState(() => _mobileSearch = true);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => AppScope.read(context).requestSearchFocus());
  }

  void _openSettings() {
    _editorKey.currentState?.flush();
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
  }

  void _openDevices() {
    _editorKey.currentState?.flush();
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DevicesScreen()));
  }

  void _open(Note n) {
    _editorKey.currentState?.flush();
    AppScope.read(context).select(n.id);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final width = MediaQuery.of(context).size.width;
    Widget body;
    if (width >= 1000) {
      body = _threeColumns(app, width);
    } else if (width >= 700) {
      body = _twoColumns(app);
    } else {
      body = _mobile(app);
    }
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): _newNote,
        const SingleActivator(LogicalKeyboardKey.keyN, control: true, shift: true): _newFromSheet,
        const SingleActivator(LogicalKeyboardKey.keyP, control: true): _quickOpen,
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): _search,
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _saveNow,
      },
      child: Focus(autofocus: true, child: body),
    );
  }

  // ---------------------------------------------------------------- bureau
  Widget _listPane(AppController app, {bool withMenu = false}) {
    final nn = context.nn;
    final count = app.visibleNotes().length;
    return Container(
      color: nn.bg,
      child: Stack(children: [
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 8, 6),
            child: Row(children: [
              if (withMenu)
                IconButton(onPressed: () => _scaffoldKey.currentState?.openDrawer(), icon: const Icon(Icons.menu_rounded)),
              const Expanded(child: SearchField()),
              const SortFilterButton(),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 8, 20, 4),
            child: Row(children: [
              Expanded(
                child: Text(app.viewTitle.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontFamily: kFontMono, fontSize: 11, letterSpacing: 1.6, color: nn.mid)),
              ),
              Text('$count', style: TextStyle(fontFamily: kFontMono, fontSize: 11, color: nn.mid)),
            ]),
          ),
          Expanded(child: app.view == NavView.tasks ? TasksPane(onOpen: _openId) : NoteList(onOpen: _open)),
        ]),
        Positioned(
          right: 20,
          bottom: 20,
          child: FloatingActionButton(
            heroTag: 'new-note',
            tooltip: 'Nouvelle page (Ctrl+N : page vide · Ctrl+Maj+N : modèles)',
            onPressed: _newFromSheet,
            child: const Icon(Icons.add_rounded, size: 28),
          ),
        ),
      ]),
    );
  }

  Widget _editorPane(AppController app) {
    final id = app.selectedNoteId;
    final exists = id != null && app.repo!.note(id) != null;
    return Container(
      color: context.nn.bg,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        switchInCurve: Curves.easeOutCubic,
        transitionBuilder: (child, a) => FadeTransition(
          opacity: a,
          child: SlideTransition(position: Tween(begin: const Offset(0.015, 0), end: Offset.zero).animate(a), child: child),
        ),
        child: exists
            ? NoteEditor(key: _editorKey, noteId: id)
            : Stack(key: const ValueKey('empty'), children: [
                const Positioned.fill(child: DotPattern()),
                Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const NothingLogo(size: 72),
                    const SizedBox(height: 20),
                    const DotTitle('Nothing Notes', size: 26),
                    const SizedBox(height: 10),
                    Text('Sélectionnez une page ou créez-en une (Ctrl+N)', style: TextStyle(color: context.nn.mid)),
                    const SizedBox(height: 6),
                    Text('Ctrl+P : aller à une page', style: TextStyle(color: context.nn.mid, fontSize: 12.5)),
                  ]),
                ),
              ]),
      ),
    );
  }

  Widget _threeColumns(AppController app, double width) {
    final nn = context.nn;
    final listW = width >= 1300 ? 380.0 : 330.0;
    final navW = width >= 1300 ? 260.0 : 230.0;
    return Scaffold(
      body: Row(children: [
        SizedBox(width: navW, child: Sidebar(onSettings: _openSettings)),
        VerticalDivider(width: 1, color: nn.line),
        SizedBox(width: listW, child: _listPane(app)),
        VerticalDivider(width: 1, color: nn.line),
        Expanded(child: _editorPane(app)),
      ]),
    );
  }

  Widget _twoColumns(AppController app) {
    final nn = context.nn;
    return Scaffold(
      key: _scaffoldKey,
      drawer: Drawer(
        backgroundColor: nn.panel,
        child: Sidebar(onSettings: _openSettings, onNavigate: () => Navigator.of(context).pop()),
      ),
      body: SafeArea(
        child: Row(children: [
          SizedBox(width: 330, child: _listPane(app, withMenu: true)),
          VerticalDivider(width: 1, color: nn.line),
          Expanded(child: _editorPane(app)),
        ]),
      ),
    );
  }

  // ---------------------------------------------------------------- téléphone
  Widget _mobile(AppController app) {
    final nn = context.nn;
    final id = app.selectedNoteId;
    final open = id != null && app.repo!.note(id) != null;
    return PopScope(
      canPop: !open && !_mobileSearch,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (open) {
          _editorKey.currentState?.flush();
          app.select(null);
        } else if (_mobileSearch) {
          app.setQuery('');
          setState(() => _mobileSearch = false);
        }
      },
      child: Scaffold(
        key: _scaffoldKey,
        drawer: Drawer(
          backgroundColor: nn.panel,
          child: Sidebar(onSettings: _openSettings, onNavigate: () => Navigator.of(context).pop()),
        ),
        floatingActionButton: open
            ? null
            : FloatingActionButton(
                heroTag: 'new-note',
                tooltip: 'Nouvelle page',
                onPressed: _newFromSheet,
                child: const Icon(Icons.add_rounded, size: 30),
              ),
        body: SafeArea(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, a) => FadeTransition(
              opacity: a,
              child: SlideTransition(
                position: Tween(begin: const Offset(0, 0.03), end: Offset.zero).animate(a),
                child: child,
              ),
            ),
            child: open
                ? NoteEditor(
                    key: _editorKey,
                    noteId: id,
                    onBack: () => app.select(null),
                  )
                : Column(key: const ValueKey('list'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
                      child: Row(children: [
                        IconButton(
                          tooltip: 'Navigation',
                          onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                          icon: const Icon(Icons.menu_rounded),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: app.view == NavView.all
                              ? const Align(alignment: Alignment.centerLeft, child: DotTitle('Notes', size: 30))
                              : Text(app.viewTitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
                        ),
                        SyncBadge(status: app.syncStatus, compact: true, onTap: _openDevices),
                        IconButton(
                          tooltip: 'Rechercher',
                          onPressed: () {
                            if (_mobileSearch) {
                              app.setQuery('');
                              setState(() => _mobileSearch = false);
                            } else {
                              _search();
                            }
                          },
                          icon: Icon(_mobileSearch ? Icons.close_rounded : Icons.search_rounded),
                        ),
                        PopupMenuButton<String>(
                          icon: const Icon(Icons.more_vert_rounded),
                          onSelected: (v) {
                            if (v == 'settings') _openSettings();
                            if (v == 'devices') _openDevices();
                            if (v == 'sync') app.syncNow();
                            if (v == 'find') _quickOpen();
                          },
                          itemBuilder: (c) => const [
                            PopupMenuItem(value: 'find', child: Text('Aller à une page…')),
                            PopupMenuItem(value: 'devices', child: Text('Appareils')),
                            PopupMenuItem(value: 'sync', child: Text('Synchroniser maintenant')),
                            PopupMenuItem(value: 'settings', child: Text('Paramètres')),
                          ],
                        ),
                      ]),
                    ),
                    if (_mobileSearch)
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 0, 16, 10),
                        child: Row(children: [Expanded(child: SearchField(autofocus: true)), SortFilterButton()]),
                      ),
                    if (app.view != NavView.tasks) ...[
                      const TagChipsRow(),
                      const SizedBox(height: 8),
                    ],
                    Expanded(child: app.view == NavView.tasks ? TasksPane(onOpen: _openId) : NoteList(onOpen: _open)),
                  ]),
          ),
        ),
      ),
    );
  }
}
