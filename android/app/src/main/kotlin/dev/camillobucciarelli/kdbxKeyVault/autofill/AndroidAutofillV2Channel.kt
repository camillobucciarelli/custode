package dev.camillobucciarelli.kdbxKeyVault.autofill

import android.content.Context
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

internal class AndroidAutofillV2Channel(context: Context) {
    private val store = AndroidAutofillStore(context)
    private val appContext = context.applicationContext

    init {
        // spec 023 T405: bring the credential provider component into line
        // with what this OS version can actually use. Done here rather than in
        // the service because a disabled component is never instantiated.
        AndroidPasskeyProviderAvailability.reconcile(appContext)
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "publishCredentials" -> handlePublishCredentials(call.arguments, result)
                "clearCredentials" -> handleClearCredentials(call.arguments, result)
                "readPendingAssociations" -> result.success(
                    store.readPendingAssociations().map(AndroidAutofillJson::pendingAssociationToMap),
                )
                "clearPendingAssociations" -> handleClearPendingAssociations(call.arguments, result)
                "readPendingCapture" -> handleReadPendingCapture(call.arguments, result)
                "resolvePendingCapture" -> handleResolvePendingCapture(call.arguments, result)
                "takePendingCaptureToken" -> result.success(takePendingCaptureToken())
                "getStatus" -> result.success(statusMap())
                // spec 023 T405: what the settings row reads.
                "getPasskeyProviderAvailability" -> result.success(
                    AndroidPasskeyProviderAvailability.availabilityMap(),
                )
                else -> result.notImplemented()
            }
        } catch (error: Throwable) {
            Log.w(TAG, "Android Autofill channel failed: ${error.javaClass.simpleName}")
            result.error("android_autofill_v2_failed", error.message, null)
        }
    }

    private fun handlePublishCredentials(arguments: Any?, result: MethodChannel.Result) {
        val args = arguments as? Map<*, *> ?: throw IllegalArgumentException("arguments must be a map")
        val databaseId = args["databaseId"] as? String
            ?: throw IllegalArgumentException("databaseId must be a string")
        val rawEntries = args["entries"] as? List<*>
            ?: throw IllegalArgumentException("entries must be a list")
        val entries = rawEntries.map(::parsePublishEntry)
        val authSessionTtlMs = parseAuthSessionTtlMs(args["authSessionTtlMs"])
        Log.i(TAG, "publishCredentials received entryCount=${entries.size}")
        result.success(
            store.publishCredentials(
                databaseId = databaseId,
                entries = entries,
                authSessionTtlMs = authSessionTtlMs,
            ),
        )
    }

    private fun handleClearCredentials(arguments: Any?, result: MethodChannel.Result) {
        val databaseId = (arguments as? Map<*, *>)?.get("databaseId") as? String
        Log.i(TAG, "clearCredentials received hasDatabaseId=${databaseId != null}")
        result.success(store.clearCredentials(databaseId = databaseId))
    }

    private fun handleClearPendingAssociations(arguments: Any?, result: MethodChannel.Result) {
        val ids = ((arguments as? Map<*, *>)?.get("ids") as? List<*>)
            ?.mapNotNull { it as? String }
        val clearedCount = store.clearPendingAssociations(ids = ids)
        result.success(mapOf("clearedCount" to clearedCount, "warnings" to emptyList<String>()))
    }

    /**
     * The token of a save capture the app was launched for, kept until Dart
     * asks for it: a cold start reaches [handle] only after the engine is up,
     * so the launching intent cannot simply be pushed at it.
     */
    private var pendingCaptureToken: String? = null

    fun setPendingCaptureToken(token: String?) {
        pendingCaptureToken = token?.trim()?.takeIf { it.isNotEmpty() }
        Log.d(TAG, "pendingCaptureToken set=${pendingCaptureToken != null}")
    }

    private fun takePendingCaptureToken(): String? {
        val token = pendingCaptureToken
        pendingCaptureToken = null
        Log.d(TAG, "takePendingCaptureToken -> ${token != null}")
        return token
    }

    private fun handleReadPendingCapture(arguments: Any?, result: MethodChannel.Result) {
        val token = parseToken(arguments)
        val capture = AndroidAutofillCaptureHolder.shared.readSecret(token)
        Log.d(TAG, "readPendingCapture found=${capture != null} pending=${AndroidAutofillCaptureHolder.shared.size()}")
        if (capture == null) {
            // Expected: process death, expiry, or a second read of one token.
            result.error(CAPTURE_MISSING, "No pending capture for this token.", null)
            return
        }
        result.success(
            mapOf(
                "token" to capture.token,
                "username" to capture.username,
                "password" to capture.password,
                "packageName" to capture.packageName,
                "webDomain" to capture.webDomain,
                "capturedAtEpochMs" to capture.capturedAtEpochMs,
            ),
        )
    }

    private fun handleResolvePendingCapture(arguments: Any?, result: MethodChannel.Result) {
        val args = arguments as? Map<*, *> ?: throw IllegalArgumentException("arguments must be a map")
        val token = parseToken(arguments)
        val outcome = args["outcome"] as? String
            ?: throw IllegalArgumentException("outcome must be a string")
        require(outcome in RESOLVE_OUTCOMES) { "outcome is not a known value" }

        val capture = AndroidAutofillCaptureHolder.shared.resolve(token)
        if (outcome == "declined" && capture != null) {
            store.recordDeclinedSave(
                association = capture.association,
                username = capture.username,
            )
        }
        Log.i(TAG, "resolvePendingCapture outcome=$outcome known=${capture != null}")
        result.success(
            mapOf(
                "clearedCount" to if (capture == null) 0 else 1,
                "warnings" to emptyList<String>(),
            ),
        )
    }

    private fun parseToken(arguments: Any?): String {
        val args = arguments as? Map<*, *> ?: throw IllegalArgumentException("arguments must be a map")
        val token = (args["token"] as? String)?.trim()
        require(!token.isNullOrEmpty()) { "token must be a non-empty string" }
        return token
    }

    private fun parseAuthSessionTtlMs(rawValue: Any?): Long {
        val value = when (rawValue) {
            null -> 0L
            is Int -> rawValue.toLong()
            is Long -> rawValue
            else -> throw IllegalArgumentException("authSessionTtlMs must be an integer")
        }
        require(value >= 0L) { "authSessionTtlMs must not be negative" }
        return value
    }

    private fun statusMap(): Map<String, Any?> {
        val status = store.status()
        return mapOf(
            "version" to ANDROID_AUTOFILL_CACHE_VERSION,
            "appGroupAvailable" to true,
            "keychainAccessGroupAvailable" to true,
            "metadataCount" to status.metadataCount,
            "encryptedCacheAvailable" to status.encryptedCacheAvailable,
            "cacheAvailable" to status.cacheAvailable,
            "databaseId" to status.databaseId,
            "generatedAtEpochMs" to status.generatedAtEpochMs,
            "authSessionTtlMs" to status.authSessionTtlMs,
            "lastAuthenticatedAtEpochMs" to status.lastAuthenticatedAtEpochMs,
        )
    }

    private fun parsePublishEntry(rawValue: Any?): AndroidAutofillPublishEntry {
        val map = rawValue as? Map<*, *> ?: throw IllegalArgumentException("entry must be a map")
        return AndroidAutofillPublishEntry(
            id = map["id"] as? String ?: throw IllegalArgumentException("entry.id must be a string"),
            title = map["title"] as? String ?: "",
            username = map["username"] as? String ?: "",
            password = map["password"] as? String
                ?: throw IllegalArgumentException("entry.password must be a string"),
            url = map["url"] as? String,
            serviceIdentifiers = parseServiceIdentifiers(map["serviceIdentifiers"]),
            passkeys = parsePasskeys(map["passkeys"]),
        )
    }

    /**
     * spec 023 — the `passkeys` list of `contracts/passkey_platform_bridges.md`.
     *
     * Absent from an older app's payload, which is not an error: it has no
     * passkeys to publish. A malformed entry inside the list IS dropped here
     * rather than failing the whole publish — one unreadable passkey must not
     * cost the user every password in the cache.
     */
    private fun parsePasskeys(rawValue: Any?): List<AndroidAutofillPasskey> {
        val rawList = rawValue as? List<*> ?: return emptyList()
        return rawList.mapNotNull { rawPasskey ->
            val map = rawPasskey as? Map<*, *> ?: return@mapNotNull null
            val rpId = (map["rpId"] as? String)?.trim()?.lowercase().orEmpty()
            val credentialId = (map["credentialId"] as? String)?.trim().orEmpty()
            val pem = map["privateKeyPem"] as? String ?: return@mapNotNull null
            val algorithm = AndroidPasskeyAlgorithm.fromRawValue(
                map["algorithm"] as? String ?: "",
            ) ?: return@mapNotNull null
            if (rpId.isEmpty() || rpId.length > 253 || credentialId.isEmpty() || pem.isEmpty()) {
                return@mapNotNull null
            }
            val backupEligible = map["be"] as? Boolean ?: true
            AndroidAutofillPasskey(
                rpId = rpId,
                credentialId = credentialId,
                userHandle = (map["userHandle"] as? String)?.trim()?.ifEmpty { null },
                username = (map["username"] as? String).orEmpty().take(512),
                privateKeyPem = pem,
                algorithm = algorithm,
                backupEligible = backupEligible,
                backupState = backupEligible && (map["bs"] as? Boolean ?: true),
            )
        }
    }

    private fun parseServiceIdentifiers(rawValue: Any?): List<AndroidAutofillServiceIdentifier> {
        val rawList = rawValue as? List<*> ?: return emptyList()
        return rawList.mapNotNull { rawIdentifier ->
            val map = rawIdentifier as? Map<*, *> ?: return@mapNotNull null
            val rawType = map["type"] as? String ?: return@mapNotNull null
            val type = AndroidAutofillServiceIdentifierType.fromRawValue(rawType) ?: return@mapNotNull null
            val value = (map["value"] as? String)?.trim().orEmpty()
            if (value.isEmpty()) {
                null
            } else {
                AndroidAutofillServiceIdentifier(type = type, value = value)
            }
        }
    }

    companion object {
        const val CHANNEL_NAME = "dev.camillobucciarelli.keyvault/apple_autofill_v2"
        const val CAPTURE_MISSING = "android_autofill_capture_missing"
        private const val TAG = "CustodeAutofill"
        private val RESOLVE_OUTCOMES = setOf("saved", "updated", "declined", "cancelled", "failed")
    }
}
