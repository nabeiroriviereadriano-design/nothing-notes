import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:notes_core/notes_core.dart';
import 'package:path/path.dart' as p;
import 'package:supabase/supabase.dart';

/// Enveloppe un accès serveur pour simuler coupures réseau et réponses perdues.
class SwitchableRemote implements RemoteApi {
  SwitchableRemote(this.inner);
  final RemoteApi inner;

  bool online = true;
  bool dropNextPushResponse = false;

  /// Nombre de pages de réception autorisées avant coupure (null = illimité).
  int? pullsBeforeCut;
  int pushCount = 0;
  int pullCount = 0;

  void _check() {
    if (!online) throw RemoteUnavailable('hors ligne (test)');
  }

  @override
  String get userId => inner.userId;

  @override
  Future<void> prepare() async {
    _check();
    await inner.prepare();
  }

  @override
  Future<PushResult> push(EntityType type, Map<String, dynamic> row, int baseVersion, String opId) async {
    _check();
    pushCount++;
    final r = await inner.push(type, row, baseVersion, opId);
    if (dropNextPushResponse) {
      dropNextPushResponse = false;
      throw RemoteUnavailable('réponse perdue (test)');
    }
    return r;
  }

  @override
  Future<List<Map<String, dynamic>>> pull(EntityType type, int afterSeq, int limit) async {
    _check();
    if (pullsBeforeCut != null) {
      if (pullsBeforeCut! <= 0) throw RemoteUnavailable('coupure pendant la réception (test)');
      pullsBeforeCut = pullsBeforeCut! - 1;
    }
    pullCount++;
    return inner.pull(type, afterSeq, limit);
  }

  @override
  Future<void> uploadFile(String storagePath, Uint8List bytes, String mime) async {
    _check();
    return inner.uploadFile(storagePath, bytes, mime);
  }

  @override
  Future<Uint8List> downloadFile(String storagePath) async {
    _check();
    return inner.downloadFile(storagePath);
  }

  @override
  Future<void> removeFiles(List<String> storagePaths) async {
    _check();
    return inner.removeFiles(storagePaths);
  }

  @override
  Future<void> saveNoteVersion(String noteId, String title, Map<String, dynamic> content, String deviceId) async {
    _check();
    return inner.saveNoteVersion(noteId, title, content, deviceId);
  }

  @override
  Future<List<Map<String, dynamic>>> noteHistory(String noteId) async {
    _check();
    return inner.noteHistory(noteId);
  }

  @override
  Stream<void> get changes => inner.changes;

  @override
  Future<void> dispose() => inner.dispose();
}

/// Un « appareil » de test : sa base SQLite sur disque, son moteur, ses fichiers.
class Device {
  Device._(this.name, this.net, this.dir, this.pageSize);

  final String name;
  final SwitchableRemote net;
  final Directory dir;
  final int pageSize;
  late LocalStore store;
  late SyncEngine engine;
  late NotesRepository repo;

  static Future<Device> create(String name, RemoteApi remote, {int pageSize = 500}) async {
    final dir = await Directory.systemTemp.createTemp('nn_${name}_');
    final d = Device._(name, SwitchableRemote(remote), dir, pageSize);
    d._open();
    return d;
  }

  void _open() {
    final files = p.join(dir.path, 'files');
    store = LocalStore.open(p.join(dir.path, 'notes.db'));
    engine = SyncEngine(store: store, remote: net, filesDir: files, pageSize: pageSize);
    repo = NotesRepository(store: store, userId: net.userId, filesDir: files, engine: engine);
  }

  Future<void> sync() => engine.syncNow();

  /// Ferme et rouvre l'application (la base sur disque est conservée).
  Future<void> restart() async {
    await engine.dispose();
    store.close();
    _open();
  }

  Future<void> close() async {
    await engine.dispose();
    store.close();
    await net.dispose();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  }

  Note byTitle(String title) => repo.allNotes().firstWhere((n) => n.title == title);
  Note? maybeByTitle(String title) => repo.allNotes().where((n) => n.title == title).firstOrNull;
}

/// Un backend de test : faux serveur en mémoire ou vrai Supabase.
abstract class Backend {
  String get label;

  /// Ouvre une nouvelle session (un nouvel appareil) pour le compte [account].
  Future<RemoteApi> connect(String account);
  Future<void> close();
}

class FakeBackend implements Backend {
  final server = FakeServer();
  @override
  String get label => 'serveur simulé';
  @override
  Future<RemoteApi> connect(String account) async => server.client('u-$account');
  @override
  Future<void> close() async {}
}

/// Vrai backend Supabase (lancé localement en CI avec `supabase start`).
class SupabaseBackend implements Backend {
  SupabaseBackend(this.url, this.anonKey);
  final String url;
  final String anonKey;
  final _accounts = <String, ({String email, String password})>{};
  final clients = <SupabaseClient>[];
  final _rnd = Random();

  static SupabaseBackend? fromEnv() {
    final url = Platform.environment['SUPABASE_URL'];
    final key = Platform.environment['SUPABASE_ANON_KEY'];
    if (url == null || url.isEmpty || key == null || key.isEmpty) return null;
    return SupabaseBackend(url, key);
  }

  @override
  String get label => 'Supabase réel';

  SupabaseClient newClient() {
    final c = SupabaseClient(url, anonKey,
        authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit, autoRefreshToken: false));
    clients.add(c);
    return c;
  }

  Future<SupabaseClient> connectClient(String account) async {
    final c = newClient();
    final known = _accounts[account];
    if (known == null) {
      final creds = (
        email: 'nn-$account-${DateTime.now().microsecondsSinceEpoch}-${_rnd.nextInt(1 << 30)}@example.com',
        password: 'Test-${_rnd.nextInt(1 << 30)}-Mdp!',
      );
      final res = await c.auth.signUp(email: creds.email, password: creds.password);
      if (res.session == null) {
        throw StateError('Inscription sans session : désactivez la confirmation e-mail pour les tests.');
      }
      _accounts[account] = creds;
    } else {
      await c.auth.signInWithPassword(email: known.email, password: known.password);
    }
    return c;
  }

  @override
  Future<RemoteApi> connect(String account) async => SupabaseRemote(await connectClient(account));

  @override
  Future<void> close() async {
    for (final c in clients) {
      try {
        await c.dispose();
      } catch (_) {}
    }
    clients.clear();
  }
}

Uint8List fakePng(int size, [int seed = 7]) {
  final r = Random(seed);
  final b = Uint8List(size);
  const header = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  for (var i = 0; i < size; i++) {
    b[i] = i < header.length ? header[i] : r.nextInt(256);
  }
  return b;
}
