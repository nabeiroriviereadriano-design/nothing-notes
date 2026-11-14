import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../state/app_controller.dart';
import '../theme.dart';
import '../widgets/common.dart';

enum _Mode { signIn, signUp, confirm, forgot, reset }

String authErrorFr(Object e) {
  final raw = e is AuthException ? e.message : e.toString();
  final m = raw.toLowerCase();
  if (m.contains('invalid login')) return 'E-mail ou mot de passe incorrect.';
  if (m.contains('not confirmed')) return 'Adresse e-mail pas encore confirmée.';
  if (m.contains('already registered') || m.contains('already been registered')) {
    return 'Un compte existe déjà avec cet e-mail.';
  }
  if (m.contains('password') && (m.contains('at least') || m.contains('short') || m.contains('weak'))) {
    return 'Mot de passe trop faible (8 caractères minimum conseillés).';
  }
  if (m.contains('expired') || m.contains('invalid') && m.contains('otp') || m.contains('token')) {
    return 'Code invalide ou expiré.';
  }
  if (m.contains('rate limit') || m.contains('too many')) return 'Trop de tentatives, réessayez dans quelques minutes.';
  if (m.contains('socket') || m.contains('failed host lookup') || m.contains('network') || m.contains('clientexception')) {
    return 'Connexion au serveur impossible. Vérifiez votre accès à Internet.';
  }
  return raw;
}

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  _Mode _mode = _Mode.signIn;
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _password2 = TextEditingController();
  final _code = TextEditingController();
  bool _busy = false;
  bool _hide = true;
  String? _error;
  String? _info;

  @override
  void dispose() {
    for (final c in [_email, _password, _password2, _code]) {
      c.dispose();
    }
    super.dispose();
  }

  void _go(_Mode m) => setState(() {
        _mode = m;
        _error = null;
        _info = null;
      });

  Future<void> _submit() async {
    final app = AppScope.read(context);
    final email = _email.text.trim();
    setState(() {
      _error = null;
      _busy = true;
    });
    try {
      switch (_mode) {
        case _Mode.signIn:
          await app.account.signIn(email, _password.text);
        case _Mode.signUp:
          if (_password.text.length < 8) throw const AuthException('Password should be at least 8 characters');
          if (_password.text != _password2.text) {
            setState(() => _error = 'Les deux mots de passe ne correspondent pas.');
            return;
          }
          final r = await app.account.signUp(email, _password.text);
          if (r.session == null) {
            _go(_Mode.confirm);
            _info = 'Un e-mail de confirmation vient d\'être envoyé à $email. '
                'Saisissez le code reçu, ou cliquez sur le lien de l\'e-mail puis connectez-vous.';
          }
        case _Mode.confirm:
          await app.account.confirmSignUp(email, _code.text);
        case _Mode.forgot:
          await app.account.sendPasswordReset(email);
          _go(_Mode.reset);
          _info = 'Si un compte existe pour $email, un code de réinitialisation vient d\'être envoyé.';
        case _Mode.reset:
          if (_password.text.length < 8) throw const AuthException('Password should be at least 8 characters');
          await app.account.resetPassword(email, _code.text, _password.text);
          if (mounted) toast(context, 'Mot de passe modifié');
      }
    } catch (e) {
      if (mounted) setState(() => _error = authErrorFr(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final nn = context.nn;
    final app = AppScope.of(context);
    final title = switch (_mode) {
      _Mode.signIn => 'Connexion',
      _Mode.signUp => 'Créer un compte',
      _Mode.confirm => 'Confirmer l\'e-mail',
      _Mode.forgot => 'Mot de passe oublié',
      _Mode.reset => 'Nouveau mot de passe',
    };
    final action = switch (_mode) {
      _Mode.signIn => 'Se connecter',
      _Mode.signUp => 'Créer le compte',
      _Mode.confirm => 'Confirmer',
      _Mode.forgot => 'Envoyer le code',
      _Mode.reset => 'Changer le mot de passe',
    };
    final needsPassword = _mode == _Mode.signIn || _mode == _Mode.signUp || _mode == _Mode.reset;

    return Scaffold(
      body: Stack(children: [
        const Positioned.fill(child: DotPattern()),
        SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: AutofillGroup(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Row(children: [
                      const NothingLogo(size: 64),
                      const SizedBox(width: 18),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          const DotTitle('Nothing', size: 30),
                          const SizedBox(height: 4),
                          const DotTitle('Notes', size: 30),
                        ]),
                      ),
                    ]),
                    const SizedBox(height: 10),
                    Text('Prise de notes · Organisation · Synchronisation', style: TextStyle(color: nn.mid, fontSize: 13)),
                    const SizedBox(height: 36),
                    Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 18),
                    if (_info != null) ...[
                      Text(_info!, style: TextStyle(color: nn.mid, fontSize: 13.5, height: 1.4)),
                      const SizedBox(height: 14),
                    ],
                    TextField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(hintText: 'Adresse e-mail', prefixIcon: Icon(Icons.alternate_email_rounded, size: 19)),
                    ),
                    if (_mode == _Mode.confirm || _mode == _Mode.reset) ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: _code,
                        keyboardType: TextInputType.number,
                        autofillHints: const [AutofillHints.oneTimeCode],
                        decoration: const InputDecoration(hintText: 'Code reçu par e-mail', prefixIcon: Icon(Icons.pin_outlined, size: 19)),
                      ),
                    ],
                    if (needsPassword) ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: _password,
                        obscureText: _hide,
                        autofillHints: [_mode == _Mode.signIn ? AutofillHints.password : AutofillHints.newPassword],
                        onSubmitted: (_) => _mode == _Mode.signIn ? _submit() : null,
                        decoration: InputDecoration(
                          hintText: _mode == _Mode.reset ? 'Nouveau mot de passe' : 'Mot de passe',
                          prefixIcon: const Icon(Icons.lock_outline_rounded, size: 19),
                          suffixIcon: IconButton(
                            onPressed: () => setState(() => _hide = !_hide),
                            icon: Icon(_hide ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 19),
                          ),
                        ),
                      ),
                    ],
                    if (_mode == _Mode.signUp) ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: _password2,
                        obscureText: _hide,
                        onSubmitted: (_) => _submit(),
                        decoration: const InputDecoration(hintText: 'Confirmer le mot de passe', prefixIcon: Icon(Icons.lock_outline_rounded, size: 19)),
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 14),
                      Row(children: [
                        const RedDot(),
                        const SizedBox(width: 10),
                        Expanded(child: Text(_error!, style: const TextStyle(color: NColors.red, fontSize: 13.5))),
                      ]),
                    ],
                    const SizedBox(height: 22),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: nn.invertedFg))
                          : Text(action),
                    ),
                    const SizedBox(height: 14),
                    if (_mode == _Mode.signIn) ...[
                      OutlinedButton(onPressed: () => _go(_Mode.signUp), child: const Text('Créer un compte')),
                      TextButton(onPressed: () => _go(_Mode.forgot), child: const Text('Mot de passe oublié ?')),
                    ] else
                      TextButton(onPressed: () => _go(_Mode.signIn), child: const Text('Retour à la connexion')),
                    if (_mode == _Mode.forgot)
                      TextButton(onPressed: () => _go(_Mode.reset), child: const Text('J\'ai déjà un code')),
                    const SizedBox(height: 24),
                    Center(
                      child: TextButton.icon(
                        onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                          builder: (_) => const ServerSetupScreen(canCancel: true),
                        )),
                        icon: Icon(Icons.dns_outlined, size: 16, color: nn.mid),
                        label: Text(
                          'Serveur : ${Uri.tryParse(app.serverUrl)?.host ?? app.serverUrl}',
                          style: TextStyle(color: nn.mid, fontSize: 12),
                        ),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

/// Configuration du serveur Supabase (adresse + clé publique « anon »).
class ServerSetupScreen extends StatefulWidget {
  const ServerSetupScreen({super.key, this.canCancel = false});
  final bool canCancel;
  @override
  State<ServerSetupScreen> createState() => _ServerSetupScreenState();
}

class _ServerSetupScreenState extends State<ServerSetupScreen> {
  late final TextEditingController _url;
  late final TextEditingController _key;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final app = AppScope.read(context);
    _url = TextEditingController(text: app.serverUrl);
    _key = TextEditingController(text: app.anonKey);
  }

  Future<void> _save() async {
    final url = _url.text.trim();
    final key = _key.text.trim();
    if (!url.startsWith('https://') && !url.startsWith('http://')) {
      setState(() => _error = 'L\'adresse doit commencer par https://');
      return;
    }
    if (key.length < 20) {
      setState(() => _error = 'Clé publique invalide.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AppScope.read(context).configureServer(url, key);
      if (mounted && widget.canCancel) Navigator.of(context).pop();
    } catch (e) {
      setState(() => _error = 'Configuration refusée : $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final nn = context.nn;
    final app = AppScope.of(context);
    return Scaffold(
      appBar: widget.canCancel ? AppBar(title: const Text('Serveur de synchronisation')) : null,
      body: Stack(children: [
        const Positioned.fill(child: DotPattern()),
        SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  if (!widget.canCancel) ...[
                    const Row(children: [NothingLogo(size: 56), SizedBox(width: 16), DotTitle('Notes', size: 34)]),
                    const SizedBox(height: 32),
                  ],
                  const Text('Serveur de synchronisation', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 10),
                  Text(
                    'Nothing Notes synchronise vos notes via votre propre projet Supabase (offre gratuite). '
                    'Dans Supabase : Project Settings › API, copiez l\'URL du projet et la clé publique « anon ». '
                    'Ne saisissez jamais la clé « service_role ».',
                    style: TextStyle(color: nn.mid, fontSize: 13.5, height: 1.45),
                  ),
                  const SizedBox(height: 22),
                  TextField(
                    controller: _url,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(hintText: 'https://xxxx.supabase.co', prefixIcon: Icon(Icons.link_rounded, size: 19)),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _key,
                    maxLines: 1,
                    decoration: const InputDecoration(hintText: 'Clé publique (anon / publishable)', prefixIcon: Icon(Icons.key_rounded, size: 19)),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, style: const TextStyle(color: NColors.red)),
                  ],
                  const SizedBox(height: 22),
                  FilledButton(onPressed: _busy ? null : _save, child: Text(_busy ? 'Connexion…' : 'Enregistrer')),
                  if (app.serverFromBuild) ...[
                    const SizedBox(height: 10),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () async {
                              await app.resetServerToBuild();
                              if (context.mounted && widget.canCancel) Navigator.of(context).pop();
                            },
                      child: const Text('Revenir au serveur par défaut'),
                    ),
                  ],
                ]),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}
