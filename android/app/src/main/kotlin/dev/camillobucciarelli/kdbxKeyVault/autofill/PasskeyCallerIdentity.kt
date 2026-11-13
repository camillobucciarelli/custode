package dev.camillobucciarelli.kdbxKeyVault.autofill

import android.content.Context
import android.util.Log
import androidx.credentials.provider.CallingAppInfo
import dev.camillobucciarelli.kdbxKeyVault.R

/**
 * spec 023 — who is asking for a passkey operation, as the relying party will
 * read it in `clientDataJSON`.
 *
 * Shared by sign-in ([PasskeyAuthActivity]) and registration
 * ([PasskeyCreateActivity]) so both ceremonies state the caller identically.
 * It logs nothing about the caller beyond an exception class name.
 */
internal object PasskeyCallerIdentity {
    private const val TAG = "CustodePasskey"

    /**
     * [origin] goes into `clientDataJSON.origin`. [androidPackageName] is set
     * only for a native caller: a web ceremony must not carry it, or the
     * relying party sees client data it did not expect.
     */
    class Caller(val origin: String, val androidPackageName: String?)

    /**
     * A browser passes its page origin through `callingAppInfo`, and the
     * relying party checks exactly that string. A native app has no web
     * origin, so WebAuthn's Android binding uses the caller's signing
     * certificate hash instead; when even that is unavailable the rp id's own
     * https origin is the honest remaining answer.
     */
    fun resolve(context: Context, callingAppInfo: CallingAppInfo, rpId: String): Caller {
        val browserOrigin = browserOrigin(context, callingAppInfo)
        if (browserOrigin != null) {
            return Caller(origin = browserOrigin, androidPackageName = null)
        }
        val fingerprint = signingCertificateSha256(callingAppInfo)
        return Caller(
            origin = if (fingerprint != null) {
                "android:apk-key-hash:$fingerprint"
            } else {
                "https://$rpId"
            },
            androidPackageName = callingAppInfo.packageName,
        )
    }

    /**
     * The web origin a privileged browser vouched for, or null.
     *
     * Any app can put an origin in its request, so it is trusted only when
     * the caller's package and signing certificate are on the privileged
     * allowlist (`res/raw/passkey_privileged_apps.json`, refreshed by
     * `tool/update_passkey_privileged_apps.sh`). Anyone else is treated as
     * the native app it is: an unlisted app claiming `https://bank.example`
     * must not get a response that bank would accept.
     */
    private fun browserOrigin(context: Context, callingAppInfo: CallingAppInfo): String? {
        if (!callingAppInfo.isOriginPopulated()) return null
        val origin = try {
            callingAppInfo.getOrigin(privilegedAllowlist(context))
        } catch (error: Exception) {
            // Thrown for a caller that is not on the list, or a list that
            // does not parse; both mean "no trusted origin".
            Log.i(TAG, "origin not trusted: ${error.javaClass.simpleName}")
            null
        }
        return origin?.takeIf { it.isNotEmpty() }
    }

    private fun privilegedAllowlist(context: Context): String =
        context.resources.openRawResource(R.raw.passkey_privileged_apps)
            .bufferedReader()
            .use { it.readText() }

    private fun signingCertificateSha256(callingAppInfo: CallingAppInfo): String? {
        val certificate = callingAppInfo.signingInfo
            .apkContentsSigners
            .firstOrNull()
            ?.toByteArray()
            ?: return null
        val digest = java.security.MessageDigest.getInstance("SHA-256").digest(certificate)
        return PasskeyAssertionBuilder.base64Url(digest)
    }
}
