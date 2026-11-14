import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Dossier des données de l'application sur cet appareil.
///  * Windows : %APPDATA%\NothingNotes (supprimable à la désinstallation)
///  * Android : stockage privé de l'application
Future<Directory> appDataDir() async {
  Directory dir;
  if (Platform.isWindows) {
    final base = Platform.environment['APPDATA'] ?? (await getApplicationSupportDirectory()).path;
    dir = Directory(p.join(base, 'NothingNotes'));
  } else {
    dir = await getApplicationSupportDirectory();
  }
  await dir.create(recursive: true);
  return dir;
}

/// Petits réglages persistants (fichier JSON dans le dossier de l'application).
class SettingsFile {
  SettingsFile(this.dir);
  final Directory dir;
  Map<String, dynamic> _data = {};

  File get _file => File(p.join(dir.path, 'settings.json'));

  Future<void> load() async {
    try {
      if (await _file.exists()) {
        _data = Map<String, dynamic>.from(jsonDecode(await _file.readAsString()) as Map);
      }
    } catch (_) {
      _data = {};
    }
  }

  T? get<T>(String key) {
    final v = _data[key];
    return v is T ? v : null;
  }

  Future<void> set(String key, Object? value) async {
    if (value == null) {
      _data.remove(key);
    } else {
      _data[key] = value;
    }
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(jsonEncode(_data), flush: true);
    await tmp.rename(_file.path);
  }
}
