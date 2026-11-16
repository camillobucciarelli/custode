package dev.camillobucciarelli.kdbxKeyVault

import android.content.Intent
import android.os.Build
import dev.camillobucciarelli.kdbxKeyVault.autofill.AndroidAutofillV2Channel
import dev.camillobucciarelli.kdbxKeyVault.autofill.EXTRA_CAPTURE_TOKEN
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private var channelHandler: AndroidAutofillV2Channel? = null
    private var methodChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val handler = AndroidAutofillV2Channel(applicationContext)
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            AndroidAutofillV2Channel.CHANNEL_NAME,
        )
        channel.setMethodCallHandler(handler::handle)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "dev.camillobucciarelli.kdbxKeyVault/install_source",
        ).setMethodCallHandler { call, result ->
            if (call.method == "installerPackage") result.success(installerPackage())
            else result.notImplemented()
        }
        channelHandler = handler
        methodChannel = channel
        // A cold start reaches Dart only after the engine is up, so the token
        // waits here until Dart pulls it with `takePendingCaptureToken`.
        handler.setPendingCaptureToken(intent?.captureToken())
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val token = intent.captureToken() ?: return
        channelHandler?.setPendingCaptureToken(token)
        methodChannel?.invokeMethod("receivePendingCapture", token)
    }

    @Suppress("DEPRECATION")
    private fun installerPackage(): String? = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            packageManager.getInstallSourceInfo(packageName).installingPackageName
        } else {
            packageManager.getInstallerPackageName(packageName)
        }
    } catch (e: Exception) {
        null
    }

    private fun Intent.captureToken(): String? =
        getStringExtra(EXTRA_CAPTURE_TOKEN)?.trim()?.takeIf { it.isNotEmpty() }
}
