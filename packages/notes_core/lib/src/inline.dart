/// Mise en forme en ligne, stockée sous forme de balises légères dans le
/// texte des blocs :
///   **gras**   *italique*   ++souligné++   ~~barré~~   `code`   [texte](https://lien)
///
/// Le texte reste lisible tel quel (export TXT/Markdown) et la mise en forme
/// voyage avec la note entre Android et Windows sans format propriétaire.
enum InlineStyle { bold, italic, underline, strike, code }

class InlineToken {
  InlineToken(this.text, {this.marker = false, Set<InlineStyle>? styles, this.link})
      : styles = styles ?? const {};

  final String text;

  /// Vrai pour les caractères de balisage (**, ++, [ ...) : affichés en
  /// discret dans l'éditeur, masqués en lecture et à l'export.
  final bool marker;
  final Set<InlineStyle> styles;
  final String? link;

  @override
  String toString() => '${marker ? 'M' : 'T'}("$text" $styles${link != null ? ' $link' : ''})';
}

final _linkAt = RegExp(r'\[([^\]\n]+)\]\(([^)\s]+)\)');

const _pairs = <String, InlineStyle>{
  '**': InlineStyle.bold,
  '++': InlineStyle.underline,
  '~~': InlineStyle.strike,
};

/// Découpe [s] en jetons. La concaténation des `text` de tous les jetons
/// (marqueurs compris) redonne exactement [s].
List<InlineToken> parseInline(String s, {Set<InlineStyle> inherited = const {}, String? link}) {
  final out = <InlineToken>[];
  final plain = StringBuffer();
  void flush() {
    if (plain.isNotEmpty) {
      out.add(InlineToken(plain.toString(), styles: inherited, link: link));
      plain.clear();
    }
  }

  var i = 0;
  while (i < s.length) {
    // code en ligne : pas d'imbrication à l'intérieur
    if (s[i] == '`') {
      final end = s.indexOf('`', i + 1);
      if (end > i + 1) {
        flush();
        final st = {...inherited, InlineStyle.code};
        out.add(InlineToken('`', marker: true, styles: st, link: link));
        out.add(InlineToken(s.substring(i + 1, end), styles: st, link: link));
        out.add(InlineToken('`', marker: true, styles: st, link: link));
        i = end + 1;
        continue;
      }
    }
    // lien
    if (s[i] == '[' && link == null) {
      final m = _linkAt.matchAsPrefix(s, i);
      if (m != null) {
        flush();
        final url = m.group(2)!;
        out.add(InlineToken('[', marker: true, styles: inherited, link: url));
        out.addAll(parseInline(m.group(1)!, inherited: inherited, link: url));
        out.add(InlineToken('](${m.group(2)})', marker: true, styles: inherited, link: url));
        i = m.end;
        continue;
      }
    }
    // paires de deux caractères
    var matched = false;
    if (i + 1 < s.length) {
      final two = s.substring(i, i + 2);
      final style = _pairs[two];
      if (style != null) {
        var end = s.indexOf(two, i + 2);
        // « ***» en fin de zone : le premier caractère ferme un marquage imbriqué
        while (end >= 0 && end + 2 < s.length && s[end + 2] == two[0]) {
          end++;
        }
        if (end > i + 2) {
          flush();
          final st = {...inherited, style};
          out.add(InlineToken(two, marker: true, styles: st, link: link));
          out.addAll(parseInline(s.substring(i + 2, end), inherited: st, link: link));
          out.add(InlineToken(two, marker: true, styles: st, link: link));
          i = end + 2;
          matched = true;
        }
      }
    }
    if (matched) continue;
    // italique *texte* (un seul astérisque, non collé à un espace)
    if (s[i] == '*' && (i + 1 < s.length && s[i + 1] != '*' && s[i + 1] != ' ')) {
      var end = -1;
      for (var j = i + 1; j < s.length; j++) {
        if (s[j] == '*' && s[j - 1] != ' ' && (j + 1 >= s.length || s[j + 1] != '*') && s[j - 1] != '*') {
          end = j;
          break;
        }
      }
      if (end > i + 1) {
        flush();
        final st = {...inherited, InlineStyle.italic};
        out.add(InlineToken('*', marker: true, styles: st, link: link));
        out.addAll(parseInline(s.substring(i + 1, end), inherited: st, link: link));
        out.add(InlineToken('*', marker: true, styles: st, link: link));
        i = end + 1;
        continue;
      }
    }
    plain.write(s[i]);
    i++;
  }
  flush();
  return out;
}

/// Entoure la sélection [start, end) de [marker] ou retire le marquage s'il
/// est déjà présent. Retourne le nouveau texte et la nouvelle sélection.
({String text, int start, int end}) toggleWrap(String text, int start, int end, String marker) {
  if (start < 0 || end < 0) return (text: text, start: start, end: end);
  if (start > end) {
    final t = start;
    start = end;
    end = t;
  }
  final m = marker.length;
  // Marquage déjà autour de la sélection : on l'enlève.
  if (start >= m &&
      end + m <= text.length &&
      text.substring(start - m, start) == marker &&
      text.substring(end, end + m) == marker) {
    final t = text.substring(0, start - m) + text.substring(start, end) + text.substring(end + m);
    return (text: t, start: start - m, end: end - m);
  }
  // La sélection inclut les marqueurs.
  final sel = text.substring(start, end);
  if (sel.length >= 2 * m && sel.startsWith(marker) && sel.endsWith(marker)) {
    final inner = sel.substring(m, sel.length - m);
    final t = text.substring(0, start) + inner + text.substring(end);
    return (text: t, start: start, end: start + inner.length);
  }
  final t = text.substring(0, start) + marker + sel + marker + text.substring(end);
  return (text: t, start: start + m, end: end + m);
}
