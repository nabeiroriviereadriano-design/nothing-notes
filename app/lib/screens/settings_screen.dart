import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:notes_core/notes_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/exporter.dart';
import '../state/app_controller.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/update_dialog.dart';
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
              _Tile(Icons.restore_page_outlined, 'Sauvegardes et restauration',
                  () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const BackupsScreen()))),
              _Tile(Icons.upload_file_rounded, 'Importer des fichiers Markdown…', () => _importMarkdown(context)),
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
              _Tile(
                app.updateAvailable != null ? Icons.new_releases_outlined : Icons.system_update_alt_rounded,
                app.updateAvailable != null
                    ? 'Installer la version ${app.updateAvailable!.cleanVersion}'
                    : 'Rechercher une mise à jour',
                () => checkAndOfferUpdate(context),
              ),
              SwitchListTile(
                key: const ValueKey('auto-update'),
                value: app.autoUpdateCheck,
                activeThumbColor: NColors.red,
                onChanged: (v) => app.setAutoUpdateCheck(v),
                title: const Text('Vérifier les mises à jour au démarrage'),
                subtitle: Text('Une fois par jour, auprès de GitHub. Rien n\'est envoyé.', style: TextStyle(color: nn.mid, fontSize: 12.5)),
              ),
              _Tile(Icons.code_rounded, 'Code source sur GitHub',
                  () => launchUrl(Uri.parse('https://github.com/$kGithubRepo'), mode: LaunchMode.externalApplication)),
              _Tile(Icons.gavel_outlined, 'Licences', () => showLicensePage(context: context, applicationName: 'Nothing Notes', applicationVersion: kAppVersion)),
            ]),
            const SizedBox(height: 16),
            Text(
              'Vos notes sont enregistrées sur cet appareil et ne transitent que directement entre vos appareils '
              'associés, sur votre réseau local, par une connexion chiffrée. Aucun compte, aucun serveur. Seule la '
              'recherche de mise à jour contacte GitHub (désactivable), sans rien envoyer.',
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
    final notes = repo.allNotes().where((n) => !n.trashed && !n.isTemplate).toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
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

  Future<void> _importMarkdown(BuildContext context) async {
    final app = AppScope.read(context);
    final repo = app.repo;
    if (repo == null) return;
    final files = await FilePicker.pickFiles(type: FileType.any);
    var count = 0, skipped = 0;
    String? last;
    for (final f in files) {
      if (!RegExp(r'\.(md|markdown|txt)$', caseSensitive: false).hasMatch(f.name)) {
        skipped++;
        continue;
      }
      try {
        final bytes = await f.readAsBytes();
        final text = utf8.decode(bytes, allowMalformed: true);
        last = repo.importMarkdown(text, fileName: f.name).id;
        count++;
      } catch (_) {
        skipped++;
      }
    }
    if (!context.mounted) return;
    if (count == 0) {
      toast(context, skipped > 0 ? 'Aucun fichier .md, .markdown ou .txt importé' : 'Aucun fichier choisi');
      return;
    }
    toast(context, '$count page(s) importée(s)${skipped > 0 ? ' · $skipped fichier(s) ignoré(s)' : ''}');
    if (last != null) {
      app.showView(NavView.all);
      app.select(last);
      Navigator.of(context).pop();
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


/// Sauvegardes de la base : création manuelle, liste, restauration.
class BackupsScreen extends StatefulWidget {
  const BackupsScreen({super.key});
  @override
  State<BackupsScreen> createState() => _BackupsScreenState();
}

class _BackupsScreenState extends State<BackupsScreen> {
  String _label(String l) => switch (l) {
        'manuelle' => 'Sauvegarde manuelle',
        'avant-restauration' => 'État remplacé lors d\'une restauration',
        'avant-mise-a-jour' => 'Avant l\'installation d\'une nouvelle version',
        _ when l.endsWith('avant-migration') => 'Avant la mise à jour (version ${l.replaceAll(RegExp(r'[^0-9]'), '')} des données)',
        _ => l,
      };

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final nn = context.nn;
    final list = app.ready && app.repo != null ? app.backups() : const <BackupInfo>[];
    return Scaffold(
      appBar: AppBar(title: const Text('Sauvegardes')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(padding: const EdgeInsets.fromLTRB(20, 0, 20, 40), children: [
            Text(
              'Une sauvegarde complète et vérifiée est créée automatiquement avant chaque mise à jour des données. '
              'Vous pouvez aussi en créer une à tout moment. Restaurer remplace toutes les notes de cet appareil par '
              'celles de la sauvegarde ; l\'état actuel est d\'abord sauvegardé lui aussi.',
              style: TextStyle(color: nn.mid, fontSize: 13, height: 1.45),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const ValueKey('backup-now'),
              onPressed: () {
                try {
                  final b = app.backupNow();
                  toast(context, 'Sauvegarde créée (${formatBytes(b.sizeBytes)})');
                } catch (e) {
                  toast(context, 'Sauvegarde impossible : $e');
                }
                setState(() {});
              },
              icon: const Icon(Icons.save_alt_rounded),
              label: const Text('Créer une sauvegarde maintenant'),
            ),
            const SectionLabel('Sauvegardes disponibles'),
            if (list.isEmpty) Text('Aucune sauvegarde pour le moment.', style: TextStyle(color: nn.mid)),
            for (final b in list)
              Container(
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: nn.card,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: nn.line),
                ),
                child: ListTile(
                  leading: Icon(b.label.endsWith('avant-migration') ? Icons.verified_outlined : Icons.inventory_outlined),
                  title: Text(_label(b.label)),
                  subtitle: Text('${formatDate(b.createdAt.toUtc())} · ${formatBytes(b.sizeBytes)}',
                      style: TextStyle(color: nn.mid, fontSize: 12.5)),
                  trailing: TextButton(onPressed: () => _restore(context, app, b), child: const Text('Restaurer')),
                ),
              ),
            const SizedBox(height: 12),
            SelectableText('Dossier : ${app.safety.backupsDir}', style: TextStyle(color: nn.mid, fontSize: 11.5)),
          ]),
        ),
      ),
    );
  }

  Future<void> _restore(BuildContext context, AppController app, BackupInfo b) async {
    String content;
    try {
      content = app.safety.inspect(b.path).describe();
    } catch (e) {
      toast(context, 'Sauvegarde illisible : $e');
      return;
    }
    final ok = await confirm(context,
        title: 'Restaurer cette sauvegarde ?',
        message: 'Elle contient : $content.\n\nToutes les notes actuelles de cet appareil seront remplacées. '
            'L\'état actuel est sauvegardé avant, vous pourrez donc revenir en arrière.\n\n'
            'Si des appareils sont associés, la synchronisation pourra ensuite ramener ici les modifications '
            'plus récentes qu\'ils possèdent.',
        ok: 'Restaurer',
        danger: true);
    if (!ok || !context.mounted) return;
    final nav = Navigator.of(context);
    nav.popUntil((r) => r.isFirst);
    try {
      await app.restoreBackup(b);
    } catch (e) {
      app.notice.value = 'Restauration impossible : $e';
    }
  }
}
