package dev.camillobucciarelli.kdbxKeyVault

import android.content.Intent
import dev.camillobucciarelli.kdbxKeyVault.autofill.AndroidAutofillV2Channel
import dev.camillobucciarelli.kdbxKeyVault.autofill.EXTRA_CAPTURE_TOKEN
import dev.camillobucciarelli.kdbxKeyVault.autofill.PasskeyRegistrationBridge
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
        channelHandler = handler
        methodChannel = channel
        // spec 023 T805: PasskeyCreateActivity asks the app to write a new
        // passkey over this same channel, so it must be reachable from outside
        // this activity for as long as the engine lives.
        PasskeyRegistrationBridge.attach(channel)
        // A cold start reaches Dart only after the engine is up, so the token
        // waits here until Dart pulls it with `takePendingCaptureToken`.
        handler.setPendingCaptureToken(intent?.captureToken())
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        releasePasskeyRegistrationBridge()
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        // Belt and braces with cleanUpFlutterEngine: a channel whose engine is
        // gone must not be left looking like a running app.
        releasePasskeyRegistrationBridge()
        super.onDestroy()
    }

    private fun releasePasskeyRegistrationBridge() {
        PasskeyRegistrationBridge.detach(methodChannel)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val token = intent.captureToken() ?: return
        channelHandler?.setPendingCaptureToken(token)
        methodChannel?.invokeMethod("receivePendingCapture", token)
    }

    private fun Intent.captureToken(): String? =
        getStringExtra(EXTRA_CAPTURE_TOKEN)?.trim()?.takeIf { it.isNotEmpty() }
}
