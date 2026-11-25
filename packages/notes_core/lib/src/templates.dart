import 'models.dart';
import 'repository.dart';

/// Modèle de page : intégré (défini ici) ou personnalisé (page de sorte
/// [PageKind.template], synchronisée entre les appareils).
class PageTemplate {
  PageTemplate({
    required this.id,
    required this.name,
    this.icon,
    this.description = '',
    this.title = '',
    required this.blocks,
    this.builtIn = false,
    this.forDatabase,
  });

  final String id;
  final String name;
  final String? icon;
  final String description;

  /// Titre proposé pour la nouvelle page (peut contenir {date}).
  final String title;
  final List<Block> Function() blocks;
  final bool builtIn;

  /// Modèle d'entrée pour cette base de données.
  final String? forDatabase;
}

String _today() {
  final d = DateTime.now();
  const months = ['janvier', 'février', 'mars', 'avril', 'mai', 'juin', 'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre'];
  return '${d.day} ${months[d.month - 1]} ${d.year}';
}

Block _h(String t, [String type = BlockType.heading2]) => Block(type: type, text: t);
Block _p([String t = '']) => Block(text: t);
Block _todo(String t) => Block(type: BlockType.todo, text: t);
Block _bullet(String t) => Block(type: BlockType.bullet, text: t);

/// Modèles intégrés.
final List<PageTemplate> builtInTemplates = [
  PageTemplate(
    id: 'builtin:quick',
    name: 'Note rapide',
    icon: '⚡',
    description: 'Une page vierge, prête à écrire.',
    builtIn: true,
    blocks: () => [_p()],
  ),
  PageTemplate(
    id: 'builtin:course',
    name: 'Cours',
    icon: '📘',
    description: 'Matière, notions clés, exemples, à retenir.',
    title: 'Cours — ',
    builtIn: true,
    blocks: () => [
      Block(type: BlockType.quote, text: 'Matière : · Chapitre : · Date : ${_today()}'),
      _h('Objectifs'),
      _bullet(''),
      _h('Notions clés'),
      _p(),
      _h('Exemples'),
      _p(),
      _h('À retenir'),
      Block(type: BlockType.toggle, text: 'Résumé', extra: {'body': ''}),
    ],
  ),
  PageTemplate(
    id: 'builtin:meeting',
    name: 'Réunion',
    icon: '🗓',
    description: 'Participants, ordre du jour, décisions, actions.',
    title: 'Réunion du {date}',
    builtIn: true,
    blocks: () => [
      _h('Participants'),
      _bullet(''),
      _h('Ordre du jour'),
      Block(type: BlockType.numbered, text: ''),
      _h('Décisions'),
      _bullet(''),
      _h('Actions'),
      _todo(''),
    ],
  ),
  PageTemplate(
    id: 'builtin:project',
    name: 'Projet',
    icon: '🎯',
    description: 'Objectif, étapes, tâches, ressources.',
    builtIn: true,
    blocks: () => [
      _h('Objectif'),
      _p(),
      _h('Étapes'),
      Block(type: BlockType.numbered, text: ''),
      _h('Tâches'),
      _todo(''),
      _h('Ressources'),
      _bullet(''),
      _h('Notes'),
      _p(),
    ],
  ),
  PageTemplate(
    id: 'builtin:todo',
    name: 'Liste de tâches',
    icon: '✅',
    description: 'Des cases à cocher, à suivre dans la vue Tâches.',
    title: 'Tâches',
    builtIn: true,
    blocks: () => [_todo(''), _todo(''), _todo('')],
  ),
  PageTemplate(
    id: 'builtin:journal',
    name: 'Journal',
    icon: '📓',
    description: 'Une page par jour : faits, réflexions, demain.',
    title: '{date}',
    builtIn: true,
    blocks: () => [
      _h('Aujourd\'hui'),
      _p(),
      _h('Ce que j\'ai appris'),
      _p(),
      _h('Demain'),
      _todo(''),
    ],
  ),
  PageTemplate(
    id: 'builtin:revision',
    name: 'Fiche de révision',
    icon: '🧠',
    description: 'Définitions, formules, méthode, questions types.',
    title: 'Fiche — ',
    builtIn: true,
    blocks: () => [
      _h('Définitions'),
      _bullet(''),
      _h('Formules'),
      Block(type: BlockType.code, text: ''),
      _h('Méthode'),
      Block(type: BlockType.numbered, text: ''),
      _h('Questions types'),
      Block(type: BlockType.toggle, text: 'Question', extra: {'body': 'Réponse'}),
      _h('Pièges à éviter'),
      _bullet(''),
    ],
  ),
];

/// Les pages ne contenant qu'un paragraphe vide sont considérées vides.
bool isEmptyContent(List<Block> blocks) =>
    blocks.isEmpty || (blocks.length == 1 && blocks.first.type == BlockType.paragraph && blocks.first.text.trim().isEmpty);

extension TemplatesX on NotesRepository {
  /// Modèles personnalisés (pages de sorte « modèle »).
  List<Note> customTemplateNotes({String? forDatabase}) => allNotes()
      .where((n) => n.isTemplate && !n.trashed && n.templateFor == forDatabase)
      .toList()
    ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));

  /// Tous les modèles disponibles : intégrés puis personnalisés.
  List<PageTemplate> templates({String? forDatabase}) => [
        if (forDatabase == null) ...builtInTemplates,
        for (final n in customTemplateNotes(forDatabase: forDatabase))
          PageTemplate(
            id: n.id,
            name: n.title.isEmpty ? 'Modèle sans nom' : n.title,
            icon: n.icon,
            description: n.preview,
            title: (n.props['template_title'] ?? '').toString(),
            blocks: () => n.blocks.map((b) => b.cloneFresh()).toList(),
            forDatabase: n.templateFor,
          ),
      ];

  PageTemplate? templateById(String id) {
    for (final t in builtInTemplates) {
      if (t.id == id) return t;
    }
    final n = note(id);
    if (n == null || !n.isTemplate) return null;
    return templates(forDatabase: n.templateFor).where((t) => t.id == id).firstOrNull;
  }

  String _titleFrom(PageTemplate t) => t.title.replaceAll('{date}', _today());

  /// Nouvelle page à partir d'un modèle.
  Note createFromTemplate(PageTemplate t, {String? parentId, String? folderId, Map<String, dynamic>? props}) {
    final parent = parentId == null ? null : note(parentId);
    return createNote(
      title: _titleFrom(t),
      blocks: t.blocks(),
      parentId: parentId,
      folderId: folderId ?? parent?.folderId,
      icon: t.icon != null && !t.builtIn ? t.icon : null,
      props: props,
    );
  }

  /// Applique un modèle à une page existante SANS rien écraser : si la page
  /// est vide, le contenu du modèle la remplit ; sinon il est ajouté à la fin.
  /// Le titre n'est rempli que s'il est vide.
  void applyTemplate(String noteId, PageTemplate t) {
    final n = note(noteId);
    if (n == null) return;
    final added = t.blocks();
    if (isEmptyContent(n.blocks)) {
      n.blocks = added;
    } else {
      n.blocks = [...n.blocks, Block(type: BlockType.divider), ...added];
    }
    if (n.title.trim().isEmpty) n.title = _titleFrom(t);
    saveNote(n);
  }

  /// Enregistre une copie de la page comme modèle personnalisé.
  Note saveAsTemplate(String noteId, {String? name}) {
    final src = note(noteId)!;
    return createNote(
      title: (name ?? src.title).trim().isEmpty ? 'Mon modèle' : (name ?? src.title).trim(),
      blocks: src.blocks.map((b) => b.cloneFresh()).toList(),
      kind: PageKind.template,
      icon: src.icon,
      templateFor: src.parentId != null && (note(src.parentId!)?.isDatabase ?? false) ? src.parentId : null,
    );
  }
}
