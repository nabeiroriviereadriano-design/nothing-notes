/// Rangement des clés d'association (une clé de 256 bits par appareil associé).
/// L'application fournit une implémentation adossée au coffre du système.
abstract class KeyStore {
  Future<List<int>?> read(String peerId);
  Future<void> write(String peerId, List<int> key);
  Future<void> delete(String peerId);
}

/// Implémentation en mémoire (tests).
class MemoryKeyStore implements KeyStore {
  final _keys = <String, List<int>>{};

  @override
  Future<List<int>?> read(String peerId) async => _keys[peerId];

  @override
  Future<void> write(String peerId, List<int> key) async => _keys[peerId] = List<int>.from(key);

  @override
  Future<void> delete(String peerId) async => _keys.remove(peerId);
}
