/// Noyau partagé de Nothing Notes : modèles, base locale, fusion,
/// synchronisation directe entre appareils et export. Aucune dépendance à
/// Flutter : le même code tourne sur Android, Windows et dans les tests.
library;

export 'src/database.dart';
export 'src/export.dart';
export 'src/inline.dart';
export 'src/lan/channel.dart' show ChannelClosed, RpcError;
export 'src/lan/discovery.dart' show Discovery, SeenDevice, localIPv4Addresses, isPrivateIPv4;
export 'src/lan/key_store.dart';
export 'src/lan/lan_node.dart';
export 'src/local_store.dart';
export 'src/markdown_import.dart';
export 'src/merge.dart';
export 'src/models.dart';
export 'src/repository.dart';
export 'src/safety.dart';
export 'src/status.dart';
export 'src/tasks.dart';
export 'src/templates.dart';
