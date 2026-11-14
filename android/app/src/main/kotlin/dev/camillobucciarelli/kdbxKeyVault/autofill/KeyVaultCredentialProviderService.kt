package dev.camillobucciarelli.kdbxKeyVault.autofill

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.os.CancellationSignal
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.credentials.provider.BeginCreateCredentialRequest
import androidx.credentials.provider.BeginCreateCredentialResponse
import androidx.credentials.provider.BeginCreatePublicKeyCredentialRequest
import androidx.credentials.provider.CreateEntry
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
import dev.camillobucciarelli.kdbxKeyVault.R
import org.json.JSONObject

/**
 * spec 023 T403 — Custode as a passkey source for Credential Manager.
 *
 * API 34 and above only, which is where the platform first has a credential
 * provider to register with (FR-013). Below that the manifest's service is
 * disabled at runtime and this class is never instantiated.
 *
 * The service answers from the **plaintext metadata** of the cache (rp ids
 * and credential ids) plus, since spec 024, the plaintext envelope fields of
 * the pending passkey queue; no key is read. Nothing here can sign — that happens
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
        val store = AndroidAutofillStore(applicationContext)
        // spec 024 FR-10: no published cache, nothing offered, pending or not.
        val databaseId = store.publishedDatabaseId() ?: return emptyList()
        val metadata = store.readCredentialMetadata()
        // Envelope metadata only: nothing is decrypted before user verification.
        val pending = AndroidPendingPasskeyStore(applicationContext).readMetadata()

        val entries = mutableListOf<PublicKeyCredentialEntry>()
        for (option in options) {
            if (option !is BeginGetPublicKeyCredentialOption) continue
            val request = JSONObject(option.requestJson)
            val rpId = request.optString("rpId").trim().lowercase()
            // FR-014: the relying party must match exactly, and an
            // `allowCredentials` the site sent must name this credential.
            val offers = PasskeyProviderLogic.offers(
                rpId = rpId,
                allowed = PasskeyProviderLogic.credentialIds(request, "allowCredentials"),
                publishedDatabaseId = databaseId,
                cached = metadata,
                pending = pending,
            )
            for (offer in offers) {
                entries.add(
                    PublicKeyCredentialEntry(
                        context = applicationContext,
                        username = offer.username,
                        pendingIntent = PasskeyAuthActivity.pendingIntent(
                            context = applicationContext,
                            entryId = offer.entryId,
                            pendingRecordId = offer.pendingRecordId,
                            rpId = offer.rpId,
                            credentialId = offer.credentialId,
                            requestCode = entries.size,
                        ),
                        beginGetPublicKeyCredentialOption = option,
                        displayName = offer.displayName,
                    ),
                )
            }
        }
        return entries
    }

    /**
     * spec 024 T022. A public-key create request gets one entry opening
     * [PasskeyCreateActivity], which does the whole ceremony. A request that
     * does not offer ES256 gets no entry (FR-4), so the sheet offers another
     * provider instead. Other credential types are refused as before.
     */
    override fun onBeginCreateCredentialRequest(
        request: BeginCreateCredentialRequest,
        cancellationSignal: CancellationSignal,
        callback: android.os.OutcomeReceiver<BeginCreateCredentialResponse, CreateCredentialException>,
    ) {
        if (cancellationSignal.isCanceled) return
        if (request !is BeginCreatePublicKeyCredentialRequest) {
            callback.onError(CreateCredentialUnknownException("Custode creates passkeys only"))
            return
        }
        if (!PasskeyProviderLogic.offersEs256(request.requestJson)) {
            callback.onResult(BeginCreateCredentialResponse())
            return
        }
        val entry = CreateEntry.Builder(
            getString(R.string.autofill_service_label),
            PasskeyCreateActivity.pendingIntent(applicationContext),
        ).build()
        callback.onResult(BeginCreateCredentialResponse(createEntries = listOf(entry)))
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

        /** spec 024 T023: set instead of [EXTRA_ENTRY_ID] for a pending record. */
        const val EXTRA_PENDING_RECORD_ID = "dev.camillobucciarelli.keyvault.PASSKEY_PENDING_RECORD_ID"

        fun intentFor(
            context: android.content.Context,
            entryId: String?,
            pendingRecordId: String?,
            rpId: String,
            credentialId: String,
        ): Intent = Intent(context, PasskeyAuthActivity::class.java).apply {
            putExtra(EXTRA_ENTRY_ID, entryId)
            putExtra(EXTRA_PENDING_RECORD_ID, pendingRecordId)
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
