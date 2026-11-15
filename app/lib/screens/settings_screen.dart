import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:notes_core/notes_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/exporter.dart';
import '../services/update_checker.dart';
import '../state/app_controller.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'devices_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final nn = context.nn;
    final s = app.syncStatus;
    return Scaffold(
      appBar: AppBar(title: const DotTitle('Paramètres', size: 22)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(padding: const EdgeInsets.fromLTRB(20, 0, 20, 40), children: [
            const SectionLabel('Synchronisation'),
            _Card(children: [
              ListTile(
                leading: const Icon(Icons.devices_rounded),
                title: const Text('Appareils associés'),
                subtitle: Text(
                  app.peers.isEmpty
                      ? 'Aucun — associer un téléphone ou un PC'
                      : app.peers.map((p) => p.info.name).join(', '),
                  style: TextStyle(color: nn.mid, fontSize: 12.5),
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DevicesScreen())),
              ),
              ListTile(
                leading: const Icon(Icons.cloud_outlined),
                title: SyncBadge(status: s),
                subtitle: s.state == SyncState.unpaired
                    ? null
                    : Padding(
                        padding: const EdgeInsets.only(left: 10),
                        child: Text(
                          [
                            if (s.lastSync != null) 'Dernière synchronisation : ${formatDate(s.lastSync!.toUtc())}',
                            if (s.message != null && s.state != SyncState.synced) s.message!,
                          ].join('\n'),
                          style: TextStyle(color: nn.mid, fontSize: 12.5),
                        ),
                      ),
              ),
              _Tile(Icons.sync_rounded, 'Synchroniser maintenant', () => app.syncNow()),
            ]),
            const SectionLabel('Apparence'),
            _Card(children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: SegmentedButton<ThemeMode>(
                  segments: const [
                    ButtonSegment(value: ThemeMode.dark, icon: Icon(Icons.dark_mode_outlined), label: Text('Sombre')),
                    ButtonSegment(value: ThemeMode.light, icon: Icon(Icons.light_mode_outlined), label: Text('Clair')),
                    ButtonSegment(value: ThemeMode.system, icon: Icon(Icons.brightness_auto_outlined), label: Text('Système')),
                  ],
                  selected: {app.themeMode},
                  showSelectedIcon: false,
                  onSelectionChanged: (v) => app.setThemeMode(v.first),
                  style: ButtonStyle(
                    backgroundColor: WidgetStateProperty.resolveWith((st) => st.contains(WidgetState.selected) ? nn.invertedBg : null),
                    foregroundColor: WidgetStateProperty.resolveWith((st) => st.contains(WidgetState.selected) ? nn.invertedFg : nn.fg),
                    side: WidgetStatePropertyAll(BorderSide(color: nn.line)),
                  ),
                ),
              ),
            ]),
            const SectionLabel('Données'),
            _Card(children: [
              _Tile(Icons.description_outlined, 'Exporter toutes les notes (Markdown)', () => _exportAll(context, 'md')),
              _Tile(Icons.picture_as_pdf_outlined, 'Exporter toutes les notes (PDF)', () => _exportAll(context, 'pdf')),
              _Tile(Icons.delete_sweep_outlined, 'Vider la corbeille', () async {
                if (await confirm(context,
                    title: 'Vider la corbeille ?',
                    message: 'Les notes de la corbeille seront supprimées définitivement sur tous vos appareils.',
                    ok: 'Vider',
                    danger: true)) {
                  app.repo?.emptyTrash();
                }
              }),
            ]),
            const SectionLabel('À propos'),
            _Card(children: [
              ListTile(
                leading: const NothingLogo(size: 30),
                title: const Text('Nothing Notes'),
                subtitle: Text('Version $kAppVersion · logiciel libre et gratuit', style: TextStyle(color: nn.mid)),
              ),
              _Tile(Icons.system_update_alt_rounded, 'Rechercher une mise à jour', () => _checkUpdate(context)),
              _Tile(Icons.code_rounded, 'Code source sur GitHub',
                  () => launchUrl(Uri.parse('https://github.com/$kGithubRepo'), mode: LaunchMode.externalApplication)),
              _Tile(Icons.gavel_outlined, 'Licences', () => showLicensePage(context: context, applicationName: 'Nothing Notes', applicationVersion: kAppVersion)),
            ]),
            const SizedBox(height: 16),
            Text(
              'Vos notes sont enregistrées sur cet appareil et ne transitent que directement entre vos appareils '
              'associés, sur votre réseau local, par une connexion chiffrée. Aucun compte, aucun serveur, rien sur Internet.',
              style: TextStyle(color: nn.mid, fontSize: 12, height: 1.45),
            ),
          ]),
        ),
      ),
    );
  }

  Future<void> _exportAll(BuildContext context, String format) async {
    final repo = AppScope.read(context).repo;
    if (repo == null) return;
    final notes = repo.allNotes().where((n) => !n.trashed).toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (notes.isEmpty) {
      toast(context, 'Aucune note à exporter');
      return;
    }
    try {
      final date = DateTime.now().toIso8601String().substring(0, 10);
      final Uint8List bytes = format == 'pdf'
          ? await buildPdf(repo, notes)
          : Uint8List.fromList(utf8.encode(exportAllMarkdown(notes, (n) => exportContextFor(repo, n))));
      final path = await saveBytes('nothing-notes-$date.$format', bytes);
      if (path != null && context.mounted) toast(context, '${notes.length} notes exportées');
    } catch (e) {
      if (context.mounted) toast(context, 'Export impossible : $e');
    }
  }

  Future<void> _checkUpdate(BuildContext context) async {
    toast(context, 'Recherche de mise à jour…');
    try {
      final u = await checkForUpdate();
      if (!context.mounted) return;
      if (u.newer) {
        if (await confirm(context,
            title: 'Version ${u.version} disponible',
            message: 'Téléchargez le nouvel installateur depuis GitHub. Vos notes sont conservées lors de la mise à jour.',
            ok: 'Télécharger')) {
          await launchUrl(Uri.parse(u.url), mode: LaunchMode.externalApplication);
        }
      } else {
        toast(context, 'Nothing Notes est à jour ($kAppVersion)');
      }
    } catch (e) {
      if (context.mounted) toast(context, 'Vérification impossible (hors ligne ?)');
    }
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

class _Tile extends StatelessWidget {
  const _Tile(this.icon, this.label, this.onTap);
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => ListTile(
        leading: Icon(icon),
        title: Text(label),
        trailing: Icon(Icons.chevron_right_rounded, color: context.nn.mid),
        onTap: onTap,
      );
}
