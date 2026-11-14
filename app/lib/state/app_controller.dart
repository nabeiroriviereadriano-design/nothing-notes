import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:notes_core/notes_core.dart';
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/platform_paths.dart';
import '../services/secure_session_storage.dart';

const kAppVersion = String.fromEnvironment('APP_VERSION', defaultValue: '1.0.0');
const kGithubRepo = 'nabeiroriviereadriano-design/nothing-notes';

/// Adresse et clé publique du projet Supabase, injectées à la compilation
/// (`--dart-define`) par la CI. Modifiables dans l'application.
const _envUrl = String.fromEnvironment('SUPABASE_URL');
const _envKey = String.fromEnvironment('SUPABASE_ANON_KEY');

enum NavView { all, favorites, folder, tag, archive, trash }

enum SortMode { modified, created, title }

enum NoteFilter { none, checklists, images, code, unsynced }

/// État global de l'application : configuration, compte, session de
/// synchronisation et sélection courante de l'interface.
class AppController extends ChangeNotifier {
  late Directory dataDir;
  late SettingsFile settings;

  bool ready = false;
  String? fatalError;

  // ---------------------------------------------------------------- serveur
  String serverUrl = '';
  String anonKey = '';
  bool get hasServer => serverUrl.startsWith('http') && anonKey.length > 20;
  bool _supabaseReady = false;
  SupabaseClient? get client => _supabaseReady ? Supabase.instance.client : null;
  StreamSubscription<AuthState>? _authSub;

  // ---------------------------------------------------------------- session
  User? user;
  LocalStore? store;
  SyncEngine? engine;
  NotesRepository? repo;
  SupabaseRemote? _remote;
  StreamSubscription<EntityType>? _storeSub;
  StreamSubscription<SyncStatus>? _statusSub;
  SyncStatus syncStatus = const SyncStatus(SyncState.pending);
  bool get signedIn => repo != null;
  bool _opening = false;

  // ---------------------------------------------------------------- apparence
  ThemeMode themeMode = ThemeMode.dark;

  // ---------------------------------------------------------------- sélection
  NavView view = NavView.all;
  String? folderId;
  String? tagId;
  String query = '';
  SortMode sort = SortMode.modified;
  NoteFilter filter = NoteFilter.none;
  String? selectedNoteId;

  /// Incrémenté quand l'utilisateur demande le focus sur la recherche (Ctrl+F).
  final searchFocusRequest = ValueNotifier<int>(0);

  Future<void> init() async {
    try {
      dataDir = await appDataDir();
      settings = SettingsFile(dataDir);
      await settings.load();
      themeMode = switch (settings.get<String>('theme')) {
        'light' => ThemeMode.light,
        'system' => ThemeMode.system,
        _ => ThemeMode.dark,
      };
      sort = SortMode.values.firstWhere((s) => s.name == settings.get<String>('sort'), orElse: () => SortMode.modified);
      serverUrl = settings.get<String>('server_url') ?? _envUrl;
      anonKey = settings.get<String>('anon_key') ?? _envKey;
      if (hasServer) await _initSupabase();
    } catch (e) {
      fatalError = e.toString();
    }
    ready = true;
    notifyListeners();
  }

  Future<void> _initSupabase() async {
    await _authSub?.cancel();
    if (_supabaseReady) {
      await _closeSession();
      await Supabase.instance.dispose();
      _supabaseReady = false;
    }
    await Supabase.initialize(
      url: serverUrl.trim(),
      anonKey: anonKey.trim(),
      authOptions: FlutterAuthClientOptions(
        localStorage: SecureSessionStorage(dataDir),
        autoRefreshToken: true,
      ),
      debug: false,
    );
    _supabaseReady = true;
    _authSub = Supabase.instance.client.auth.onAuthStateChange.listen(
      (data) => _onSession(data.session),
      onError: (_) {},
    );
    await _onSession(Supabase.instance.client.auth.currentSession);
  }

  /// Enregistre l'adresse du serveur (écran de configuration).
  Future<void> configureServer(String url, String key) async {
    serverUrl = url.trim().replaceAll(RegExp(r'/+$'), '');
    anonKey = key.trim();
    await settings.set('server_url', serverUrl);
    await settings.set('anon_key', anonKey);
    await _initSupabase();
    notifyListeners();
  }

  bool get serverFromBuild => _envUrl.isNotEmpty && _envKey.isNotEmpty;

  Future<void> resetServerToBuild() async {
    await settings.set('server_url', null);
    await settings.set('anon_key', null);
    serverUrl = _envUrl;
    anonKey = _envKey;
    if (hasServer) await _initSupabase();
    notifyListeners();
  }

  // ---------------------------------------------------------------- session locale
  Future<void> _onSession(Session? session) async {
    final u = session?.user;
    if (u == null) {
      if (user != null) await _closeSession();
      return;
    }
    if (user?.id == u.id && repo != null) {
      user = u;
      notifyListeners();
      return;
    }
    if (_opening) return;
    _opening = true;
    try {
      if (repo != null) await _closeSession();
      user = u;
      final userDir = Directory(p.join(dataDir.path, 'accounts', u.id));
      await userDir.create(recursive: true);
      final s = LocalStore.open(p.join(userDir.path, 'notes.db'));
      final remote = SupabaseRemote(Supabase.instance.client);
      final e = SyncEngine(store: s, remote: remote, filesDir: p.join(userDir.path, 'files'));
      final r = NotesRepository(store: s, userId: u.id, filesDir: p.join(userDir.path, 'files'), engine: e);
      store = s;
      engine = e;
      repo = r;
      _remote = remote;
      _storeSub = s.changes.listen((_) => _scheduleNotify());
      _statusSub = e.statusStream.listen((st) {
        syncStatus = st;
        _scheduleNotify();
      });
      r.purgeExpiredTrash();
      e.start();
      unawaited(Supabase.instance.client.rpc('cleanup_my_ops').then((_) {}, onError: (_) {}));
    } finally {
      _opening = false;
    }
    notifyListeners();
  }

  Future<void> _closeSession() async {
    await _storeSub?.cancel();
    await _statusSub?.cancel();
    _storeSub = null;
    _statusSub = null;
    final e = engine, s = store, r = _remote;
    engine = null;
    store = null;
    repo = null;
    _remote = null;
    user = null;
    selectedNoteId = null;
    await e?.dispose();
    s?.close();
    await r?.dispose();
    notifyListeners();
  }

  bool _notifyScheduled = false;
  void _scheduleNotify() {
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    scheduleMicrotask(() {
      _notifyScheduled = false;
      notifyListeners();
    });
  }

  // ---------------------------------------------------------------- compte
  AccountService get account => AccountService(Supabase.instance.client);

  Future<void> signOut({bool everywhere = false, bool wipeLocal = false}) async {
    final dir = user == null ? null : Directory(p.join(dataDir.path, 'accounts', user!.id));
    try {
      if (everywhere) {
        await account.signOutEverywhere();
      } else {
        await account.signOut();
      }
    } catch (_) {
      // hors ligne : on ferme quand même la session locale
      await Supabase.instance.client.auth.signOut(scope: SignOutScope.local).catchError((_) {});
    }
    await _closeSession();
    if (wipeLocal && dir != null && await dir.exists()) await dir.delete(recursive: true);
  }

  Future<void> deleteAccount() async {
    final dir = user == null ? null : Directory(p.join(dataDir.path, 'accounts', user!.id));
    await engine?.stop();
    await account.deleteAccount();
    await _closeSession();
    if (dir != null && await dir.exists()) await dir.delete(recursive: true);
  }

  // ---------------------------------------------------------------- apparence
  Future<void> setThemeMode(ThemeMode m) async {
    themeMode = m;
    notifyListeners();
    await settings.set('theme', m.name);
  }

  Future<void> setSort(SortMode s) async {
    sort = s;
    notifyListeners();
    await settings.set('sort', s.name);
  }

  // ---------------------------------------------------------------- navigation
  void showView(NavView v, {String? folder, String? tag}) {
    view = v;
    folderId = folder;
    tagId = tag;
    notifyListeners();
  }

  void setQuery(String q) {
    query = q;
    notifyListeners();
  }

  void setFilter(NoteFilter f) {
    filter = f;
    notifyListeners();
  }

  void select(String? noteId) {
    selectedNoteId = noteId;
    notifyListeners();
  }

  void requestSearchFocus() => searchFocusRequest.value++;

  Note newNote() {
    final r = repo!;
    final n = r.createNote(
      folderId: view == NavView.folder ? folderId : null,
      tags: view == NavView.tag && tagId != null ? [tagId!] : null,
    );
    if (view == NavView.favorites) r.setFavorite(n.id, true);
    if (view == NavView.trash || view == NavView.archive) showView(NavView.all);
    selectedNoteId = n.id;
    notifyListeners();
    return n;
  }

  String get viewTitle {
    switch (view) {
      case NavView.all:
        return 'Toutes les notes';
      case NavView.favorites:
        return 'Favoris';
      case NavView.archive:
        return 'Archives';
      case NavView.trash:
        return 'Corbeille';
      case NavView.folder:
        return repo?.folders().where((f) => f.id == folderId).firstOrNull?.name ?? 'Dossier';
      case NavView.tag:
        return repo?.tags().where((t) => t.id == tagId).firstOrNull?.name ?? 'Étiquette';
    }
  }

  /// Notes affichées dans la liste selon la vue, la recherche, le filtre et le tri.
  List<Note> visibleNotes() {
    final r = repo;
    if (r == null) return [];
    final searching = query.trim().isNotEmpty;
    var notes = searching ? r.search(query) : r.allNotes();
    Set<String>? folderIds;
    if (view == NavView.folder && folderId != null) folderIds = r.folderSubtree(folderId!);
    notes = notes.where((n) {
      switch (view) {
        case NavView.all:
          return !n.trashed && !n.archived;
        case NavView.favorites:
          return n.favorite && !n.trashed;
        case NavView.folder:
          return !n.trashed && !n.archived && folderIds!.contains(n.folderId);
        case NavView.tag:
          return !n.trashed && n.tags.contains(tagId);
        case NavView.archive:
          return n.archived && !n.trashed;
        case NavView.trash:
          return n.trashed;
      }
    }).where((n) {
      switch (filter) {
        case NoteFilter.none:
          return true;
        case NoteFilter.checklists:
          return n.hasChecklist;
        case NoteFilter.images:
          return n.hasImage;
        case NoteFilter.code:
          return n.hasCode;
        case NoteFilter.unsynced:
          return n.dirty || n.hasConflict;
      }
    }).toList();
    if (!searching) {
      switch (sort) {
        case SortMode.modified:
          notes.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
          break;
        case SortMode.created:
          notes.sort((a, b) => b.createdAt.compareTo(a.createdAt));
          break;
        case SortMode.title:
          notes.sort((a, b) => foldText(a.title).compareTo(foldText(b.title)));
          break;
      }
    }
    return notes;
  }

  ({int all, int favorites, int archive, int trash, Map<String, int> tags, Map<String, int> folders}) counts() {
    final r = repo;
    if (r == null) return (all: 0, favorites: 0, archive: 0, trash: 0, tags: {}, folders: {});
    var all = 0, fav = 0, arch = 0, trash = 0;
    final tags = <String, int>{}, folders = <String, int>{};
    for (final n in r.allNotes()) {
      if (n.trashed) {
        trash++;
        continue;
      }
      if (n.favorite) fav++;
      if (n.archived) {
        arch++;
        continue;
      }
      all++;
      for (final t in n.tags) {
        tags[t] = (tags[t] ?? 0) + 1;
      }
      if (n.folderId != null) folders[n.folderId!] = (folders[n.folderId!] ?? 0) + 1;
    }
    return (all: all, favorites: fav, archive: arch, trash: trash, tags: tags, folders: folders);
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _closeSession();
    super.dispose();
  }
}

/// Accès au contrôleur depuis l'arbre de widgets.
class AppScope extends InheritedNotifier<AppController> {
  const AppScope({super.key, required AppController controller, required super.child}) : super(notifier: controller);

  static AppController of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  static AppController read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}
