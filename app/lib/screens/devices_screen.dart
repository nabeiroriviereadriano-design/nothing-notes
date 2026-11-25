import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:notes_core/notes_core.dart';

import '../state/app_controller.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Appareils associés et association par code.
class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});
  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  List<String> _addresses = const [];
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    localIPv4Addresses().then((a) {
      if (mounted) setState(() => _addresses = a);
    });
    // Rafraîchit « vu il y a… » et l'état de connexion.
    _refresh = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final nn = context.nn;
    final peers = app.peers;
    final port = app.node?.port ?? 0;
    return Scaffold(
      appBar: AppBar(title: const DotTitle('Appareils', size: 22)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(padding: const EdgeInsets.fromLTRB(20, 0, 20, 40), children: [
            Text(
              'Les notes se synchronisent directement entre vos appareils, sans compte ni serveur, '
              'quand ils sont sur le même réseau : même Wi-Fi, câble Ethernet ou partage de connexion USB. '
              'Les échanges sont chiffrés.',
              style: TextStyle(color: nn.mid, fontSize: 13.5, height: 1.45),
            ),
            const SizedBox(height: 18),
            Row(children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => showPairingCode(context),
                  icon: const Icon(Icons.password_rounded),
                  label: const Text('Afficher un code'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => enterPairingCode(context),
                  icon: const Icon(Icons.dialpad_rounded),
                  label: const Text('Saisir un code'),
                ),
              ),
            ]),
            const SizedBox(height: 6),
            Text('Affichez le code sur un appareil, saisissez-le sur l\'autre. Une seule fois par appareil.',
                style: TextStyle(color: nn.mid, fontSize: 12)),
            if (app.networkError != null) ...[
              const SizedBox(height: 14),
              Text(app.networkError!, style: const TextStyle(color: NColors.red, fontSize: 13)),
            ],
            const SectionLabel('Appareils associés'),
            if (peers.isEmpty)
              _Card(children: [
                ListTile(
                  leading: Icon(Icons.devices_other_outlined, color: nn.mid),
                  title: const Text('Aucun appareil associé'),
                  subtitle: Text('Vos notes restent sur cet appareil.', style: TextStyle(color: nn.mid)),
                ),
              ])
            else
              _Card(children: [for (final p in peers) _PeerTile(peer: p)]),
            const SectionLabel('Cet appareil'),
            _Card(children: [
              ListTile(
                leading: Icon(_platformIcon(Platform.isAndroid ? 'android' : Platform.isWindows ? 'windows' : '')),
                title: Text(app.deviceName),
                subtitle: Text('Nom affiché sur vos autres appareils', style: TextStyle(color: nn.mid)),
                trailing: const Icon(Icons.edit_outlined, size: 19),
                onTap: () async {
                  final name = await promptText(context, title: 'Nom de cet appareil', initial: app.deviceName);
                  if (name != null && name.isNotEmpty) app.renameDevice(name);
                },
              ),
              ListTile(
                leading: const Icon(Icons.lan_outlined),
                title: const Text('Adresse sur le réseau local'),
                subtitle: Text(
                  _addresses.isEmpty
                      ? 'Aucun réseau local détecté'
                      : _addresses.map((a) => '$a:$port').join('\n'),
                  style: TextStyle(color: nn.mid, fontFamily: kFontMono, fontSize: 12.5),
                ),
              ),
            ]),
            const SizedBox(height: 16),
            Text(
              'Si les appareils ne se trouvent pas : vérifiez qu\'ils sont sur le même réseau, que '
              'Nothing Notes est ouvert des deux côtés, et sur Windows que le pare-feu autorise Nothing Notes '
              'sur les réseaux privés.',
              style: TextStyle(color: nn.mid, fontSize: 12, height: 1.45),
            ),
          ]),
        ),
      ),
    );
  }
}

IconData _platformIcon(String p) {
  if (p == 'android') return Icons.smartphone_rounded;
  if (p == 'windows') return Icons.laptop_windows_rounded;
  return Icons.devices_rounded;
}

String _ago(DateTime? t) {
  if (t == null) return 'jamais';
  final d = DateTime.now().toUtc().difference(t.toUtc());
  if (d.inSeconds < 60) return 'à l\'instant';
  if (d.inMinutes < 60) return 'il y a ${d.inMinutes} min';
  return formatDate(t);
}

class _PeerTile extends StatelessWidget {
  const _PeerTile({required this.peer});
  final PeerView peer;

  @override
  Widget build(BuildContext context) {
    final nn = context.nn;
    final info = peer.info;
    final String state;
    final Color color;
    if (peer.rejected) {
      state = 'Association supprimée sur l\'autre appareil — associez-les à nouveau';
      color = redText(context);
    } else if (peer.outdated) {
      state = 'Version différente de Nothing Notes — mettez à jour les deux appareils vers la même version. '
          'La synchronisation est suspendue pour ne rien perdre.';
      color = redText(context);
    } else if (peer.syncing) {
      state = 'Synchronisation…';
      color = nn.fg;
    } else if (peer.connected) {
      state = 'Connecté · synchronisé ${_ago(info.lastSync)}';
      color = nn.fg;
    } else {
      state = 'Hors de portée · dernière synchro ${_ago(info.lastSync)}';
      color = nn.mid;
    }
    return ListTile(
      leading: Stack(clipBehavior: Clip.none, children: [
        Icon(_platformIcon(info.platform)),
        Positioned(
          right: -3,
          bottom: -3,
          child: RedDot(size: 9, color: peer.connected ? const Color(0xFF00B86B) : nn.mid),
        ),
      ]),
      title: Text(info.name.isEmpty ? 'Appareil' : info.name),
      subtitle: Text(state, style: TextStyle(color: color, fontSize: 12.5)),
      trailing: PopupMenuButton<String>(
        onSelected: (v) async {
          if (v != 'remove') return;
          if (await confirm(context,
              title: 'Retirer « ${info.name} » ?',
              message: 'Les deux appareils ne se synchroniseront plus. Les notes déjà présentes '
                  'de chaque côté sont conservées.',
              ok: 'Retirer',
              danger: true)) {
            await AppScope.read(context).node?.removePeer(info.id);
          }
        },
        itemBuilder: (c) => const [
          PopupMenuItem(value: 'remove', child: Text('Retirer cet appareil', style: TextStyle(color: NColors.red))),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: context.nn.card,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: context.nn.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: Material(color: Colors.transparent, child: Column(children: children)),
      );
}

// =================================================================== afficher un code
/// Code d'association en grands chiffres à points.
class PairingCodeView extends StatelessWidget {
  const PairingCodeView({super.key, required this.code, required this.remaining});
  final String code;
  final Duration remaining;

  @override
  Widget build(BuildContext context) {
    final nn = context.nn;
    final secs = remaining.inSeconds.clamp(0, 3600);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      FittedBox(
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          for (var i = 0; i < code.length; i++) ...[
            if (i == 3) const SizedBox(width: 18),
            Container(
              width: 54,
              height: 72,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: nn.bg,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: nn.line),
              ),
              child: DotTitle(code[i], size: 44),
            ),
          ],
        ]),
      ),
      const SizedBox(height: 16),
      Row(mainAxisSize: MainAxisSize.min, children: [
        const RedDot(size: 7),
        const SizedBox(width: 8),
        Text('En attente de l\'autre appareil · ${secs ~/ 60}:${two(secs % 60)}',
            style: TextStyle(color: nn.mid, fontSize: 13)),
      ]),
    ]);
  }
}

Future<void> showPairingCode(BuildContext context) async {
  final app = AppScope.read(context);
  final node = app.node;
  if (node == null || !node.isRunning) {
    toast(context, app.networkError ?? 'Réseau local indisponible');
    return;
  }
  final paired = await showDialog<PeerInfo>(
    context: context,
    barrierDismissible: false,
    builder: (c) => _ShowCodeDialog(node: node),
  );
  if (paired != null && context.mounted) toast(context, '« ${paired.name} » est associé. Synchronisation en cours…');
}

class _ShowCodeDialog extends StatefulWidget {
  const _ShowCodeDialog({required this.node});
  final LanNode node;
  @override
  State<_ShowCodeDialog> createState() => _ShowCodeDialogState();
}

class _ShowCodeDialogState extends State<_ShowCodeDialog> {
  late String _code;
  Timer? _tick;
  StreamSubscription<PeerInfo>? _paired;
  StreamSubscription<void>? _ended;
  bool _expired = false;

  @override
  void initState() {
    super.initState();
    _code = widget.node.startPairing();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _expired = widget.node.pairingCode == null);
    });
    _paired = widget.node.onPaired.listen((p) {
      if (mounted) Navigator.of(context).pop(p);
    });
    _ended = widget.node.onPairingEnded.listen((_) {
      if (mounted) setState(() => _expired = true);
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _paired?.cancel();
    _ended?.cancel();
    widget.node.stopPairing();
    super.dispose();
  }

  void _renew() => setState(() {
        _code = widget.node.startPairing();
        _expired = false;
      });

  @override
  Widget build(BuildContext context) {
    final nn = context.nn;
    final left = widget.node.pairingExpires?.difference(DateTime.now()) ?? Duration.zero;
    return AlertDialog(
      title: const Text('Associer un appareil', style: TextStyle(fontWeight: FontWeight.w600)),
      content: SizedBox(
        width: 440,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(
            'Sur l\'autre appareil : Nothing Notes › Appareils › Saisir un code.',
            textAlign: TextAlign.center,
            style: TextStyle(color: nn.mid, fontSize: 13.5),
          ),
          const SizedBox(height: 22),
          if (_expired)
            Column(children: [
              const Icon(Icons.timer_off_outlined, size: 36),
              const SizedBox(height: 10),
              const Text('Code expiré ou trop de tentatives.'),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: _renew, child: const Text('Nouveau code')),
            ])
          else
            PairingCodeView(code: _code, remaining: left),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Annuler'))],
    );
  }
}

// =================================================================== saisir un code
Future<void> enterPairingCode(BuildContext context) async {
  final app = AppScope.read(context);
  final node = app.node;
  if (node == null || !node.isRunning) {
    toast(context, app.networkError ?? 'Réseau local indisponible');
    return;
  }
  final paired = await showDialog<PeerInfo>(context: context, builder: (c) => _EnterCodeDialog(node: node));
  if (paired != null && context.mounted) toast(context, 'Associé à « ${paired.name} ». Synchronisation en cours…');
}

class _EnterCodeDialog extends StatefulWidget {
  const _EnterCodeDialog({required this.node});
  final LanNode node;
  @override
  State<_EnterCodeDialog> createState() => _EnterCodeDialogState();
}

class _EnterCodeDialogState extends State<_EnterCodeDialog> {
  final _code = TextEditingController();
  final _address = TextEditingController();
  bool _busy = false;
  bool _advanced = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    _address.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final p = await widget.node.joinWithCode(_code.text, address: _address.text.trim().isEmpty ? null : _address.text);
      if (mounted) Navigator.of(context).pop(p);
    } on PairingError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Association impossible : $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final nn = context.nn;
    return AlertDialog(
      title: const Text('Saisir le code', style: TextStyle(fontWeight: FontWeight.w600)),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Code à 6 chiffres affiché sur l\'autre appareil (Appareils › Afficher un code).',
              style: TextStyle(color: nn.mid, fontSize: 13.5)),
          const SizedBox(height: 18),
          TextField(
            controller: _code,
            autofocus: true,
            enabled: !_busy,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            maxLength: 6,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: const TextStyle(fontFamily: kFontDot, fontWeight: FontWeight.w900, fontSize: 34, letterSpacing: 10),
            decoration: const InputDecoration(counterText: '', hintText: '000000'),
            onChanged: (v) {
              if (v.length == 6 && !_busy) _go();
            },
            onSubmitted: (_) => _go(),
          ),
          if (_busy) ...[
            const SizedBox(height: 16),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 12),
              Text('Recherche de l\'appareil sur le réseau…', style: TextStyle(color: nn.mid, fontSize: 13)),
            ]),
          ],
          if (_error != null) ...[
            const SizedBox(height: 14),
            Text(_error!, style: const TextStyle(color: NColors.red, fontSize: 13.5)),
          ],
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => setState(() => _advanced = !_advanced),
              child: Text(_advanced ? 'Masquer l\'adresse' : 'L\'appareil n\'est pas trouvé ? Saisir son adresse',
                  style: TextStyle(fontSize: 12.5, color: nn.mid)),
            ),
          ),
          if (_advanced)
            TextField(
              controller: _address,
              enabled: !_busy,
              keyboardType: TextInputType.url,
              style: const TextStyle(fontFamily: kFontMono, fontSize: 14),
              decoration: const InputDecoration(hintText: '192.168.1.20', helperText: 'Visible dans Appareils › Cet appareil, sur l\'autre appareil'),
            ),
        ]),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: const Text('Annuler')),
        FilledButton(onPressed: _busy ? null : _go, child: const Text('Associer')),
      ],
    );
  }
}
