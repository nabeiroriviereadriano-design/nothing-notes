import 'dart:io';

import 'package:flutter/services.dart';

/// Partage Android (canal natif, sans bibliothèque tierce) :
///  * entrant : « Partager → Nothing Notes » depuis une autre application ;
///  * sortant : envoyer le texte d'une note vers l'application choisie.
class ShareBridge {
  static const _ch = MethodChannel('nothing_notes/share');

  static bool get supported => Platform.isAndroid;

  /// Appelle [onShared] pour le partage reçu au démarrage puis pour chaque
  /// partage reçu pendant que l'application est ouverte.
  static Future<void> listen(void Function(String text, String? subject, bool fromFile) onShared) async {
    if (!supported) return;
    Future<void> take() async {
      try {
        final m = await _ch.invokeMapMethod<String, dynamic>('takeShared');
        final text = m?['text'] as String?;
        if (text != null && text.trim().isNotEmpty) onShared(text, m?['subject'] as String?, m?['file'] != null);
      } on PlatformException {
        // rien à importer
      } on MissingPluginException {
        // pas d'activité native (tests)
      }
    }

    _ch.setMethodCallHandler((call) async {
      if (call.method == 'shared') await take();
    });
    await take();
  }

  static Future<bool> shareText(String text, {String subject = ''}) async {
    if (!supported) return false;
    try {
      return await _ch.invokeMethod<bool>('shareText', {'text': text, 'subject': subject}) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
