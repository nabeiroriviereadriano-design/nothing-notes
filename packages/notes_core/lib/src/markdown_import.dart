import 'models.dart';
import 'repository.dart';

/// Résultat de la lecture d'un fichier Markdown.
class MarkdownDoc {
  MarkdownDoc(this.title, this.blocks);
  final String title;
  final List<Block> blocks;
}

final _heading = RegExp(r'^(#{1,6})\s+(.*?)\s*#*\s*$');
final _todo = RegExp(r'^\s*[-*+]\s+\[([ xX])\]\s?(.*)$');
final _bullet = RegExp(r'^\s*[-*+]\s+(.*)$');
final _numbered = RegExp(r'^\s*\d+[.)]\s+(.*)$');
final _divider = RegExp(r'^\s*([-*_])(\s*\1){2,}\s*$');
final _fence = RegExp(r'^\s*(```|~~~)');
final _tableSep = RegExp(r'^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$');
final _image = RegExp(r'^\s*!\[([^\]]*)\]\(([^)]*)\)\s*$');

String _inline(String s) => s
    .replaceAllMapped(RegExp(r'<u>(.+?)</u>'), (m) => '++${m.group(1)}++')
    .replaceAllMapped(RegExp(r'<(?:b|strong)>(.+?)</(?:b|strong)>'), (m) => '**${m.group(1)}**')
    .replaceAllMapped(RegExp(r'<(?:i|em)>(.+?)</(?:i|em)>'), (m) => '*${m.group(1)}*')
    .replaceAllMapped(RegExp(r'(?<![\w_])__(?!\s)(.+?)(?<!\s)__(?![\w_])'), (m) => '**${m.group(1)}**')
    .replaceAll(RegExp(r'<br\s*/?>'), '\n');

List<String> _cells(String line) {
  var t = line.trim();
  if (t.startsWith('|')) t = t.substring(1);
  if (t.endsWith('|') && !t.endsWith(r'\|')) t = t.substring(0, t.length - 1);
  final out = <String>[];
  final cur = StringBuffer();
  for (var i = 0; i < t.length; i++) {
    if (t[i] == r'\' && i + 1 < t.length && t[i + 1] == '|') {
      cur.write('|');
      i++;
    } else if (t[i] == '|') {
      out.add(cur.toString().trim());
      cur.clear();
    } else {
      cur.write(t[i]);
    }
  }
  out.add(cur.toString().trim());
  return out;
}

/// Lit un document Markdown (CommonMark / GFM courant) et le convertit en blocs.
/// Rien n'est perdu : ce qui n'est pas reconnu devient un paragraphe tel quel.
MarkdownDoc parseMarkdown(String source, {String fallbackTitle = ''}) {
  var lines = source.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
  var title = '';

  // En-tête YAML éventuel (--- … ---) : on garde « title: ».
  if (lines.isNotEmpty && lines.first.trim() == '---') {
    final end = lines.indexWhere((l) => l.trim() == '---', 1);
    if (end > 0) {
      for (final l in lines.sublist(1, end)) {
        final m = RegExp(r'^title\s*:\s*(.*)$').firstMatch(l.trim());
        if (m != null) title = m.group(1)!.replaceAll(RegExp(r'''^["']|["']$'''), '').trim();
      }
      lines = lines.sublist(end + 1);
    }
  }

  // Un premier « # Titre » devient le titre de la page ; les niveaux suivants
  // remontent alors d'un cran (## → Titre 1), comme dans l'export Nothing Notes.
  var shift = 0;
  final firstIdx = lines.indexWhere((l) => l.trim().isNotEmpty);
  if (title.isEmpty && firstIdx >= 0) {
    final m = _heading.firstMatch(lines[firstIdx]);
    if (m != null && m.group(1)!.length == 1) {
      title = _inline(m.group(2)!);
      lines = [...lines.sublist(0, firstIdx), ...lines.sublist(firstIdx + 1)];
      final others = lines.map(_heading.firstMatch).whereType<RegExpMatch>().map((m) => m.group(1)!.length);
      shift = others.isNotEmpty && !others.contains(1) ? 1 : 0;
    }
  }
  if (title.isEmpty) title = fallbackTitle;

  final blocks = <Block>[];
  final para = <String>[];
  void flush() {
    if (para.isEmpty) return;
    blocks.add(Block(text: _inline(para.join('\n'))));
    para.clear();
  }

  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    final trimmed = line.trim();

    if (trimmed.isEmpty) {
      flush();
      i++;
      continue;
    }

    // Bloc de code
    if (_fence.hasMatch(line)) {
      flush();
      final marker = _fence.firstMatch(line)!.group(1)!;
      final code = <String>[];
      i++;
      while (i < lines.length && !lines[i].trim().startsWith(marker)) {
        code.add(lines[i]);
        i++;
      }
      i++; // clôture
      blocks.add(Block(type: BlockType.code, text: code.join('\n')));
      continue;
    }

    // Bloc repliable <details><summary>…</summary> … </details>
    if (trimmed.startsWith('<details')) {
      flush();
      var summary = '';
      final body = <String>[];
      var rest = trimmed.replaceFirst(RegExp(r'^<details[^>]*>'), '');
      i++;
      final buf = [if (rest.isNotEmpty) rest];
      while (i < lines.length && !buf.any((l) => l.contains('</details>'))) {
        buf.add(lines[i]);
        i++;
      }
      var all = buf.join('\n');
      final sm = RegExp(r'<summary>([\s\S]*?)</summary>').firstMatch(all);
      if (sm != null) {
        summary = sm.group(1)!.trim();
        all = all.replaceFirst(sm.group(0)!, '');
      }
      all = all.replaceFirst('</details>', '');
      body.addAll(all.split('\n'));
      blocks.add(Block(type: BlockType.toggle, text: _inline(summary), extra: {'body': _inline(body.join('\n').trim())}));
      continue;
    }

    final h = _heading.firstMatch(line);
    if (h != null) {
      flush();
      final level = (h.group(1)!.length - shift).clamp(1, 6);
      final type = level == 1 ? BlockType.heading1 : (level == 2 ? BlockType.heading2 : BlockType.heading3);
      blocks.add(Block(type: type, text: _inline(h.group(2)!)));
      i++;
      continue;
    }

    if (_divider.hasMatch(line)) {
      flush();
      blocks.add(Block(type: BlockType.divider));
      i++;
      continue;
    }

    // Tableau GFM
    if (trimmed.contains('|') && i + 1 < lines.length && _tableSep.hasMatch(lines[i + 1])) {
      flush();
      final rows = <List<String>>[_cells(line)];
      i += 2;
      while (i < lines.length && lines[i].trim().contains('|') && lines[i].trim().isNotEmpty) {
        rows.add(_cells(lines[i]));
        i++;
      }
      final width = rows.map((r) => r.length).reduce((a, b) => a > b ? a : b);
      for (final r in rows) {
        while (r.length < width) {
          r.add('');
        }
      }
      blocks.add(Block(type: BlockType.table, rows: rows.map((r) => r.map(_inline).toList()).toList()));
      continue;
    }

    if (trimmed.startsWith('>')) {
      flush();
      final q = <String>[];
      while (i < lines.length && lines[i].trim().startsWith('>')) {
        q.add(lines[i].trim().replaceFirst(RegExp(r'^>\s?'), ''));
        i++;
      }
      blocks.add(Block(type: BlockType.quote, text: _inline(q.join('\n'))));
      continue;
    }

    final t = _todo.firstMatch(line);
    if (t != null) {
      flush();
      blocks.add(Block(type: BlockType.todo, text: _inline(t.group(2)!), checked: t.group(1)!.toLowerCase() == 'x'));
      i++;
      continue;
    }
    final img = _image.firstMatch(line);
    if (img != null) {
      flush();
      final alt = img.group(1)!.trim();
      blocks.add(Block(text: '[Image : ${alt.isEmpty ? img.group(2) : alt}]'));
      i++;
      continue;
    }
    final b = _bullet.firstMatch(line);
    if (b != null && !_divider.hasMatch(line)) {
      flush();
      blocks.add(Block(type: BlockType.bullet, text: _inline(b.group(1)!)));
      i++;
      continue;
    }
    final n = _numbered.firstMatch(line);
    if (n != null) {
      flush();
      blocks.add(Block(type: BlockType.numbered, text: _inline(n.group(1)!)));
      i++;
      continue;
    }

    para.add(line.trimRight());
    i++;
  }
  flush();
  if (blocks.isEmpty) blocks.add(Block());
  return MarkdownDoc(title, blocks);
}

extension MarkdownImportX on NotesRepository {
  /// Importe un fichier Markdown comme NOUVELLE page : aucune page existante
  /// n'est modifiée.
  Note importMarkdown(String source, {String fileName = '', String? folderId, String? parentId}) {
    final base = fileName.replaceAll(RegExp(r'\.(md|markdown|txt)$', caseSensitive: false), '').trim();
    final doc = parseMarkdown(source, fallbackTitle: base);
    return createNote(title: doc.title, blocks: doc.blocks, folderId: folderId, parentId: parentId);
  }

  /// Texte partagé depuis une autre appli (Android) : nouvelle page.
  Note importSharedText(String text, {String? subject}) {
    final trimmed = text.trim();
    final looksMd = RegExp(r'^(#|\s*[-*]\s|\s*\d+\.\s|>|```)', multiLine: true).hasMatch(trimmed);
    if (looksMd) return importMarkdown(trimmed, fileName: subject ?? '');
    final lines = trimmed.split('\n');
    final title = (subject ?? '').trim().isNotEmpty ? subject!.trim() : (lines.first.length <= 80 ? lines.first.trim() : '');
    final body = title == lines.first.trim() && (subject ?? '').trim().isEmpty ? lines.skip(1).join('\n').trim() : trimmed;
    return createNote(title: title, blocks: [Block(text: body)]);
  }
}
