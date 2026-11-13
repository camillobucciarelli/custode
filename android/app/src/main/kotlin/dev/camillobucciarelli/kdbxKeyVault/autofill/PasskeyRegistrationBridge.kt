package dev.camillobucciarelli.kdbxKeyVault.autofill

import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.MethodChannel

/**
 * spec 023 T805 — the way from a native activity to the running Flutter app.
 *
 * Only the app can write the vault, and the method channel belongs to the
 * engine `MainActivity` owns. This holder keeps that channel reachable for
 * the process: set when the engine is configured, cleared when it goes away.
 * With no live channel there is no app to ask, which is reported as
 * `noVault`.
 *
 * Main thread only, as `MethodChannel.invokeMethod` requires. Arguments and
 * answers are never logged: they carry the user handle and public key bytes.
 */
internal object PasskeyRegistrationBridge {
    const val STATUS_READY = "ready"
    const val STATUS_NO_VAULT = "noVault"

    /** The vault already holds a credential the site listed in `excludeCredentials`. */
    const val STATUS_EXCLUDED = "excluded"
    const val STATUS_FAILED = "failed"

    private const val TAG = "CustodePasskey"
    private const val PREPARE_METHOD = "preparePasskeyRegistration"
    private const val COMMIT_METHOD = "commitPasskeyRegistration"

    /** `prepare` only reads; an app that has not answered by now is not there. */
    private const val PREPARE_TIMEOUT_MS = 10_000L

    /** `commit` backs up and rewrites the vault, which can be slow on a large file. */
    private const val COMMIT_TIMEOUT_MS = 60_000L

    private var channel: MethodChannel? = null
    private val mainHandler by lazy { Handler(Looper.getMainLooper()) }

    class Prepared(val status: String, val replaces: Boolean)

    fun attach(channel: MethodChannel) {
        this.channel = channel
    }

    /** Clears the holder only if it still holds [channel]: a newer engine keeps its own. */
    fun detach(channel: MethodChannel?) {
        if (channel != null && this.channel === channel) {
            this.channel = null
        }
    }

    fun prepare(
        rpId: String,
        userHandle: String?,
        excludeCredentialIds: List<String>,
        onResult: (Prepared) -> Unit,
    ) {
        invoke(
            method = PREPARE_METHOD,
            arguments = mapOf(
                "rpId" to rpId,
                "userHandle" to userHandle,
                "excludeCredentialIds" to excludeCredentialIds,
            ),
            timeoutMs = PREPARE_TIMEOUT_MS,
        ) { answer ->
            val status = answer?.get("status") as? String ?: STATUS_NO_VAULT
            onResult(
                Prepared(
                    status = status,
                    replaces = status == STATUS_READY && answer?.get("replaces") == true,
                ),
            )
        }
    }

    /**
     * Hands [onResult] the app's answer map. With no app to ask the status is
     * `noVault`; an app that errors or does not answer in time is `failed`.
     */
    fun commit(
        rpId: String,
        username: String,
        userHandle: String?,
        replaceExisting: Boolean,
        onResult: (Map<*, *>) -> Unit,
    ) {
        if (channel == null) {
            onResult(mapOf("status" to STATUS_NO_VAULT))
            return
        }
        invoke(
            method = COMMIT_METHOD,
            arguments = mapOf(
                "rpId" to rpId,
                "username" to username,
                "userHandle" to userHandle,
                "replaceExisting" to replaceExisting,
            ),
            timeoutMs = COMMIT_TIMEOUT_MS,
        ) { answer ->
            onResult(answer ?: mapOf("status" to STATUS_FAILED))
        }
    }

    /** [onResult] runs exactly once, on the main thread, with null for "no answer". */
    private fun invoke(
        method: String,
        arguments: Map<String, Any?>,
        timeoutMs: Long,
        onResult: (Map<*, *>?) -> Unit,
    ) {
        val target = channel
        if (target == null) {
            onResult(null)
            return
        }

        var answered = false
        val timeout = Runnable {
            if (!answered) {
                answered = true
                Log.w(TAG, "$method timed out")
                onResult(null)
            }
        }
        fun deliver(answer: Map<*, *>?) {
            if (answered) return
            answered = true
            mainHandler.removeCallbacks(timeout)
            onResult(answer)
        }

        mainHandler.postDelayed(timeout, timeoutMs)
        try {
            target.invokeMethod(
                method,
                arguments,
                object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        deliver(result as? Map<*, *>)
                    }

                    override fun error(
                        errorCode: String,
                        errorMessage: String?,
                        errorDetails: Any?,
                    ) {
                        // The code only: a message could quote the arguments.
                        Log.w(TAG, "$method failed in the app")
                        deliver(null)
                    }

                    override fun notImplemented() {
                        // The engine is up but the app has not attached its
                        // handler yet, which is "not there" for this purpose.
                        deliver(null)
                    }
                },
            )
        } catch (error: Exception) {
            Log.w(TAG, "$method could not be sent: ${error.javaClass.simpleName}")
            deliver(null)
        }
    }
}
