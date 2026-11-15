/// État de la synchronisation, affiché en permanence dans l'interface.
enum SyncState {
  /// Aucun appareil n'est associé : les notes restent sur cet appareil.
  unpaired,

  /// Tout a été transmis aux appareils associés.
  synced,

  /// Échange en cours.
  syncing,

  /// Aucun appareil associé n'est joignable (pas sur le même réseau, ou application fermée).
  offline,

  /// Des modifications attendent d'être transmises.
  pending,

  /// La dernière synchronisation a échoué.
  error,
}

class SyncStatus {
  const SyncStatus(
    this.state, {
    this.pending = 0,
    this.conflicts = 0,
    this.peers = 0,
    this.connected = 0,
    this.message,
    this.lastSync,
  });

  final SyncState state;

  /// Modifications pas encore transmises.
  final int pending;

  /// Conflits en attente de choix de l'utilisateur.
  final int conflicts;

  /// Appareils associés / actuellement connectés.
  final int peers;
  final int connected;
  final String? message;
  final DateTime? lastSync;

  String get label {
    switch (state) {
      case SyncState.unpaired:
        return 'Aucun appareil associé';
      case SyncState.synced:
        return 'Synchronisé';
      case SyncState.syncing:
        return 'Synchronisation…';
      case SyncState.offline:
        return pending > 0 ? 'Appareil hors de portée · $pending en attente' : 'Appareil hors de portée';
      case SyncState.pending:
        return '$pending modification${pending > 1 ? 's' : ''} en attente';
      case SyncState.error:
        return 'Erreur de synchronisation';
    }
  }
}
