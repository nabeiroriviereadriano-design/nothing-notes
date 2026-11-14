import 'dart:typed_data';

import 'models.dart';

/// Réponse du serveur à un envoi.
class PushResult {
  PushResult(this.status, this.row);

  /// 'ok' | 'conflict' | 'duplicate'
  final String status;
  final Map<String, dynamic>? row;
}

/// Le serveur est injoignable (pas de réseau, délai dépassé...) : on réessaiera.
class RemoteUnavailable implements Exception {
  RemoteUnavailable(this.message);
  final String message;
  @override
  String toString() => 'Serveur injoignable : $message';
}

/// Erreur renvoyée par le serveur (droits, données invalides, session...).
class RemoteError implements Exception {
  RemoteError(this.message, {this.authProblem = false});
  final String message;
  final bool authProblem;
  @override
  String toString() => message;
}

/// Contrat entre le moteur de synchronisation et le backend.
/// Implémenté par [SupabaseRemote] (production) et [FakeServer] (tests).
abstract class RemoteApi {
  /// Identifiant du compte connecté.
  String get userId;

  /// Préparation avant une synchronisation (ex. rafraîchir la session).
  Future<void> prepare();

  Future<PushResult> push(EntityType type, Map<String, dynamic> row, int baseVersion, String opId);

  /// Lignes dont `server_seq > afterSeq`, triées par `server_seq` croissant.
  Future<List<Map<String, dynamic>>> pull(EntityType type, int afterSeq, int limit);

  Future<void> uploadFile(String storagePath, Uint8List bytes, String mime);
  Future<Uint8List> downloadFile(String storagePath);
  Future<void> removeFiles(List<String> storagePaths);

  Future<void> saveNoteVersion(String noteId, String title, Map<String, dynamic> content, String deviceId);
  Future<List<Map<String, dynamic>>> noteHistory(String noteId);

  /// Signal « quelque chose a changé côté serveur » (temps réel).
  Stream<void> get changes;

  Future<void> dispose();
}
