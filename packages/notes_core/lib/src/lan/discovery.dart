import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Un appareil Nothing Notes aperçu sur le réseau local.
class SeenDevice {
  SeenDevice({
    required this.id,
    required this.name,
    required this.platform,
    required this.address,
    required this.port,
    required this.pairing,
  });

  final String id;
  final String name;
  final String platform;
  final String address;

  /// Port TCP de synchronisation de l'appareil.
  final int port;

  /// L'appareil affiche un code d'association.
  final bool pairing;
}

/// Adresses IPv4 de cet appareil sur ses réseaux locaux (Wi-Fi, Ethernet,
/// partage de connexion USB…).
Future<List<String>> localIPv4Addresses() async {
  try {
    final list = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
    return [
      for (final i in list)
        for (final a in i.addresses)
          if (isPrivateIPv4(a.address)) a.address
    ];
  } catch (_) {
    return [];
  }
}

/// Plages d'adresses privées (RFC 1918) et lien local.
bool isPrivateIPv4(String address) {
  final p = address.split('.').map(int.tryParse).toList();
  if (p.length != 4 || p.any((x) => x == null)) return false;
  final a = p[0]!, b = p[1]!;
  return a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168) || (a == 169 && b == 254);
}

/// Annonces UDP sur le réseau local.
///
/// Chaque appareil diffuse périodiquement un petit message (identifiant, nom,
/// port). Le message n'est pas un secret et ne donne aucun accès : il sert
/// seulement à savoir où se connecter ; la connexion elle-même est
/// authentifiée et chiffrée.
class Discovery {
  Discovery({
    required this.port,
    required this.describe,
    this.broadcast = true,
    this.extraTargets = const [],
  });

  /// Port UDP des annonces.
  final int port;

  /// Description courante de cet appareil : `{id, name, plat, port, pairing}`.
  final Map<String, dynamic> Function() describe;

  /// Diffusion générale sur les réseaux locaux (désactivée dans les tests).
  final bool broadcast;

  /// Destinataires supplémentaires `(adresse, port)`.
  final List<(String, int)> extraTargets;

  RawDatagramSocket? _socket;
  final _seen = StreamController<SeenDevice>.broadcast();

  Stream<SeenDevice> get seen => _seen.stream;
  bool get isRunning => _socket != null;

  Future<void> start() async {
    if (_socket != null) return;
    RawDatagramSocket? s;
    try {
      s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port, reuseAddress: true);
    } catch (_) {
      try {
        // Port déjà pris : on peut encore émettre et recevoir les réponses directes.
        s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      } catch (_) {
        return;
      }
    }
    try {
      s.broadcastEnabled = true;
    } catch (_) {}
    _socket = s;
    s.listen((event) {
      if (event != RawSocketEvent.read) return;
      while (true) {
        final d = _socket?.receive();
        if (d == null) break;
        _onDatagram(d);
      }
    }, onError: (_) {});
  }

  void _onDatagram(Datagram d) {
    Map<String, dynamic> m;
    try {
      if (d.data.length > 2048) return;
      m = Map<String, dynamic>.from(jsonDecode(utf8.decode(d.data)) as Map);
    } catch (_) {
      return;
    }
    final me = describe();
    final id = m['id'];
    final tcp = m['port'];
    if (m['nn'] != 1 || id is! String || id.isEmpty || id == me['id'] || tcp is! int) return;
    // Réponse directe : permet à un appareil dont le pare-feu filtre les
    // diffusions entrantes de nous découvrir quand même.
    if (m['reply'] != true) _send({...me, 'nn': 1, 'reply': true}, d.address, d.port);
    if (_seen.isClosed) return;
    _seen.add(SeenDevice(
      id: id,
      name: (m['name'] ?? '').toString(),
      platform: (m['plat'] ?? '').toString(),
      address: d.address.address,
      port: tcp,
      pairing: m['pairing'] == true,
    ));
  }

  void _send(Map<String, dynamic> message, InternetAddress to, int toPort) {
    try {
      _socket?.send(utf8.encode(jsonEncode(message)), to, toPort);
    } catch (_) {}
  }

  /// Diffuse une annonce. [unicast] : adresses déjà connues à prévenir directement.
  Future<void> announce({List<String> unicast = const []}) async {
    if (_socket == null) return;
    final message = {...describe(), 'nn': 1, 'reply': false};
    final targets = <(String, int)>{...extraTargets};
    for (final a in unicast) {
      targets.add((a, port));
    }
    if (broadcast) {
      targets.add(('255.255.255.255', port));
      for (final a in await localIPv4Addresses()) {
        final parts = a.split('.');
        targets.add(('${parts[0]}.${parts[1]}.${parts[2]}.255', port));
      }
    }
    for (final (host, p) in targets) {
      final addr = InternetAddress.tryParse(host);
      if (addr != null) _send(message, addr, p);
    }
  }

  void stop() {
    _socket?.close();
    _socket = null;
  }
}
