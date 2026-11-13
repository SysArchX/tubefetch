package com.sysarchx.fastsearchx

import android.content.Intent
import android.net.Uri
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "fastsearchx/intent"
    private var channel: MethodChannel? = null
    private var pendingUrl: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelName,
        ).also { methodChannel ->
            methodChannel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInitialUrl" -> {
                        val url = pendingUrl ?: extractUrl(intent)
                        pendingUrl = null
                        result.success(url)
                    }
                    "openDefaultBrowserSettings" -> {
                        result.success(openDefaultBrowserSettings())
                    }
                    else -> result.notImplemented()
                }
            }
        }

        pendingUrl = extractUrl(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)

        val url = extractUrl(intent) ?: return
        val methodChannel = channel
        if (methodChannel == null) {
            pendingUrl = url
        } else {
            methodChannel.invokeMethod("openUrl", url)
        }
    }

    private fun extractUrl(intent: Intent?): String? {
        if (intent == null || intent.action != Intent.ACTION_VIEW) return null
        val data = intent.data ?: return null
        val scheme = data.scheme?.lowercase()
        if (scheme != "http" && scheme != "https") return null
        return data.toString()
    }

    private fun openDefaultBrowserSettings(): Boolean {
        val intents = listOf(
            Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS),
            Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:$packageName"),
            ),
        )
        for (intent in intents) {
            try {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent)
                return true
            } catch (_: Exception) {
                // Tenta a próxima opção.
            }
        }
        return false
    }
}
