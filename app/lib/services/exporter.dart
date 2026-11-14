import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:notes_core/notes_core.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

enum ExportFormat { txt, md, html, pdf }

extension ExportFormatX on ExportFormat {
  String get ext => switch (this) {
        ExportFormat.txt => 'txt',
        ExportFormat.md => 'md',
        ExportFormat.html => 'html',
        ExportFormat.pdf => 'pdf',
      };
  String get label => switch (this) {
        ExportFormat.txt => 'Texte (.txt)',
        ExportFormat.md => 'Markdown (.md)',
        ExportFormat.html => 'Page web (.html)',
        ExportFormat.pdf => 'PDF (.pdf)',
      };
}

ExportContext exportContextFor(NotesRepository repo, Note n) {
  final tags = {for (final t in repo.tags()) t.id: t.name};
  final folder = repo.folders().where((f) => f.id == n.folderId).firstOrNull?.name;
  return ExportContext(
    tagNames: n.tags.map((t) => tags[t]).whereType<String>().toList(),
    folderName: folder,
    attachmentName: (id) => repo.attachment(id)?.fileName,
    imageDataUri: (id) {
      final path = repo.localPath(id);
      final a = repo.attachment(id);
      if (path == null || a == null) return null;
      try {
        return 'data:${a.mime};base64,${base64Encode(File(path).readAsBytesSync())}';
      } catch (_) {
        return null;
      }
    },
  );
}

Future<Uint8List> buildExport(NotesRepository repo, Note n, ExportFormat f) async {
  final ctx = exportContextFor(repo, n);
  switch (f) {
    case ExportFormat.txt:
      return Uint8List.fromList(utf8.encode(exportTxt(n, ctx)));
    case ExportFormat.md:
      return Uint8List.fromList(utf8.encode(exportMarkdown(n, ctx)));
    case ExportFormat.html:
      return Uint8List.fromList(utf8.encode(exportHtml(n, ctx)));
    case ExportFormat.pdf:
      return buildPdf(repo, [n]);
  }
}

/// Ouvre la boîte « Enregistrer sous » et écrit le fichier. Retourne le
/// chemin choisi, ou null si l'utilisateur a annulé.
Future<String?> saveBytes(String fileName, Uint8List bytes) async {
  final uri = await FilePicker.saveFile(
    dialogTitle: 'Enregistrer',
    fileName: fileName,
    bytes: bytes,
  );
  if (uri == null) return null;
  // Sur Windows, on s'assure que le fichier a bien été écrit.
  if (Platform.isWindows && (uri.scheme == 'file' || uri.scheme.isEmpty)) {
    final f = File(uri.scheme == 'file' ? uri.toFilePath() : uri.path);
    if (!await f.exists() || await f.length() != bytes.length) {
      await f.writeAsBytes(bytes, flush: true);
    }
    return f.path;
  }
  return uri.pathSegments.isNotEmpty ? Uri.decodeComponent(uri.pathSegments.last) : fileName;
}

// ------------------------------------------------------------------ PDF
Future<Uint8List> buildPdf(NotesRepository repo, List<Note> notes) async {
  Future<pw.Font> font(String name) async => pw.Font.ttf(await rootBundle.load('assets/fonts/$name'));
  final regular = await font('Inter-Regular.ttf');
  final bold = await font('Inter-SemiBold.ttf');
  final italic = await font('Inter-Italic.ttf');
  final boldItalic = await font('Inter-SemiBoldItalic.ttf');
  final mono = await font('JetBrainsMono-Regular.ttf');
  final dot = await font('Doto-Black.ttf');

  const red = PdfColor.fromInt(0xFFE60012);
  const mid = PdfColor.fromInt(0xFF858585);
  const line = PdfColor.fromInt(0xFFDADADA);

  final doc = pw.Document(
    title: notes.length == 1 ? notes.first.title : 'Nothing Notes',
    creator: 'Nothing Notes',
    theme: pw.ThemeData.withFont(base: regular, bold: bold, italic: italic, boldItalic: boldItalic),
  );

  pw.Widget rich(String text, {double size = 11, PdfColor? color, bool strike = false}) {
    final spans = <pw.InlineSpan>[];
    for (final t in parseInline(text)) {
      if (t.marker) continue;
      final decos = <pw.TextDecoration>[
        if (t.styles.contains(InlineStyle.underline) || t.link != null) pw.TextDecoration.underline,
        if (t.styles.contains(InlineStyle.strike) || strike) pw.TextDecoration.lineThrough,
      ];
      spans.add(pw.TextSpan(
        text: t.text,
        style: pw.TextStyle(
          fontWeight: t.styles.contains(InlineStyle.bold) ? pw.FontWeight.bold : pw.FontWeight.normal,
          fontStyle: t.styles.contains(InlineStyle.italic) ? pw.FontStyle.italic : pw.FontStyle.normal,
          font: t.styles.contains(InlineStyle.code) ? mono : null,
          decoration: decos.isEmpty ? null : pw.TextDecoration.combine(decos),
          color: t.link != null ? red : color,
        ),
      ));
    }
    if (spans.isEmpty && strike) {
      spans.add(pw.TextSpan(text: text, style: const pw.TextStyle(decoration: pw.TextDecoration.lineThrough)));
    }
    return pw.RichText(
      text: pw.TextSpan(style: pw.TextStyle(fontSize: size, color: color, lineSpacing: 2), children: spans),
    );
  }

  for (final n in notes) {
    final ctx = exportContextFor(repo, n);
    final widgets = <pw.Widget>[
      pw.Text(n.title.trim().isEmpty ? 'Sans titre' : n.title.trim(),
          style: pw.TextStyle(fontSize: 24, fontWeight: pw.FontWeight.bold)),
      pw.SizedBox(height: 4),
      pw.Text(
        [
          if (ctx.folderName != null) ctx.folderName!,
          ...ctx.tagNames,
          'modifiée le ${n.updatedAt.toLocal().toString().substring(0, 16)}',
        ].join('  ·  '),
        style: const pw.TextStyle(fontSize: 9, color: mid),
      ),
      pw.SizedBox(height: 16),
    ];
    var counter = 0;
    for (final b in n.blocks) {
      if (b.type != BlockType.numbered) counter = 0;
      switch (b.type) {
        case BlockType.heading1:
          widgets.add(pw.Padding(
              padding: const pw.EdgeInsets.only(top: 12, bottom: 4),
              child: rich(b.text, size: 17)));
          break;
        case BlockType.heading2:
          widgets.add(pw.Padding(
              padding: const pw.EdgeInsets.only(top: 8, bottom: 3),
              child: rich(b.text, size: 14)));
          break;
        case BlockType.quote:
          widgets.add(pw.Container(
            margin: const pw.EdgeInsets.symmetric(vertical: 4),
            padding: const pw.EdgeInsets.only(left: 10),
            decoration: const pw.BoxDecoration(border: pw.Border(left: pw.BorderSide(color: red, width: 2))),
            child: rich(b.text, color: mid),
          ));
          break;
        case BlockType.bullet:
        case BlockType.numbered:
          final mark = b.type == BlockType.bullet ? '•' : '${++counter}.';
          widgets.add(pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.SizedBox(width: 18, child: pw.Text(mark)),
            pw.Expanded(child: rich(b.text)),
          ]));
          break;
        case BlockType.todo:
          widgets.add(pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 2),
            child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Container(
                width: 10,
                height: 10,
                margin: const pw.EdgeInsets.only(top: 2, right: 8),
                decoration: pw.BoxDecoration(
                  color: b.checked ? red : null,
                  border: pw.Border.all(color: b.checked ? red : PdfColors.black, width: 1),
                  borderRadius: const pw.BorderRadius.all(pw.Radius.circular(2)),
                ),
              ),
              pw.Expanded(child: rich(b.text, color: b.checked ? mid : null, strike: b.checked)),
            ]),
          ));
          break;
        case BlockType.code:
          widgets.add(pw.Container(
            width: double.infinity,
            margin: const pw.EdgeInsets.symmetric(vertical: 6),
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(
                color: const PdfColor.fromInt(0xFFF3F3F3),
                border: pw.Border.all(color: line),
                borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6))),
            child: pw.Text(b.text, style: pw.TextStyle(font: mono, fontSize: 9.5)),
          ));
          break;
        case BlockType.divider:
          widgets.add(pw.Padding(
              padding: const pw.EdgeInsets.symmetric(vertical: 8),
              child: pw.Divider(color: mid, borderStyle: pw.BorderStyle.dotted)));
          break;
        case BlockType.image:
          final path = b.attachmentId == null ? null : repo.localPath(b.attachmentId!);
          pw.Widget w;
          try {
            if (path == null) throw StateError('absente');
            w = pw.Image(pw.MemoryImage(File(path).readAsBytesSync()), height: 260, fit: pw.BoxFit.contain);
          } catch (_) {
            w = pw.Text('[Image : ${ctx.attachmentName?.call(b.attachmentId ?? '') ?? 'non disponible'}]',
                style: const pw.TextStyle(color: mid));
          }
          widgets.add(pw.Padding(padding: const pw.EdgeInsets.symmetric(vertical: 6), child: w));
          break;
        case BlockType.file:
          widgets.add(pw.Text('Pièce jointe : ${ctx.attachmentName?.call(b.attachmentId ?? '') ?? 'fichier'}',
              style: const pw.TextStyle(color: mid)));
          break;
        case BlockType.table:
          final rows = b.rows ?? const <List<String>>[];
          if (rows.isNotEmpty) {
            widgets.add(pw.Padding(
              padding: const pw.EdgeInsets.symmetric(vertical: 6),
              child: pw.TableHelper.fromTextArray(
                data: rows,
                headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10),
                cellStyle: const pw.TextStyle(fontSize: 10),
                border: pw.TableBorder.all(color: line),
                headerDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFF3F3F3)),
                cellAlignment: pw.Alignment.centerLeft,
              ),
            ));
          }
          break;
        default:
          if (b.text.trim().isEmpty) {
            widgets.add(pw.SizedBox(height: 8));
          } else {
            widgets.add(pw.Padding(padding: const pw.EdgeInsets.symmetric(vertical: 2), child: rich(b.text)));
          }
      }
    }
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(48, 44, 48, 44),
      header: (c) => pw.Container(
        alignment: pw.Alignment.centerRight,
        margin: const pw.EdgeInsets.only(bottom: 12),
        child: pw.Text('NOTHING NOTES', style: pw.TextStyle(font: dot, fontSize: 8, color: mid, letterSpacing: 1)),
      ),
      footer: (c) => pw.Container(
        alignment: pw.Alignment.centerRight,
        child: pw.Text('${c.pageNumber} / ${c.pagesCount}', style: const pw.TextStyle(fontSize: 8, color: mid)),
      ),
      build: (c) => widgets,
    ));
  }
  return doc.save();
}
