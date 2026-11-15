import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/home_shell.dart';
import 'state/app_controller.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final app = AppController();
  runApp(NothingNotesApp(controller: app));
  await app.init();
}

class NothingNotesApp extends StatelessWidget {
  const NothingNotesApp({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      controller: controller,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => MaterialApp(
          title: 'Nothing Notes',
          debugShowCheckedModeBanner: false,
          themeMode: controller.themeMode,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          builder: (context, child) {
            final dark = Theme.of(context).brightness == Brightness.dark;
            SystemChrome.setSystemUIOverlayStyle(dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark);
            return child!;
          },
          home: const _Root(),
        ),
      ),
    );
  }
}

class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    Widget page;
    if (!app.ready) {
      page = const _Splash(key: ValueKey('splash'));
    } else if (app.fatalError != null) {
      page = _Fatal(key: const ValueKey('fatal'), message: app.fatalError!);
    } else {
      page = const HomeShell(key: ValueKey('home'));
    }
    return AnimatedSwitcher(duration: const Duration(milliseconds: 250), child: page);
  }
}

class _Splash extends StatelessWidget {
  const _Splash({super.key});
  @override
  Widget build(BuildContext context) => const Scaffold(
        body: Stack(children: [
          Positioned.fill(child: DotPattern()),
          Center(child: NothingLogo(size: 84)),
        ]),
      );
}

class _Fatal extends StatelessWidget {
  const _Fatal({super.key, required this.message});
  final String message;
  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const NothingLogo(size: 56),
              const SizedBox(height: 20),
              const Text('Démarrage impossible', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              SelectableText(message, textAlign: TextAlign.center, style: TextStyle(color: context.nn.mid)),
            ]),
          ),
        ),
      );
}
