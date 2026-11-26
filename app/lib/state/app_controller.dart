import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:notes_core/notes_core.dart';
import 'package:path/path.dart' as p;

import '../services/platform_paths.dart';
import '../services/share_bridge.dart';
import '../services/update_checker.dart';

const kAppVersion = String.fromEnvironment('APP_VERSION', defaultValue: '3.0.0');
const kGithubRepo = 'nabeiroriviereadriano-design/nothing-notes';

enum NavView { all, favorites, folder, tag, archive, trash, recent, tasks, templates }

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

  /// Chemin de la sauvegarde à proposer quand la migration a été arrêtée.
  String? fatalBackupPath;

  late DataSafety safety;
  String get dbPath => p.join(dataDir.path, 'notes.db');

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

  /// Message court à afficher (ex. : page créée depuis un partage).
  final notice = ValueNotifier<String?>(null);

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
      safety = DataSafety(p.join(dataDir.path, 'backups'));
      // Sauvegarde vérifiée avant toute migration, vérification après,
      // remise en place automatique au moindre écart.
      final s = safety.openStore(dbPath);
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
    } on MigrationAborted catch (e) {
      fatalError = 'La mise à jour de la base de notes a été arrêtée par sécurité.\n\n${e.message}\n\n'
          'Vos notes n\'ont pas été modifiées.';
      fatalBackupPath = e.backupPath;
    } catch (e) {
      fatalError = e.toString();
    }
    ready = true;
    notifyListeners();
    if (repo != null && !_shareListening) {
      _shareListening = true;
      unawaited(ShareBridge.listen(importShared));
    }
    if (repo != null) unawaited(autoCheckUpdate());
  }

  // ---------------------------------------------------------------- mises à jour
  /// Dernière version disponible trouvée (null : à jour ou pas encore vérifié).
  UpdateInfo? updateAvailable;

  /// Recherche automatique (au plus une fois par jour), désactivable.
  bool get autoUpdateCheck => settings.get<bool>('auto_update_check') ?? true;

  Future<void> setAutoUpdateCheck(bool v) async {
    await settings.set('auto_update_check', v);
    notifyListeners();
  }

  Future<void> autoCheckUpdate({bool force = false}) async {
    if (!force) {
      if (!autoUpdateCheck) return;
      final last = DateTime.tryParse(settings.get<String>('last_update_check') ?? '');
      if (last != null && DateTime.now().difference(last) < const Duration(hours: 20)) {
        final known = settings.get<String>('update_available');
        if (known != null && isNewer(known, kAppVersion)) {
          // Une version déjà repérée reste signalée sans nouvelle requête.
          try {
            updateAvailable = await checkForUpdate();
            if (!updateAvailable!.newer) updateAvailable = null;
            notifyListeners();
          } catch (_) {}
        }
        return;
      }
    }
    try {
      final u = await checkForUpdate();
      await settings.set('last_update_check', DateTime.now().toIso8601String());
      await settings.set('update_available', u.newer ? u.cleanVersion : null);
      updateAvailable = u.newer ? u : null;
      if (u.newer && settings.get<String>('update_dismissed') != u.cleanVersion) {
        updateNotice.value = u;
      }
      notifyListeners();
    } catch (_) {
      // Hors ligne : on réessaiera au prochain démarrage.
    }
  }

  /// Nouvelle version à signaler une fois (bandeau de l'écran principal).
  final updateNotice = ValueNotifier<UpdateInfo?>(null);

  Future<void> dismissUpdate(UpdateInfo u) => settings.set('update_dismissed', u.cleanVersion);

  /// Enregistrent les modifications en cours (éditeurs ouverts) avant de quitter.
  final List<VoidCallback> beforeExit = [];

  /// Avant une mise à jour : tout enregistrer, sauvegarde de sécurité,
  /// puis (Windows) fermeture propre de la base et de la synchro.
  Future<void> prepareForUpdate({required bool closeAll}) async {
    for (final f in [...beforeExit]) {
      try {
        f();
      } catch (_) {}
    }
    final st = store;
    if (st != null) safety.backupNow(st, label: 'avant-mise-a-jour');
    if (!closeAll) return;
    _lifecycle?.dispose();
    await _storeSub?.cancel();
    await _statusSub?.cancel();
    await node?.dispose();
    store?.close();
    store = null;
  }

  bool _shareListening = false;

  /// Texte ou fichier Markdown reçu d'une autre application : nouvelle page.
  void importShared(String text, String? subject, bool fromFile) {
    final r = repo;
    if (r == null) return;
    final n = fromFile ? r.importMarkdown(text, fileName: subject ?? '') : r.importSharedText(text, subject: subject);
    view = NavView.all;
    select(n.id);
    notice.value = 'Page créée à partir du partage';
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
    if (noteId != null) repo?.markOpened(noteId);
    notifyListeners();
  }

  /// Ouvre une page (lien interne, fil d'Ariane, sous-page…) sans changer de vue
  /// si elle y est visible.
  void openPage(String id) {
    final n = repo?.note(id);
    if (n == null) return;
    if (n.trashed && view != NavView.trash) view = NavView.all;
    if (n.isTemplate) view = NavView.templates;
    select(id);
  }

  // ---------------------------------------------------------------- sauvegardes
  List<BackupInfo> backups() => safety.list();

  BackupInfo backupNow() => safety.backupNow(store!);

  /// Remplace toutes les données par une sauvegarde : la base est fermée,
  /// l'état actuel est lui-même sauvegardé, puis l'application redémarre
  /// sur la sauvegarde.
  Future<void> restoreBackup(BackupInfo b) async {
    ready = false;
    notifyListeners();
    _lifecycle?.dispose();
    await _storeSub?.cancel();
    await _statusSub?.cancel();
    await node?.dispose();
    store?.close();
    store = null;
    repo = null;
    node = null;
    selectedNoteId = null;
    try {
      safety.restore(b.path, dbPath);
    } finally {
      await init();
    }
  }

  void requestSearchFocus() => searchFocusRequest.value++;

  Note newNote({PageTemplate? template, String? parentId}) {
    final r = repo!;
    final folder = view == NavView.folder ? folderId : null;
    final Note n;
    if (view == NavView.templates && template == null && parentId == null) {
      n = r.createNote(title: 'Nouveau modèle', kind: PageKind.template);
    } else if (template != null) {
      n = r.createFromTemplate(template, parentId: parentId, folderId: folder);
    } else {
      n = r.createNote(folderId: parentId == null ? folder : r.note(parentId)?.folderId, parentId: parentId);
    }
    if (view == NavView.tag && tagId != null && parentId == null) r.setTags(n.id, [tagId!]);
    if (view == NavView.favorites && parentId == null) r.setFavorite(n.id, true);
    if (const {NavView.trash, NavView.archive, NavView.recent, NavView.tasks}.contains(view)) {
      view = NavView.all;
    }
    select(n.id);
    return n;
  }

  Note newDatabase({String? parentId}) {
    final r = repo!;
    final n = r.createDatabase(parentId: parentId, folderId: view == NavView.folder ? folderId : null);
    if (const {NavView.trash, NavView.archive, NavView.recent, NavView.tasks, NavView.templates}.contains(view)) {
      view = NavView.all;
    }
    select(n.id);
    return n;
  }

  /// Ouverture rapide (Ctrl+P) : pages par titre.
  List<Note> quickFind(String q) => repo?.findPages(q, limit: 20) ?? const [];

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
      case NavView.recent:
        return 'Récents';
      case NavView.tasks:
        return 'Tâches';
      case NavView.templates:
        return 'Modèles';
    }
  }

  /// Dans « Toutes les notes » et les dossiers, seules les pages de premier
  /// niveau sont listées (les sous-pages s'ouvrent depuis leur page). Une
  /// sous-page dont le parent est à la corbeille ou introuvable reste visible.
  bool _isRoot(Note n, Map<String, Note> byId) {
    final pid = n.parentId;
    if (pid == null) return true;
    final parent = byId[pid];
    return parent == null || parent.trashed || parent.purged || parent.isTemplate;
  }

  /// Nombre de sous-pages directes (hors corbeille).
  Map<String, int> subPageCounts() {
    final out = <String, int>{};
    for (final n in repo?.allNotes() ?? const <Note>[]) {
      if (n.parentId != null && !n.trashed && !n.isTemplate) out[n.parentId!] = (out[n.parentId!] ?? 0) + 1;
    }
    return out;
  }

  /// Notes affichées dans la liste selon la vue, la recherche, le filtre et le tri.
  List<Note> visibleNotes() {
    final r = repo;
    if (r == null) return [];
    final searching = query.trim().isNotEmpty;
    final everything = r.allNotes();
    final byId = {for (final n in everything) n.id: n};
    if (view == NavView.templates) {
      return r.customTemplateNotes()..addAll(everything.where((n) => n.isTemplate && !n.trashed && n.templateFor != null));
    }
    if (view == NavView.recent && !searching) return r.recentPages(limit: 30);
    var notes = searching ? r.search(query) : everything;
    Set<String>? folderIds;
    if (view == NavView.folder && folderId != null) folderIds = r.folderSubtree(folderId!);
    // En recherche, toutes les pages correspondantes sont montrées (sous-pages comprises).
    bool root(Note n) => searching || _isRoot(n, byId);
    notes = notes.where((n) {
      if (n.isTemplate) return false;
      switch (view) {
        case NavView.all:
        case NavView.tasks:
          return !n.trashed && !n.archived && root(n);
        case NavView.recent:
          return !n.trashed;
        case NavView.favorites:
          return n.favorite && !n.trashed;
        case NavView.folder:
          return !n.trashed && !n.archived && folderIds!.contains(n.folderId) && root(n);
        case NavView.tag:
          return !n.trashed && n.tags.contains(tagId);
        case NavView.archive:
          return n.archived && !n.trashed;
        case NavView.trash:
          // Une sous-page partie à la corbeille avec sa page n'est listée qu'une fois (sous sa page).
          final parent = n.parentId == null ? null : byId[n.parentId!];
          return n.trashed && !(parent != null && parent.trashed && parent.trashedAt == n.trashedAt);
        case NavView.templates:
          return false;
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

  ({int all, int favorites, int archive, int trash, Map<String, int> tags, Map<String, int> folders, int tasks, int templates})
      counts() {
    final r = repo;
    if (r == null) return (all: 0, favorites: 0, archive: 0, trash: 0, tags: {}, folders: {}, tasks: 0, templates: 0);
    var all = 0, fav = 0, arch = 0, trash = 0, templates = 0;
    final tags = <String, int>{}, folders = <String, int>{};
    for (final n in r.allNotes()) {
      if (n.isTemplate) {
        if (!n.trashed) templates++;
        continue;
      }
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
    return (
      all: all,
      favorites: fav,
      archive: arch,
      trash: trash,
      tags: tags,
      folders: folders,
      tasks: r.tasks().length,
      templates: templates,
    );
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
