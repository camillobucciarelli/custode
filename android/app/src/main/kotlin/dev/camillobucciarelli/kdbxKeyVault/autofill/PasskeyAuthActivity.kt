package dev.camillobucciarelli.kdbxKeyVault.autofill

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.widget.Toast
import androidx.annotation.RequiresApi
import androidx.credentials.PublicKeyCredential
import androidx.credentials.exceptions.GetCredentialCancellationException
import androidx.credentials.exceptions.GetCredentialUnknownException
import androidx.credentials.exceptions.NoCredentialException
import androidx.credentials.provider.PendingIntentHandler
import androidx.credentials.provider.ProviderGetCredentialRequest
import androidx.credentials.GetPublicKeyCredentialOption
import androidx.fragment.app.FragmentActivity
import dev.camillobucciarelli.kdbxKeyVault.R
import org.json.JSONObject

/**
 * spec 023 T404 — authenticates one chosen passkey and returns the assertion.
 *
 * The user already picked the entry in the system's sheet, so there is nothing
 * left to choose: this activity shows no list and reveals no vault content —
 * only the authentication prompt, and then a signature.
 *
 * The prompt appears **every time** (FR-015). It deliberately does not go
 * through [AutofillAuthGate], which honours the password path's 30-second
 * reuse window: that window exists because one login prompts for a username
 * and then a password, and a passkey has no such pair. Reusing it here would
 * let a second signature happen with no one watching.
 */
@RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
class PasskeyAuthActivity : FragmentActivity() {
    private var isAuthenticating = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val entryId = intent.getStringExtra(KeyVaultCredentialProviderService.EXTRA_ENTRY_ID)
        val rpId = intent.getStringExtra(KeyVaultCredentialProviderService.EXTRA_RP_ID)
        val credentialId =
            intent.getStringExtra(KeyVaultCredentialProviderService.EXTRA_CREDENTIAL_ID)
        val request = PendingIntentHandler.retrieveProviderGetCredentialRequest(intent)
        if (entryId.isNullOrBlank() || rpId.isNullOrBlank() || request == null) {
            finishWith(GetCredentialUnknownException("incomplete passkey request"))
            return
        }
        if (isAuthenticating) return
        isAuthenticating = true

        PasskeyUserPresence(this).require { authenticated ->
            if (!authenticated) {
                Toast.makeText(this, R.string.autofill_auth_cancelled, Toast.LENGTH_SHORT).show()
                finishWith(GetCredentialCancellationException())
                return@require
            }
            sign(entryId = entryId, rpId = rpId, credentialId = credentialId, request = request)
        }
    }

    private fun sign(
        entryId: String,
        rpId: String,
        credentialId: String?,
        request: ProviderGetCredentialRequest,
    ) {
        val option = request.credentialOptions
            .filterIsInstance<GetPublicKeyCredentialOption>()
            .firstOrNull()
        if (option == null) {
            finishWith(GetCredentialUnknownException("no passkey option in the request"))
            return
        }

        // The secret is unsealed only here, after the prompt succeeded.
        val secret = AndroidAutofillStore(applicationContext).readCredentialSecret(entryId)
        val passkey = secret?.passkeys?.firstOrNull { passkey ->
            passkey.rpId.equals(rpId, ignoreCase = true) &&
                (credentialId == null || passkey.credentialId == credentialId)
        }
        if (passkey == null) {
            // The vault changed under the sheet — synced, edited, locked.
            Log.i(TAG, "passkey no longer available")
            finishWith(NoCredentialException())
            return
        }

        val requestJson = JSONObject(option.requestJson)
        val challenge = requestJson.optString("challenge")
        if (challenge.isEmpty()) {
            finishWith(GetCredentialUnknownException("request carries no challenge"))
            return
        }

        val assertion = try {
            PasskeyAssertionBuilder.assert(
                passkey = passkey,
                challenge = challenge,
                origin = effectiveOrigin(request, rpId),
                androidPackageName = androidPackageName(request),
            )
        } catch (error: Exception) {
            Log.w(TAG, "assertion failed: ${error.javaClass.simpleName}")
            finishWith(GetCredentialUnknownException("this passkey cannot be used here"))
            return
        }

        val response = Intent()
        PendingIntentHandler.setGetCredentialResponse(
            response,
            androidx.credentials.GetCredentialResponse(
                PublicKeyCredential(
                    PasskeyAssertionBuilder.publicKeyCredentialJson(assertion),
                ),
            ),
        )
        setResult(RESULT_OK, response)
        finish()
    }

    /**
     * What goes into `clientDataJSON.origin`.
     *
     * A browser passes its page origin through `callingAppInfo`, and the
     * relying party checks exactly that string. A native app has no web
     * origin, so WebAuthn's Android binding uses the caller's signing
     * certificate hash instead; when even that is unavailable the rp id's own
     * https origin is the honest remaining answer.
     */
    private fun effectiveOrigin(request: ProviderGetCredentialRequest, rpId: String): String {
        browserOrigin(request)?.let { return it }

        val fingerprint = signingCertificateSha256(request)
        return if (fingerprint != null) "android:apk-key-hash:$fingerprint" else "https://$rpId"
    }

    private fun androidPackageName(request: ProviderGetCredentialRequest): String? {
        // Set only for a native caller: a web sign-in must not carry it, or
        // the relying party sees client data it did not expect.
        return if (browserOrigin(request) == null) request.callingAppInfo.packageName else null
    }

    /**
     * The web origin a privileged browser vouched for, or null.
     *
     * Any app can put an origin in its request, so it is trusted only when
     * the caller's package and signing certificate are on the privileged
     * allowlist (`res/raw/passkey_privileged_apps.json`, refreshed by
     * `tool/update_passkey_privileged_apps.sh`). Anyone else is treated as
     * the native app it is: an unlisted app claiming `https://bank.example`
     * must not get a signature that bank would accept.
     */
    private fun browserOrigin(request: ProviderGetCredentialRequest): String? {
        val callingAppInfo = request.callingAppInfo
        if (!callingAppInfo.isOriginPopulated()) return null
        val origin = try {
            callingAppInfo.getOrigin(privilegedAllowlist())
        } catch (error: Exception) {
            // Thrown for a caller that is not on the list, or a list that
            // does not parse; both mean "no trusted origin".
            Log.i(TAG, "origin not trusted: ${error.javaClass.simpleName}")
            null
        }
        return origin?.takeIf { it.isNotEmpty() }
    }

    private fun privilegedAllowlist(): String =
        resources.openRawResource(R.raw.passkey_privileged_apps)
            .bufferedReader()
            .use { it.readText() }

    private fun signingCertificateSha256(request: ProviderGetCredentialRequest): String? {
        val certificate = request.callingAppInfo.signingInfo
            .apkContentsSigners
            .firstOrNull()
            ?.toByteArray()
            ?: return null
        val digest = java.security.MessageDigest.getInstance("SHA-256").digest(certificate)
        return PasskeyAssertionBuilder.base64Url(digest)
    }

    private fun finishWith(error: androidx.credentials.exceptions.GetCredentialException) {
        val response = Intent()
        PendingIntentHandler.setGetCredentialException(response, error)
        setResult(RESULT_OK, response)
        finish()
    }

    companion object {
        private const val TAG = "CustodePasskey"

        /**
         * One PendingIntent per entry in the sheet. `requestCode` keeps them
         * distinct: two intents differing only in extras are "equal" to
         * `PendingIntent.getActivity`, so without it every row would launch
         * the first row's credential.
         */
        fun pendingIntent(
            context: Context,
            entryId: String,
            rpId: String,
            credentialId: String,
            requestCode: Int,
        ): PendingIntent = PendingIntent.getActivity(
            context,
            requestCode,
            KeyVaultCredentialProviderService.intentFor(
                context = context,
                entryId = entryId,
                rpId = rpId,
                credentialId = credentialId,
            ),
            KeyVaultCredentialProviderService.pendingIntentFlags(),
        )
    }
}
