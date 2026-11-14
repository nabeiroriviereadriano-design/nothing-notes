@Timeout(Duration(minutes: 3))
library;

import 'dart:async';

import 'package:notes_core/notes_core.dart';
import 'package:test/test.dart';

import 'harness.dart';
import 'scenarios.dart';

/// Tests de bout en bout contre un vrai backend Supabase (PostgreSQL, Auth,
/// Storage, Realtime). Lancés en CI avec `supabase start`. Ignorés si les
/// variables SUPABASE_URL et SUPABASE_ANON_KEY ne sont pas définies.
void main() {
  final env = SupabaseBackend.fromEnv();
  if (env == null) {
    test('Supabase réel', () {}, skip: 'SUPABASE_URL / SUPABASE_ANON_KEY non définies');
    return;
  }

  group('Synchronisation (Supabase réel)', () {
    defineScenarios(() => SupabaseBackend(env.url, env.anonKey));
  });

  group('Backend Supabase', () {
    late SupabaseBackend backend;
    setUp(() => backend = SupabaseBackend(env.url, env.anonKey));
    tearDown(() => backend.close());

    test('écriture directe dans les tables refusée (tout passe par sync_push)', () async {
      final c = await backend.connectClient('alice');
      await expectLater(
        c.from('notes').insert({'id': newId(), 'user_id': c.auth.currentUser!.id, 'title': 'direct'}),
        throwsA(anything),
      );
      expect(await c.from('notes').select(), isEmpty);
    });

    test('accès anonyme refusé', () async {
      final anon = backend.newClient();
      await expectLater(anon.from('notes').select(), throwsA(anything));
      await expectLater(
        anon.rpc('sync_push', params: {
          'p_entity': 'notes',
          'p_row': Note(id: newId(), title: 'anonyme').toRow(),
          'p_base_version': 0,
          'p_op_id': newId(),
        }),
        throwsA(anything),
      );
    });

    test('temps réel : l\'autre appareil est prévenu sans attendre', () async {
      final a = SupabaseRemote(await backend.connectClient('alice'));
      final b = SupabaseRemote(await backend.connectClient('alice'));
      final notified = Completer<void>();
      final sub = b.changes.listen((_) {
        if (!notified.isCompleted) notified.complete();
      });
      await Future<void>.delayed(const Duration(seconds: 3)); // abonnement au canal
      await a.push(EntityType.notes, Note(id: newId(), title: 'ping').toRow(), 0, newId());
      await notified.future.timeout(const Duration(seconds: 20));
      await sub.cancel();
      await a.dispose();
      await b.dispose();
    });

    test('compte : connexion, déconnexion globale, suppression du compte et des données', () async {
      final c1 = await backend.connectClient('carol');
      final c2 = await backend.connectClient('carol');
      final r1 = SupabaseRemote(c1);
      final id = newId();
      await r1.push(EntityType.notes, Note(id: id, title: 'à effacer').toRow(), 0, newId());
      final att = Attachment(id: newId(), noteId: id, fileName: 'f.png', storagePath: '${r1.userId}/x/f.png');
      await r1.uploadFile(att.storagePath!, fakePng(512), 'image/png');
      await r1.push(EntityType.attachments, att.toRow(), 0, newId());
      await r1.dispose();

      // La session du second appareil voit bien la note.
      expect(await c2.from('notes').select(), hasLength(1));

      await AccountService(c1).deleteAccount();
      // Le second appareil ne peut plus rien lire ni écrire.
      final r2rows = await c2.from('notes').select().catchError((_) => <Map<String, dynamic>>[]);
      expect(r2rows, isEmpty);
      // Reconnexion impossible : le compte n'existe plus.
      await expectLater(backend.connectClient('carol'), throwsA(anything));
    });
  });
}
