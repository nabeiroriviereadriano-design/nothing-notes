import 'dart:async';
import 'dart:typed_data';

import 'package:supabase/supabase.dart';

import 'models.dart';
import 'remote.dart';

const attachmentsBucket = 'attachments';

/// Accès au backend Supabase (PostgreSQL + Auth + Storage + Realtime).
class SupabaseRemote implements RemoteApi {
  SupabaseRemote(this.client) : userId = client.auth.currentUser!.id {
    _listen();
  }

  final SupabaseClient client;
  @override
  final String userId;

  RealtimeChannel? _channel;
  final _changes = StreamController<void>.broadcast();

  void _listen() {
    final ch = client.channel('nn-sync-$userId');
    for (final t in EntityType.values) {
      ch.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: t.name,
        filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'user_id', value: userId),
        callback: (_) {
          if (!_changes.isClosed) _changes.add(null);
        },
      );
    }
    ch.subscribe();
    _channel = ch;
  }

  /// Rafraîchit la session si elle a expiré (après une longue période hors ligne).
  @override
  Future<void> prepare() => _guard(() async {
        final s = client.auth.currentSession;
        if (s == null) throw RemoteError('Session absente, reconnectez-vous', authProblem: true);
        if (s.isExpired) await client.auth.refreshSession();
      });

  Future<T> _guard<T>(Future<T> Function() body, {Duration timeout = const Duration(seconds: 40)}) async {
    try {
      return await body().timeout(timeout);
    } on RemoteError {
      rethrow;
    } on RemoteUnavailable {
      rethrow;
    } on PostgrestException catch (e) {
      final auth = e.code == 'PGRST301' || e.code == '28000' || e.code == '401';
      throw RemoteError(e.message, authProblem: auth);
    } on StorageException catch (e) {
      final code = e.statusCode ?? '';
      if (code.isEmpty || code.startsWith('5')) throw RemoteUnavailable(e.message);
      throw RemoteError(e.message, authProblem: code == '401');
    } on AuthRetryableFetchException catch (e) {
      throw RemoteUnavailable(e.message);
    } on AuthException catch (e) {
      throw RemoteError(e.message, authProblem: true);
    } on TimeoutException {
      throw RemoteUnavailable('délai dépassé');
    } on Exception catch (e) {
      // SocketException, ClientException, HandshakeException...
      throw RemoteUnavailable(e.toString());
    }
  }

  @override
  Future<PushResult> push(EntityType type, Map<String, dynamic> row, int baseVersion, String opId) =>
      _guard(() async {
        final res = await client.rpc('sync_push', params: {
          'p_entity': type.name,
          'p_row': row,
          'p_base_version': baseVersion,
          'p_op_id': opId,
        });
        final m = Map<String, dynamic>.from(res as Map);
        final r = m['row'];
        return PushResult(m['status'].toString(), r == null ? null : Map<String, dynamic>.from(r as Map));
      });

  @override
  Future<List<Map<String, dynamic>>> pull(EntityType type, int afterSeq, int limit) => _guard(() async {
        final rows = await client
            .from(type.name)
            .select()
            .gt('server_seq', afterSeq)
            .order('server_seq', ascending: true)
            .limit(limit);
        return rows.map((r) => Map<String, dynamic>.from(r)).toList();
      });

  @override
  Future<void> uploadFile(String storagePath, Uint8List bytes, String mime) => _guard(
        () => client.storage
            .from(attachmentsBucket)
            .uploadBinary(storagePath, bytes, fileOptions: FileOptions(contentType: mime, upsert: true)),
        timeout: const Duration(minutes: 10),
      );

  @override
  Future<Uint8List> downloadFile(String storagePath) => _guard(
        () => client.storage.from(attachmentsBucket).download(storagePath),
        timeout: const Duration(minutes: 10),
      );

  @override
  Future<void> removeFiles(List<String> storagePaths) => _guard(() async {
        for (var i = 0; i < storagePaths.length; i += 100) {
          final end = i + 100 > storagePaths.length ? storagePaths.length : i + 100;
          await client.storage.from(attachmentsBucket).remove(storagePaths.sublist(i, end));
        }
      });

  @override
  Future<void> saveNoteVersion(String noteId, String title, Map<String, dynamic> content, String deviceId) =>
      _guard(() => client.rpc('save_note_version', params: {
            'p_note_id': noteId,
            'p_title': title,
            'p_content': content,
            'p_device_id': deviceId,
          }));

  @override
  Future<List<Map<String, dynamic>>> noteHistory(String noteId) => _guard(() async {
        final rows = await client
            .from('note_versions')
            .select()
            .eq('note_id', noteId)
            .order('saved_at', ascending: false)
            .limit(50);
        return rows.map((r) => Map<String, dynamic>.from(r)).toList();
      });

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<void> dispose() async {
    final ch = _channel;
    _channel = null;
    if (ch != null) {
      try {
        await client.removeChannel(ch);
      } catch (_) {}
    }
    await _changes.close();
  }
}

/// Opérations de compte (inscription, connexion, mot de passe, suppression).
class AccountService {
  AccountService(this.client);
  final SupabaseClient client;

  User? get user => client.auth.currentUser;

  Future<AuthResponse> signUp(String email, String password) =>
      client.auth.signUp(email: email.trim(), password: password);

  Future<AuthResponse> signIn(String email, String password) =>
      client.auth.signInWithPassword(email: email.trim(), password: password);

  /// Valide le code reçu par e-mail après l'inscription.
  Future<AuthResponse> confirmSignUp(String email, String code) =>
      client.auth.verifyOTP(email: email.trim(), token: code.trim(), type: OtpType.signup);

  /// Envoie un e-mail de réinitialisation contenant un code.
  Future<void> sendPasswordReset(String email) => client.auth.resetPasswordForEmail(email.trim());

  /// Vérifie le code de réinitialisation puis définit le nouveau mot de passe.
  Future<void> resetPassword(String email, String code, String newPassword) async {
    await client.auth.verifyOTP(email: email.trim(), token: code.trim(), type: OtpType.recovery);
    await client.auth.updateUser(UserAttributes(password: newPassword));
  }

  Future<void> changePassword(String newPassword) =>
      client.auth.updateUser(UserAttributes(password: newPassword));

  Future<void> signOut() => client.auth.signOut(scope: SignOutScope.local);

  /// Déconnecte tous les appareils du compte (révoque toutes les sessions).
  Future<void> signOutEverywhere() => client.auth.signOut(scope: SignOutScope.global);

  /// Supprime définitivement le compte : fichiers, puis données (cascade).
  Future<void> deleteAccount() async {
    final uid = user?.id;
    if (uid == null) throw RemoteError('Non connecté', authProblem: true);
    final rows = await client.from('attachments').select('storage_path');
    final paths = rows
        .map((r) => r['storage_path'])
        .whereType<String>()
        .where((p) => p.startsWith('$uid/'))
        .toList();
    for (var i = 0; i < paths.length; i += 100) {
      final end = i + 100 > paths.length ? paths.length : i + 100;
      await client.storage.from(attachmentsBucket).remove(paths.sublist(i, end));
    }
    await client.rpc('delete_my_account');
    try {
      await client.auth.signOut(scope: SignOutScope.local);
    } catch (_) {}
  }
}
