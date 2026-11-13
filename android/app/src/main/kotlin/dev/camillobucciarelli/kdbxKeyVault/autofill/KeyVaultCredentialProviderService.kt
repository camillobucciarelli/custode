package dev.camillobucciarelli.kdbxKeyVault.autofill

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.os.CancellationSignal
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.credentials.provider.BeginCreateCredentialRequest
import androidx.credentials.provider.BeginCreateCredentialResponse
import androidx.credentials.provider.BeginGetCredentialOption
import androidx.credentials.provider.BeginGetCredentialRequest
import androidx.credentials.provider.BeginGetCredentialResponse
import androidx.credentials.provider.BeginGetPublicKeyCredentialOption
import androidx.credentials.provider.CredentialProviderService
import androidx.credentials.provider.ProviderClearCredentialStateRequest
import androidx.credentials.provider.PublicKeyCredentialEntry
import androidx.credentials.exceptions.ClearCredentialException
import androidx.credentials.exceptions.CreateCredentialException
import androidx.credentials.exceptions.CreateCredentialUnknownException
import androidx.credentials.exceptions.GetCredentialException
import org.json.JSONObject

/**
 * spec 023 T403 — Custode as a passkey source for Credential Manager.
 *
 * API 34 and above only, which is where the platform first has a credential
 * provider to register with (FR-013). Below that the manifest's service is
 * disabled at runtime and this class is never instantiated.
 *
 * The service answers from the **plaintext metadata** alone: rp ids and
 * credential ids, no unsealing, no key. Nothing here can sign — that happens
 * in [PasskeyAuthActivity], behind a biometric prompt, after the user has
 * chosen an entry from the system sheet.
 *
 * Passwords are untouched by this class. The autofill service of spec 016
 * keeps serving them; adding them here as well would put the same credential
 * in two system pickers.
 */
@RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
class KeyVaultCredentialProviderService : CredentialProviderService() {

    override fun onBeginGetCredentialRequest(
        request: BeginGetCredentialRequest,
        cancellationSignal: CancellationSignal,
        callback: android.os.OutcomeReceiver<BeginGetCredentialResponse, GetCredentialException>,
    ) {
        val entries = try {
            buildEntries(request.beginGetCredentialOptions)
        } catch (error: Exception) {
            // A malformed request is the caller's problem, not a reason to
            // crash the provider out of the user's sheet.
            Log.w(TAG, "begin get failed: ${error.javaClass.simpleName}")
            emptyList()
        }
        if (cancellationSignal.isCanceled) return
        // An empty response is the correct answer to "nothing here matches":
        // the platform simply shows no Custode rows.
        callback.onResult(BeginGetCredentialResponse(credentialEntries = entries))
    }

    private fun buildEntries(
        options: List<BeginGetCredentialOption>,
    ): List<PublicKeyCredentialEntry> {
        val metadata = AndroidAutofillStore(applicationContext).readCredentialMetadata()
        if (metadata.isEmpty()) return emptyList()

        val entries = mutableListOf<PublicKeyCredentialEntry>()
        for (option in options) {
            if (option !is BeginGetPublicKeyCredentialOption) continue
            val request = JSONObject(option.requestJson)
            val rpId = request.optString("rpId").trim().lowercase()
            if (rpId.isEmpty()) continue
            val allowed = request.optJSONArray("allowCredentials")?.let { array ->
                buildSet {
                    for (index in 0 until array.length()) {
                        val id = array.optJSONObject(index)?.optString("id")?.trim()
                        if (!id.isNullOrEmpty()) add(id)
                    }
                }
            }.orEmpty()

            for (record in metadata) {
                // FR-014: the relying party must match exactly, and an
                // `allowCredentials` the site sent must name this credential.
                val passkey = record.passkeys.firstOrNull { passkey ->
                    passkey.rpId.equals(rpId, ignoreCase = true) &&
                        (allowed.isEmpty() || allowed.contains(passkey.credentialId))
                } ?: continue

                entries.add(
                    PublicKeyCredentialEntry(
                        context = applicationContext,
                        username = record.username.ifEmpty { record.title },
                        pendingIntent = PasskeyAuthActivity.pendingIntent(
                            context = applicationContext,
                            entryId = record.id,
                            rpId = passkey.rpId,
                            credentialId = passkey.credentialId,
                            requestCode = entries.size,
                        ),
                        beginGetPublicKeyCredentialOption = option,
                        displayName = record.title,
                    ),
                )
            }
        }
        return entries
    }

    /**
     * Creating a passkey through Credential Manager is US3, which this spec
     * does not build. Answering with an explicit failure rather than leaving
     * the callback hanging is what keeps the system's create sheet responsive.
     */
    override fun onBeginCreateCredentialRequest(
        request: BeginCreateCredentialRequest,
        cancellationSignal: CancellationSignal,
        callback: android.os.OutcomeReceiver<BeginCreateCredentialResponse, CreateCredentialException>,
    ) {
        if (cancellationSignal.isCanceled) return
        callback.onError(
            CreateCredentialUnknownException("Custode cannot create passkeys yet"),
        )
    }

    /**
     * There is no per-app credential state to clear: what this provider knows
     * is the published cache, which the app owns and rewrites on every vault
     * change. Answering success is honest — after this call there is indeed
     * nothing stale left here.
     */
    override fun onClearCredentialStateRequest(
        request: ProviderClearCredentialStateRequest,
        cancellationSignal: CancellationSignal,
        callback: android.os.OutcomeReceiver<Void?, ClearCredentialException>,
    ) {
        if (cancellationSignal.isCanceled) return
        callback.onResult(null)
    }

    companion object {
        private const val TAG = "CustodePasskey"

        /** Extras shared with [PasskeyAuthActivity]. */
        const val EXTRA_ENTRY_ID = "dev.camillobucciarelli.keyvault.PASSKEY_ENTRY_ID"
        const val EXTRA_RP_ID = "dev.camillobucciarelli.keyvault.PASSKEY_RP_ID"
        const val EXTRA_CREDENTIAL_ID = "dev.camillobucciarelli.keyvault.PASSKEY_CREDENTIAL_ID"

        fun intentFor(
            context: android.content.Context,
            entryId: String,
            rpId: String,
            credentialId: String,
        ): Intent = Intent(context, PasskeyAuthActivity::class.java).apply {
            putExtra(EXTRA_ENTRY_ID, entryId)
            putExtra(EXTRA_RP_ID, rpId)
            putExtra(EXTRA_CREDENTIAL_ID, credentialId)
        }

        /**
         * `FLAG_MUTABLE` is required, not sloppiness: the platform fills the
         * chosen request into this intent before launching it, which an
         * immutable PendingIntent forbids.
         */
        fun pendingIntentFlags(): Int =
            PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
    }
}
