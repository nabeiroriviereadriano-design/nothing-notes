import 'dart:convert';

import 'inline.dart';
import 'models.dart';

/// Informations annexes pour l'export d'une note.
class ExportContext {
  ExportContext({
    this.tagNames = const [],
    this.folderName,
    this.attachmentName,
    this.imageDataUri,
    this.properties = const [],
    this.table,
    this.subPages = const [],
  });

  /// Propriétés de l'entrée de base de données (nom, valeur affichée).
  final List<(String, String)> properties;

  /// Contenu d'une base de données : première ligne = en-têtes.
  final List<List<String>>? table;

  /// Titres des sous-pages.
  final List<String> subPages;

  final List<String> tagNames;
  final String? folderName;

  /// Nom de fichier d'une pièce jointe à partir de son identifiant.
  final String? Function(String attachmentId)? attachmentName;

  /// Image encodée en `data:` URI pour l'intégrer au HTML (facultatif).
  final String? Function(String attachmentId)? imageDataUri;
}

String _title(Note n) => n.title.trim().isEmpty ? 'Sans titre' : n.title.trim();

/// Nom de fichier proposé pour l'export.
String exportFileName(Note n, String extension) {
  final base = _title(n).replaceAll(RegExp(r'[\\/:*?"<>|\n\r]+'), ' ').trim();
  final short = base.length > 60 ? base.substring(0, 60).trim() : base;
  return '${short.isEmpty ? 'note' : short}.$extension';
}

// ------------------------------------------------------------------ TXT
String exportTxt(Note n, [ExportContext? ctx]) {
  final b = StringBuffer()
    ..writeln(_title(n))
    ..writeln('=' * _title(n).length)
    ..writeln();
  for (final (k, v) in ctx?.properties ?? const <(String, String)>[]) {
    b.writeln('$k : $v');
  }
  if (ctx?.properties.isNotEmpty ?? false) b.writeln();
  var counter = 0;
  for (final blk in n.blocks) {
    if (blk.type != BlockType.numbered) counter = 0;
    final t = stripInlineMarkers(blk.text);
    switch (blk.type) {
      case BlockType.heading1:
        b
          ..writeln()
          ..writeln(t.toUpperCase());
        break;
      case BlockType.heading2:
      case BlockType.heading3:
        b
          ..writeln()
          ..writeln(t);
        break;
      case BlockType.toggle:
        b.writeln('▸ $t');
        for (final l in stripInlineMarkers(blk.body).split('\n')) {
          b.writeln('    $l');
        }
        break;
      case BlockType.quote:
        b.writeln('> $t');
        break;
      case BlockType.bullet:
        b.writeln('• $t');
        break;
      case BlockType.numbered:
        b.writeln('${++counter}. $t');
        break;
      case BlockType.todo:
        b.writeln('${blk.checked ? '[x]' : '[ ]'} $t');
        break;
      case BlockType.code:
        b.writeln(blk.text);
        break;
      case BlockType.divider:
        b.writeln('----------------------------------------');
        break;
      case BlockType.image:
      case BlockType.file:
        final name = blk.attachmentId == null ? null : ctx?.attachmentName?.call(blk.attachmentId!);
        b.writeln('[${blk.type == BlockType.image ? 'Image' : 'Fichier'} : ${name ?? 'pièce jointe'}]');
        break;
      case BlockType.table:
        for (final r in blk.rows ?? const <List<String>>[]) {
          b.writeln(r.join('\t'));
        }
        break;
      default:
        b.writeln(t);
    }
  }
  _txtExtras(b, ctx);
  return b.toString();
}

void _txtExtras(StringBuffer b, ExportContext? ctx) {
  final t = ctx?.table;
  if (t != null && t.isNotEmpty) {
    b.writeln();
    for (final r in t) {
      b.writeln(r.join('\t'));
    }
  }
  if (ctx != null && ctx.subPages.isNotEmpty) {
    b
      ..writeln()
      ..writeln('Sous-pages :');
    for (final s in ctx.subPages) {
      b.writeln('• $s');
    }
  }
}

// ------------------------------------------------------------------ Markdown
String _mdInline(String s) => s
    .replaceAllMapped(RegExp(r'\+\+(.+?)\+\+'), (m) => '<u>${m.group(1)}</u>')
    // Liens internes : le titre de la page, sans lien (l'identifiant n'a pas de sens hors de l'appli).
    .replaceAllMapped(RegExp(r'\[([^\]\n]+)\]\(nn:page:[A-Za-z0-9-]+\)'), (m) => '**${m.group(1)}**');

String _mdCell(String c) => c.replaceAll('|', r'\|').replaceAll('\n', ' ');

void _mdTable(StringBuffer b, List<List<String>> rows) {
  if (rows.isEmpty) return;
  String line(List<String> r) => '| ${r.map(_mdCell).join(' | ')} |';
  b.writeln(line(rows.first));
  b.writeln('| ${rows.first.map((_) => '---').join(' | ')} |');
  for (final r in rows.skip(1)) {
    b.writeln(line(r));
  }
}

String exportMarkdown(Note n, [ExportContext? ctx]) {
  final b = StringBuffer()..writeln('# ${_title(n)}');
  final meta = <String>[
    if (ctx?.folderName != null) 'Dossier : ${ctx!.folderName}',
    if (ctx != null && ctx.tagNames.isNotEmpty) 'Étiquettes : ${ctx.tagNames.map((t) => '#$t').join(' ')}',
  ];
  if (meta.isNotEmpty) {
    b
      ..writeln()
      ..writeln('*${meta.join(' · ')}*');
  }
  if (ctx != null && ctx.properties.isNotEmpty) {
    b.writeln();
    for (final (k, v) in ctx.properties) {
      b.writeln('- **${_mdCell(k)}** : ${_mdCell(v)}');
    }
  }
  b.writeln();
  var counter = 0;
  String? prev;
  for (final blk in n.blocks) {
    if (blk.type != BlockType.numbered) counter = 0;
    final list = {BlockType.bullet, BlockType.numbered, BlockType.todo};
    if (prev != null && !(list.contains(prev) && list.contains(blk.type))) b.writeln();
    final t = _mdInline(blk.text);
    switch (blk.type) {
      case BlockType.heading1:
        b.writeln('## $t');
        break;
      case BlockType.heading2:
        b.writeln('### $t');
        break;
      case BlockType.heading3:
        b.writeln('#### $t');
        break;
      case BlockType.toggle:
        b
          ..writeln('<details>')
          ..writeln('<summary>${_esc.convert(stripInlineMarkers(blk.text))}</summary>')
          ..writeln()
          ..writeln(_mdInline(blk.body))
          ..writeln()
          ..writeln('</details>');
        break;
      case BlockType.quote:
        b.writeln(t.split('\n').map((l) => '> $l').join('\n'));
        break;
      case BlockType.bullet:
        b.writeln('- $t');
        break;
      case BlockType.numbered:
        b.writeln('${++counter}. $t');
        break;
      case BlockType.todo:
        b.writeln('- [${blk.checked ? 'x' : ' '}] $t');
        break;
      case BlockType.code:
        b
          ..writeln('```')
          ..writeln(blk.text)
          ..writeln('```');
        break;
      case BlockType.divider:
        b.writeln('---');
        break;
      case BlockType.image:
      case BlockType.file:
        final name = (blk.attachmentId == null ? null : ctx?.attachmentName?.call(blk.attachmentId!)) ?? 'pièce jointe';
        b.writeln(blk.type == BlockType.image ? '![$name]($name)' : '[$name]($name)');
        break;
      case BlockType.table:
        _mdTable(b, blk.rows ?? const <List<String>>[]);
        break;
      default:
        b.writeln(t);
    }
    prev = blk.type;
  }
  if (ctx?.table case final t? when t.isNotEmpty) {
    b.writeln();
    _mdTable(b, t);
  }
  if (ctx != null && ctx.subPages.isNotEmpty) {
    b
      ..writeln()
      ..writeln('**Sous-pages**')
      ..writeln();
    for (final s in ctx.subPages) {
      b.writeln('- $s');
    }
  }
  return b.toString();
}

/// Toutes les notes dans un seul document Markdown.
String exportAllMarkdown(List<Note> notes, ExportContext Function(Note n) ctxOf) {
  final b = StringBuffer();
  for (final n in notes) {
    b
      ..write(exportMarkdown(n, ctxOf(n)))
      ..writeln()
      ..writeln('\n---\n');
  }
  return b.toString();
}

// ------------------------------------------------------------------ HTML
const _esc = HtmlEscape(HtmlEscapeMode.element);
const _escAttr = HtmlEscape(HtmlEscapeMode.attribute);

String inlineToHtml(String s) {
  final b = StringBuffer();
  for (final t in parseInline(s)) {
    if (t.marker) continue;
    var h = _esc.convert(t.text).replaceAll('\n', '<br>');
    if (t.styles.contains(InlineStyle.code)) h = '<code>$h</code>';
    if (t.styles.contains(InlineStyle.bold)) h = '<strong>$h</strong>';
    if (t.styles.contains(InlineStyle.italic)) h = '<em>$h</em>';
    if (t.styles.contains(InlineStyle.underline)) h = '<u>$h</u>';
    if (t.styles.contains(InlineStyle.strike)) h = '<s>$h</s>';
    if (t.link != null) {
      h = t.link!.startsWith(kPageLinkPrefix)
          ? '<span class="pagelink">$h</span>'
          : '<a href="${_escAttr.convert(t.link!)}">$h</a>';
    }
    b.write(h);
  }
  return b.toString();
}

String exportHtml(Note n, [ExportContext? ctx]) {
  final b = StringBuffer();
  String? openList;
  void closeList() {
    if (openList != null) {
      b.writeln('</$openList>');
      openList = null;
    }
  }

  void ensureList(String tag, [String cls = '']) {
    if (openList != tag) {
      closeList();
      b.writeln(cls.isEmpty ? '<$tag>' : '<$tag class="$cls">');
      openList = tag;
    }
  }

  String? lastListClass;
  for (final blk in n.blocks) {
    final h = inlineToHtml(blk.text);
    switch (blk.type) {
      case BlockType.bullet:
        if (lastListClass != 'b') closeList();
        ensureList('ul');
        lastListClass = 'b';
        b.writeln('<li>$h</li>');
        continue;
      case BlockType.todo:
        if (lastListClass != 't') closeList();
        ensureList('ul', 'todo');
        lastListClass = 't';
        b.writeln('<li class="${blk.checked ? 'done' : ''}"><span class="box">${blk.checked ? '✓' : ''}</span>$h</li>');
        continue;
      case BlockType.numbered:
        ensureList('ol');
        lastListClass = 'n';
        b.writeln('<li>$h</li>');
        continue;
    }
    closeList();
    lastListClass = null;
    switch (blk.type) {
      case BlockType.heading1:
        b.writeln('<h2>$h</h2>');
        break;
      case BlockType.heading2:
        b.writeln('<h3>$h</h3>');
        break;
      case BlockType.heading3:
        b.writeln('<h4>$h</h4>');
        break;
      case BlockType.toggle:
        b.writeln('<details${blk.collapsed ? '' : ' open'}><summary>$h</summary><p>${inlineToHtml(blk.body)}</p></details>');
        break;
      case BlockType.quote:
        b.writeln('<blockquote>$h</blockquote>');
        break;
      case BlockType.code:
        b.writeln('<pre><code>${_esc.convert(blk.text)}</code></pre>');
        break;
      case BlockType.divider:
        b.writeln('<hr>');
        break;
      case BlockType.image:
        final uri = blk.attachmentId == null ? null : ctx?.imageDataUri?.call(blk.attachmentId!);
        final name = (blk.attachmentId == null ? null : ctx?.attachmentName?.call(blk.attachmentId!)) ?? 'image';
        b.writeln(uri != null
            ? '<figure><img src="$uri" alt="${_escAttr.convert(name)}"></figure>'
            : '<p class="att">🖼 ${_esc.convert(name)}</p>');
        break;
      case BlockType.file:
        final name = (blk.attachmentId == null ? null : ctx?.attachmentName?.call(blk.attachmentId!)) ?? 'fichier';
        b.writeln('<p class="att">📎 ${_esc.convert(name)}</p>');
        break;
      case BlockType.table:
        b.writeln('<table>');
        final rows = blk.rows ?? const <List<String>>[];
        for (var i = 0; i < rows.length; i++) {
          final tag = i == 0 ? 'th' : 'td';
          b.writeln('<tr>${rows[i].map((c) => '<$tag>${_esc.convert(c)}</$tag>').join()}</tr>');
        }
        b.writeln('</table>');
        break;
      default:
        if (blk.text.trim().isNotEmpty) b.writeln('<p>$h</p>');
    }
  }
  closeList();
  String table(List<List<String>> rows) {
    final t = StringBuffer('<table>');
    for (var i = 0; i < rows.length; i++) {
      final tag = i == 0 ? 'th' : 'td';
      t.write('<tr>${rows[i].map((c) => '<$tag>${_esc.convert(c)}</$tag>').join()}</tr>');
    }
    return '$t</table>';
  }

  final props = (ctx == null || ctx.properties.isEmpty)
      ? ''
      : '<dl class="props">${ctx.properties.map((e) => '<dt>${_esc.convert(e.$1)}</dt><dd>${_esc.convert(e.$2)}</dd>').join()}</dl>';
  if (ctx?.table case final t? when t.isNotEmpty) b.writeln(table(t));
  if (ctx != null && ctx.subPages.isNotEmpty) {
    b.writeln('<h3>Sous-pages</h3><ul>${ctx.subPages.map((s) => '<li>${_esc.convert(s)}</li>').join()}</ul>');
  }

  final tags = ctx == null ? '' : ctx.tagNames.map((t) => '<span class="tag">${_esc.convert(t)}</span>').join();
  final folder = ctx?.folderName == null ? '' : '<span class="folder">${_esc.convert(ctx!.folderName!)}</span>';
  return '''<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${_esc.convert(_title(n))}</title>
<style>
  :root { color-scheme: light dark; --bg:#F5F5F5; --fg:#080808; --mid:#858585; --card:#FFFFFF; --line:#DADADA; --red:#E60012; }
  @media (prefers-color-scheme: dark) { :root { --bg:#080808; --fg:#F5F5F5; --card:#171717; --line:#292929; } }
  body { background:var(--bg); color:var(--fg); font:16px/1.6 Inter,"Segoe UI",Roboto,sans-serif; margin:0; padding:40px 20px; }
  main { max-width:760px; margin:0 auto; }
  h1 { font-size:34px; letter-spacing:.02em; margin:0 0 8px; }
  h1::after { content:""; display:inline-block; width:3px; height:.9em; background:var(--red); margin-left:8px; vertical-align:-2px; }
  .meta { color:var(--mid); font-size:13px; margin-bottom:28px; }
  .tag, .folder { display:inline-block; border:1px solid var(--line); border-radius:999px; padding:2px 12px; margin-right:6px; }
  h2 { font-size:24px; margin:28px 0 8px; } h3 { font-size:19px; margin:22px 0 6px; } h4 { font-size:16px; margin:18px 0 4px; }
  details { border:1px solid var(--line); border-radius:12px; padding:8px 14px; margin:10px 0; } summary { cursor:pointer; font-weight:600; }
  .pagelink { border-bottom:1px solid var(--red); }
  dl.props { display:grid; grid-template-columns:max-content 1fr; gap:4px 16px; margin:0 0 24px; } dt { color:var(--mid); } dd { margin:0; }
  a { color:var(--red); }
  blockquote { border-left:3px solid var(--red); margin:12px 0; padding:4px 16px; color:var(--mid); }
  pre { background:var(--card); border:1px solid var(--line); border-radius:14px; padding:16px; overflow:auto; }
  code { font-family:"Cascadia Mono",Consolas,monospace; font-size:14px; }
  hr { border:0; border-top:2px dotted var(--mid); margin:24px 0; }
  ul.todo { list-style:none; padding-left:4px; }
  ul.todo .box { display:inline-block; width:18px; height:18px; border:1.5px solid var(--fg); border-radius:4px; margin-right:10px; text-align:center; line-height:17px; font-size:13px; vertical-align:1px; }
  ul.todo li.done .box { background:var(--red); border-color:var(--red); color:#fff; }
  ul.todo li.done { color:var(--mid); }
  table { border-collapse:collapse; width:100%; margin:14px 0; } th, td { border:1px solid var(--line); padding:8px 12px; text-align:left; }
  th { background:var(--card); }
  figure { margin:16px 0; } img { max-width:100%; border-radius:14px; }
  .att { color:var(--mid); }
</style>
</head>
<body><main>
<h1>${_esc.convert(_title(n))}</h1>
<div class="meta">$folder$tags Modifiée le ${n.updatedAt.toLocal().toString().substring(0, 16)}</div>
$props
$b
</main></body>
</html>
''';
}
