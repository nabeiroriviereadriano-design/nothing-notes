// Génère une base de données avec le code de Nothing Notes 2.0.0.
// Exécuté en CI dans une copie de travail de la version 2.0.0 (commit 6b89c98),
// pour tester la migration vers la 3.0.0 sur une base réellement produite par
// l'ancienne version. Structure calquée sur une base réelle : tous les types
// de blocs, pièces jointes, note purgée, historique, appareil appairé,
// état de synchro et conflit en attente.
//
//   dart run tool/v2_fixture.dart <sortie.db> <dossier-fichiers>
import 'dart:io';
import 'dart:typed_data';

import 'package:notes_core/notes_core.dart';

void main(List<String> args) {
  final dbPath = args[0];
  final filesDir = args[1];
  Directory(filesDir).createSync(recursive: true);
  final store = LocalStore.open(dbPath);
  final repo = NotesRepository(store: store, filesDir: filesDir);
  store.deviceName = 'PC de test';
  store.historyInterval = Duration.zero;

  final cours = repo.createFolder('Cours');
  final sous = repo.createFolder('Électrotechnique', parentId: cours.id);
  final perso = repo.createFolder('Perso');
  final tag = repo.createTag('important');
  final tag2 = repo.createTag('bts');

  final notes = <Note>[];
  for (var i = 0; i < 12; i++) {
    final n = repo.createNote(
      title: 'Note $i — accentuée éàç',
      folderId: [null, cours.id, sous.id, perso.id][i % 4],
      tags: i % 3 == 0 ? [tag.id] : (i % 3 == 1 ? [tag.id, tag2.id] : []),
      blocks: [
        Block(type: BlockType.heading1, text: 'Titre **gras** $i'),
        Block(text: 'Paragraphe avec *italique*, ++souligné++, ~~barré~~, `code` et [lien](https://exemple.fr).\nDeuxième ligne.'),
        Block(type: BlockType.heading2, text: 'Sous-titre'),
        Block(type: BlockType.bullet, text: 'puce'),
        Block(type: BlockType.numbered, text: 'un'),
        Block(type: BlockType.numbered, text: 'deux'),
        Block(type: BlockType.todo, text: 'à faire', checked: i.isEven),
        Block(type: BlockType.quote, text: 'citation'),
        Block(type: BlockType.code, text: 'void main() {\n  print("x");\n}'),
        Block(type: BlockType.divider),
        Block(type: BlockType.table, rows: [
          ['A', 'B'],
          ['1', '2|3'],
        ]),
      ],
    );
    notes.add(n);
  }
  repo.setFavorite(notes[1].id, true);
  repo.setArchived(notes[2].id, true);

  // Pièces jointes (image + fichier), y compris un nom avec accents.
  for (var i = 0; i < 6; i++) {
    final n = notes[i];
    final img = repo.addAttachment(n.id, fileName: 'photo é $i.png', bytes: Uint8List.fromList(List.generate(300 + i, (k) => k % 256)));
    final doc = repo.addAttachment(n.id, fileName: 'doc$i.pdf', bytes: Uint8List.fromList(List.generate(500, (k) => (k * 7) % 256)));
    final cur = repo.note(n.id)!;
    cur.blocks.add(Block(type: BlockType.image, attachmentId: img.id));
    cur.blocks.add(Block(type: BlockType.file, attachmentId: doc.id));
    repo.saveNote(cur);
  }

  // Plusieurs versions dans l'historique.
  for (var v = 0; v < 4; v++) {
    final n = repo.note(notes[3].id)!;
    n.blocks.first.text = 'Version $v';
    repo.saveNote(n);
  }

  // Corbeille et note purgée (pierre tombale conservée pour la synchro).
  repo.trashNote(notes[10].id);
  repo.trashNote(notes[11].id);
  repo.purgeNote(notes[11].id);

  // Appareil appairé + état de synchro + conflit en attente.
  final peerId = 'zzzz-peer-device';
  store.addPeer(peerId, name: 'Téléphone', platform: 'android', address: '192.168.1.20', port: 45893);
  final n4 = store.get(EntityType.notes, notes[4].id)!;
  store.markEqual(peerId, EntityType.notes, n4.id, n4.data, 3);
  final remote = Map<String, dynamic>.from(n4.data)..['title'] = 'Titre modifié sur le téléphone';
  store.setConflict(peerId, EntityType.notes, n4.id, remote, 4);

  store.close();
  stdout.writeln('Base 2.0.0 générée : $dbPath');
}
