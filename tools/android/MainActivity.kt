package PACKAGE_NAME

import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Nothing Notes : reçoit le texte ou le fichier Markdown partagé depuis une
 * autre application (« Partager → Nothing Notes ») et permet de partager une
 * note vers une autre application. Aucune donnée n'est envoyée ailleurs que
 * vers l'application choisie par l'utilisateur.
 */
class MainActivity : FlutterActivity() {
    private var pending: Map<String, String?>? = null
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "nothing_notes/share")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "takeShared" -> {
                    result.success(pending)
                    pending = null
                }
                "shareText" -> {
                    val send = Intent(Intent.ACTION_SEND).apply {
                        type = "text/plain"
                        putExtra(Intent.EXTRA_TEXT, call.argument<String>("text") ?: "")
                        putExtra(Intent.EXTRA_SUBJECT, call.argument<String>("subject") ?: "")
                    }
                    startActivity(Intent.createChooser(send, call.argument<String>("subject") ?: "Partager"))
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        handle(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
        if (pending != null) channel?.invokeMethod("shared", null)
    }

    private fun handle(intent: Intent?) {
        if (intent == null || intent.action != Intent.ACTION_SEND) return
        var text: String? = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
        var subject: String? = intent.getStringExtra(Intent.EXTRA_SUBJECT)
        @Suppress("DEPRECATION")
        val uri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
        if (text == null && uri != null) {
            try {
                contentResolver.openInputStream(uri)?.use { input ->
                    val bytes = input.readBytes()
                    if (bytes.size <= 5 * 1024 * 1024) text = String(bytes, Charsets.UTF_8)
                }
                contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                    if (c.moveToFirst()) subject = c.getString(0)
                }
            } catch (_: Exception) {
            }
        }
        if (text != null) pending = mapOf("text" to text, "subject" to subject, "file" to if (uri != null) "1" else null)
        // Évite de réimporter le même partage si l'activité est recréée (rotation).
        intent.action = Intent.ACTION_MAIN
    }
}
