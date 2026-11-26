import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/update_checker.dart';
import '../state/app_controller.dart';
import '../theme.dart';
import 'common.dart';

/// Vérifie puis propose la mise à jour (bouton des paramètres).
Future<void> checkAndOfferUpdate(BuildContext context) async {
  toast(context, 'Recherche de mise à jour…');
  final app = AppScope.read(context);
  try {
    await app.autoCheckUpdate(force: true);
  } catch (_) {}
  if (!context.mounted) return;
  final u = app.updateAvailable;
  if (u == null) {
    toast(context, 'Nothing Notes est à jour ($kAppVersion)');
    return;
  }
  await showUpdateDialog(context, u);
}

Future<void> showUpdateDialog(BuildContext context, UpdateInfo u) => showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (c) => _UpdateDialog(info: u),
    );

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({required this.info});
  final UpdateInfo info;
  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

enum _Step { ready, downloading, installing, permission, error }

class _UpdateDialogState extends State<_UpdateDialog> {
  _Step _step = _Step.ready;
  double? _progress;
  String _error = '';

  String get _platform => Platform.isAndroid ? 'android' : (Platform.isWindows ? 'windows' : 'autre');

  ReleaseAsset? get _asset {
    if (Platform.isWindows && !windowsInstalled) return null; // version portable : mise à jour manuelle
    return widget.info.assetFor(_platform);
  }

  Future<void> _install() async {
    final a = _asset;
    if (a == null) return;
    final app = AppScope.read(context);
    setState(() {
      _step = _Step.downloading;
      _progress = 0;
    });
    try {
      final f = await downloadAsset(a, onProgress: (r, t) {
        if (mounted && t > 0) setState(() => _progress = r / t);
      });
      if (!mounted) return;
      setState(() => _step = _Step.installing);
      if (Platform.isWindows) {
        // Tout est enregistré et sauvegardé, la base est fermée proprement,
        // puis l'installateur remplace l'application et la relance.
        await app.prepareForUpdate(closeAll: true);
        await launchInstaller(f);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        exit(0);
      }
      await app.prepareForUpdate(closeAll: false);
      final r = await launchInstaller(f);
      if (!mounted) return;
      if (r == 'permission') {
        setState(() => _step = _Step.permission);
      } else {
        Navigator.of(context).pop();
      }
    } on UpdateError catch (e) {
      if (mounted) {
        setState(() {
          _step = _Step.error;
          _error = e.message;
        });
      }
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() {
          _step = _Step.error;
          _error = 'Installation impossible : ${e.message ?? e.code}';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _step = _Step.error;
          _error = 'Mise à jour impossible : $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final nn = context.nn;
    final u = widget.info;
    final a = _asset;
    final notes = releaseHighlights(u.notes);
    final busy = _step == _Step.downloading || _step == _Step.installing;
    return AlertDialog(
      title: Text('Version ${u.cleanVersion} disponible'),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Version installée : $kAppVersion', style: TextStyle(color: nn.mid, fontSize: 13)),
          if (notes.isNotEmpty) ...[
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: SingleChildScrollView(
                child: Text(
                  notes.replaceAll(RegExp(r'\*\*|`'), '').replaceAll(RegExp(r'^- ', multiLine: true), '•  '),
                  style: const TextStyle(fontSize: 13.5, height: 1.45),
                ),
              ),
            ),
          ],
          const SizedBox(height: 14),
          switch (_step) {
            _Step.ready => Text(
                a == null
                    ? (Platform.isWindows
                        ? 'Version portable : téléchargez le nouveau .zip depuis GitHub.'
                        : 'Téléchargez la nouvelle version depuis GitHub.')
                    : (Platform.isWindows
                        ? 'Vos notes sont enregistrées et sauvegardées, puis l\'application se ferme, se met à jour et se relance toute seule.'
                        : 'Vos notes sont enregistrées et sauvegardées, puis Android vous demande de confirmer l\'installation. Vos notes sont conservées.'),
                style: TextStyle(color: nn.mid, fontSize: 13),
              ),
            _Step.downloading => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                LinearProgressIndicator(value: _progress, color: NColors.red, backgroundColor: nn.line),
                const SizedBox(height: 6),
                Text('Téléchargement… ${((_progress ?? 0) * 100).round()} %', style: TextStyle(color: nn.mid, fontSize: 12.5)),
              ]),
            _Step.installing => Text(Platform.isWindows ? 'Installation… l\'application va redémarrer.' : 'Ouverture de l\'installateur…',
                style: TextStyle(color: nn.mid, fontSize: 13)),
            _Step.permission => Text(
                'Android demande d\'autoriser Nothing Notes à installer des applications. Activez l\'autorisation, revenez ici, puis touchez « Installer » à nouveau.',
                style: TextStyle(color: nn.fg, fontSize: 13),
              ),
            _Step.error => Text(_error, style: TextStyle(color: redText(context), fontSize: 13)),
          },
        ]),
      ),
      actions: [
        if (!busy)
          TextButton(
            onPressed: () {
              AppScope.read(context).dismissUpdate(u);
              Navigator.of(context).pop();
            },
            child: const Text('Plus tard'),
          ),
        if (!busy && a == null)
          FilledButton(
            onPressed: () => launchUrl(Uri.parse(u.url), mode: LaunchMode.externalApplication),
            child: const Text('Ouvrir GitHub'),
          ),
        if (!busy && a != null)
          FilledButton(
            key: const ValueKey('update-install'),
            style: FilledButton.styleFrom(backgroundColor: NColors.red, foregroundColor: Colors.white),
            onPressed: _install,
            child: Text(_step == _Step.error ? 'Réessayer' : 'Installer'),
          ),
      ],
    );
  }
}
