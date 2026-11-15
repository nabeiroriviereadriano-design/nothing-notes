import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:notes_core/notes_core.dart';
import 'package:path/path.dart' as p;

import '../services/platform_paths.dart';

const kAppVersion = String.fromEnvironment('APP_VERSION', defaultValue: '2.0.0');
const kGithubRepo = 'nabeiroriviereadriano-design/nothing-notes';

enum NavView { all, favorites, folder, tag, archive, trash }

enum SortMode { modified, created, title }

enum NoteFilter { none, checklists, images, code, unsynced }

/// Clés d'association rangées dans le coffre du système
/// (Android Keystore, protection des données Windows).
class SecureKeyStore implements KeyStore {
  static const _secure = FlutterSecureStorage();
  static String _name(String peerId) => 'nn_pair_$peerId';

  @override
  Future<List<int>?> read(String peerId) async {
    final v = await _secure.read(key: _name(peerId));
    return v == null ? null : base64Decode(v);
  }

  @override
  Future<void> write(String peerId, List<int> key) => _secure.write(key: _name(peerId), value: base64Encode(key));

  @override
  Future<void> delete(String peerId) => _secure.delete(key: _name(peerId));
}

String get _platformName => Platform.isWindows
    ? 'windows'
    : Platform.isAndroid
        ? 'android'
        : Platform.operatingSystem;

String _defaultDeviceName() {
  if (Platform.isAndroid) return 'Téléphone Android';
  try {
    final h = Platform.localHostname.trim();
    if (h.isNotEmpty) return h;
  } catch (_) {}
  return Platform.isWindows ? 'PC Windows' : 'Appareil';
}

/// État global de l'application : base locale, synchronisation directe
/// entre appareils et sélection courante de l'interface.
class AppController extends ChangeNotifier {
  AppController();

  late Directory dataDir;
  late SettingsFile settings;

  bool ready = false;
  String? fatalError;

  LocalStore? store;
  NotesRepository? repo;
  LanNode? node;
  StreamSubscription<EntityType>? _storeSub;
  StreamSubscription<SyncStatus>? _statusSub;
  AppLifecycleListener? _lifecycle;
  SyncStatus syncStatus = const SyncStatus(SyncState.unpaired);

  /// Erreur de démarrage du réseau (le reste de l'application fonctionne).
  String? networkError;

  ThemeMode themeMode = ThemeMode.dark;

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
      final s = LocalStore.open(p.join(dataDir.path, 'notes.db'));
      if (s.getMeta('device_name') == null) s.deviceName = _defaultDeviceName();
      final files = p.join(dataDir.path, 'files');
      store = s;
      repo = NotesRepository(store: s, filesDir: files);
      repo!.purgeExpiredTrash();
      _storeSub = s.changes.listen((_) => _scheduleNotify());
      final n = LanNode(store: s, filesDir: files, keys: SecureKeyStore(), platform: _platformName);
      node = n;
      _statusSub = n.statusStream.listen((st) {
        syncStatus = st;
        _scheduleNotify();
      });
      try {
        await n.start();
      } catch (e) {
        networkError = 'Réseau local indisponible : $e';
      }
      syncStatus = n.status;
      // Retour au premier plan (Android) : reconnexion immédiate.
      _lifecycle = AppLifecycleListener(onResume: () => unawaited(syncNow()));
    } catch (e) {
      fatalError = e.toString();
    }
    ready = true;
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

  // ---------------------------------------------------------------- appareils
  String get deviceName => store?.deviceName ?? '';

  void renameDevice(String name) {
    store?.deviceName = name;
    notifyListeners();
  }

  Future<void> syncNow() async {
    final n = node;
    if (n == null) return;
    if (!n.isRunning) {
      try {
        await n.start();
        networkError = null;
      } catch (e) {
        networkError = 'Réseau local indisponible : $e';
      }
    }
    await n.syncNow();
  }

  List<PeerView> get peers => node?.peers ?? const [];

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
    _lifecycle?.dispose();
    _storeSub?.cancel();
    _statusSub?.cancel();
    unawaited(node?.dispose());
    store?.close();
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
