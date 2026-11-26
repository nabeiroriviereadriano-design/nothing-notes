import 'package:flutter_test/flutter_test.dart';
import 'package:nothing_notes/services/update_checker.dart';
import 'package:nothing_notes/state/app_controller.dart';

Map<String, dynamic> _release({String tag = 'v3.1.0', List<Map<String, dynamic>>? assets}) => {
      'tag_name': tag,
      'html_url': 'https://github.com/$kGithubRepo/releases/tag/$tag',
      'body': '## Téléchargements\n\n| a | b |\n\n## Nouveautés\n\n- **Mises à jour** depuis l\'application',
      'assets': assets ??
          [
            {
              'name': 'NothingNotes-3.1.0.apk',
              'size': 1000,
              'digest': 'sha256:ABCDEF',
              'browser_download_url': 'https://github.com/$kGithubRepo/releases/download/v3.1.0/NothingNotes-3.1.0.apk',
            },
            {
              'name': 'NothingNotes-3.1.0-portable.zip',
              'size': 2000,
              'browser_download_url': 'https://github.com/$kGithubRepo/releases/download/v3.1.0/NothingNotes-3.1.0-portable.zip',
            },
            {
              'name': 'NothingNotes-Setup-3.1.0.exe',
              'size': 3000,
              'browser_download_url': 'https://github.com/$kGithubRepo/releases/download/v3.1.0/NothingNotes-Setup-3.1.0.exe',
            },
          ],
    };

void main() {
  test('comparaison des versions', () {
    expect(isNewer('v3.1.0', '3.0.0'), isTrue);
    expect(isNewer('3.0.10', '3.0.9'), isTrue);
    expect(isNewer('v3.0.0', '3.0.0'), isFalse);
    expect(isNewer('2.9.9', '3.0.0'), isFalse);
  });

  test('choix du fichier à installer selon la plateforme', () {
    final u = UpdateInfo.fromRelease(_release(), '3.0.0');
    expect(u.newer, isTrue);
    expect(u.cleanVersion, '3.1.0');
    expect(u.assetFor('android')!.name, 'NothingNotes-3.1.0.apk');
    expect(u.assetFor('android')!.sha256, 'abcdef', reason: 'empreinte publiée par GitHub, en minuscules');
    expect(u.assetFor('windows')!.name, 'NothingNotes-Setup-3.1.0.exe', reason: 'l\'installateur, pas le .zip portable');
    expect(u.assetFor('windows')!.sha256, isNull);
    expect(u.assetFor('linux'), isNull);
  });

  test('un fichier hébergé ailleurs que sur les releases du dépôt est refusé', () {
    final u = UpdateInfo.fromRelease(
        _release(assets: [
          {'name': 'NothingNotes-3.1.0.apk', 'size': 1, 'browser_download_url': 'https://exemple.com/NothingNotes-3.1.0.apk'},
          {'name': 'NothingNotes-Setup-3.1.0.exe', 'size': 1, 'browser_download_url': 'http://github.com/$kGithubRepo/releases/download/v3.1.0/x.exe'},
        ]),
        '3.0.0');
    expect(u.assetFor('android'), isNull);
    expect(u.assetFor('windows'), isNull);
  });

  test('nouveautés affichées sans le tableau des téléchargements', () {
    final u = UpdateInfo.fromRelease(_release(), '3.0.0');
    final h = releaseHighlights(u.notes);
    expect(h, startsWith('- **Mises à jour**'));
    expect(h, isNot(contains('Téléchargements')));
  });
}
