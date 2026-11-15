package dev.camillobucciarelli.kdbxKeyVault.autofill

import android.app.AlertDialog
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.widget.Toast
import androidx.annotation.RequiresApi
import androidx.credentials.CreatePublicKeyCredentialRequest
import androidx.credentials.CreatePublicKeyCredentialResponse
import androidx.credentials.exceptions.CreateCredentialCancellationException
import androidx.credentials.exceptions.CreateCredentialException
import androidx.credentials.exceptions.CreateCredentialUnknownException
import androidx.credentials.exceptions.domerrors.InvalidStateError
import androidx.credentials.exceptions.domerrors.NotSupportedError
import androidx.credentials.exceptions.publickeycredential.CreatePublicKeyCredentialDomException
import androidx.credentials.provider.PendingIntentHandler
import androidx.credentials.provider.ProviderCreateCredentialRequest
import androidx.fragment.app.FragmentActivity
import dev.camillobucciarelli.kdbxKeyVault.R

/**
 * spec 024 T022 — creates a passkey without the Flutter engine.
 *
 * Order matters and is the whole point of this class: ES256 check (FR-4),
 * published cache (FR-6), exclusion (FR-7), the user's confirmation, the
 * device prompt every time (SR-3), generation (FR-2), the sealed pending
 * record written and read back (FR-5), and only then the response to the
 * relying party. Any failure after generation answers an error: the site is
 * never told "registered" for a credential that is not on disk.
 *
 * No key material leaves [register]: not in a log, an extra or an error text
 * (SR-1).
 */
@RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
class PasskeyCreateActivity : FragmentActivity() {
    private var dialog: AlertDialog? = null

    /** One ceremony per activity instance: a second tap or callback is ignored. */
    private var ceremonyStarted = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Recreated (process reclaim, "don't keep activities", config change):
        // the ceremony may already have run, so never run it twice.
        if (savedInstanceState != null) {
            finishWith(CreateCredentialCancellationException())
            return
        }

        val request = PendingIntentHandler.retrieveProviderCreateCredentialRequest(intent)
        val options = (request?.callingRequest as? CreatePublicKeyCredentialRequest)
            ?.let { PasskeyProviderLogic.parseCreation(it.requestJson) }
        if (request == null || options == null) {
            finishWith(CreateCredentialUnknownException("incomplete passkey request"))
            return
        }
        if (!options.offersEs256) {
            finishWith(
                CreatePublicKeyCredentialDomException(NotSupportedError(), "ES256 is not offered"),
            )
            return
        }

        val store = AndroidAutofillStore(applicationContext)
        val databaseId = store.publishedDatabaseId()
        if (databaseId == null) {
            showLocked()
            return
        }

        // Envelope metadata only: no key is read to decide this.
        val conflict = PasskeyProviderLogic.conflict(
            options = options,
            cached = store.readCredentialMetadata(),
            pending = AndroidPendingPasskeyStore(applicationContext).readMetadata(),
        )
        if (conflict == PasskeyCreationConflict.ExcludedCredential) {
            show(
                AlertDialog.Builder(this)
                    .setMessage(getString(R.string.passkey_create_excluded_message, options.rpId))
                    .setPositiveButton(android.R.string.ok, null)
                    .setOnDismissListener {
                        finishWith(CreatePublicKeyCredentialDomException(InvalidStateError()))
                    },
            )
            return
        }

        val account = options.userName.ifEmpty { options.userDisplayName.orEmpty() }
        var message = getString(R.string.passkey_create_confirm_message, account, options.rpId)
        if (conflict == PasskeyCreationConflict.SameAccount) {
            message += "\n\n" + getString(R.string.passkey_create_same_account_warning)
        }
        // Before the confirmation, so nothing is lost if the later Toast is suppressed.
        message += "\n\n" + getString(R.string.passkey_create_done_message)
        var confirmed = false
        show(
            AlertDialog.Builder(this)
                .setTitle(R.string.passkey_create_confirm_title)
                .setMessage(message)
                .setPositiveButton(R.string.passkey_create_confirm_action) { _, _ -> confirmed = true }
                .setNegativeButton(android.R.string.cancel, null)
                .setOnDismissListener {
                    if (confirmed) {
                        authenticate(request, options, databaseId)
                    } else {
                        finishWith(CreateCredentialCancellationException())
                    }
                },
        )
    }

    private fun authenticate(
        request: ProviderCreateCredentialRequest,
        options: PasskeyCreationOptions,
        databaseId: String,
    ) {
        if (ceremonyStarted) return
        ceremonyStarted = true
        PasskeyUserPresence(this, R.string.passkey_create_prompt_subtitle).require { authenticated ->
            if (!authenticated) {
                Toast.makeText(this, R.string.autofill_auth_cancelled, Toast.LENGTH_SHORT).show()
                finishWith(CreateCredentialCancellationException())
                return@require
            }
            register(request, options, databaseId)
        }
    }

    private fun register(
        request: ProviderCreateCredentialRequest,
        options: PasskeyCreationOptions,
        databaseId: String,
    ) {
        // The vault may have been locked while the prompt was up (FR-6).
        if (AndroidAutofillStore(applicationContext).publishedDatabaseId() != databaseId) {
            showLocked()
            return
        }
        val recordStore = AndroidPendingPasskeyStore(applicationContext)
        var recordId: String? = null
        var written = false
        try {
            val registration = PasskeyRegistrationBuilder.create(options.rpId)
            val origin = PasskeyCallerOrigin.origin(this, request.callingAppInfo, options.rpId)
            val clientData = PasskeyRegistrationBuilder.clientDataJson(
                challenge = options.challenge,
                origin = origin,
                androidPackageName = PasskeyCallerOrigin.androidPackageName(this, request.callingAppInfo),
            )
            // Everything that can fail is built before the write; only setResult follows it.
            val result = Intent()
            PendingIntentHandler.setCreateCredentialResponse(
                result,
                CreatePublicKeyCredentialResponse(
                    PasskeyRegistrationBuilder.registrationResponseJson(registration, clientData),
                ),
            )
            recordId = AndroidPendingPasskeyStore.newRecordId()
            // FR-5: durable (sealed, renamed, read back) before any success.
            recordStore.write(
                PendingPasskeyRecord(
                    recordId = recordId,
                    databaseId = databaseId,
                    createdAtEpochMs = System.currentTimeMillis(),
                    rpId = options.rpId,
                    credentialId = PasskeyAssertionBuilder.base64Url(registration.credentialId),
                    userHandle = options.userHandle,
                    username = options.userName,
                    displayName = options.userDisplayName,
                    privateKeyPem = registration.privateKeyPem,
                    algorithm = AndroidPasskeyAlgorithm.Es256.rawValue,
                    be = true,
                    bs = true,
                    origin = origin,
                ),
            )
            written = true
            setResult(RESULT_OK, result)
        } catch (error: Exception) {
            Log.w(TAG, "passkey creation failed rpId=${options.rpId}: ${error.javaClass.simpleName}")
            // The site must not be told success, so a queued record would be a phantom passkey.
            if (written && recordId != null) runCatching { recordStore.resolve(recordId) }
            Toast.makeText(this, R.string.passkey_create_failed, Toast.LENGTH_LONG).show()
            finishWith(CreateCredentialUnknownException("the passkey could not be saved"))
            return
        }
        // Finish now: waiting on a dialog would keep the activity alive to be
        // recreated and replayed. The notice is also in the confirm dialog.
        runCatching { Toast.makeText(applicationContext, R.string.passkey_create_done_message, Toast.LENGTH_LONG).show() }
        finish()
    }

    /** FR-6: no published cache, no vault to bind to. Never starts or unlocks the app itself. */
    private fun showLocked() {
        show(
            AlertDialog.Builder(this)
                .setTitle(R.string.passkey_create_locked_title)
                .setMessage(R.string.passkey_create_locked_message)
                .setPositiveButton(R.string.passkey_create_open_custode) { _, _ ->
                    packageManager.getLaunchIntentForPackage(packageName)
                        ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        ?.let(::startActivity)
                }
                .setNegativeButton(android.R.string.cancel, null)
                .setOnDismissListener {
                    finishWith(CreateCredentialUnknownException("open and unlock Custode first"))
                },
        )
    }

    private fun show(builder: AlertDialog.Builder) {
        dialog = builder.create().also { it.show() }
    }

    override fun onDestroy() {
        // A dialog outliving its window (rotation, finish) leaks it.
        dialog?.setOnDismissListener(null)
        dialog?.dismiss()
        super.onDestroy()
    }

    private fun finishWith(error: CreateCredentialException) {
        if (isFinishing) return
        val response = Intent()
        PendingIntentHandler.setCreateCredentialException(response, error)
        setResult(RESULT_OK, response)
        finish()
    }

    companion object {
        private const val TAG = "CustodePasskey"

        /**
         * Mutable for the same reason as the sign-in entries: the platform
         * fills the create request into this intent before launching it.
         */
        fun pendingIntent(context: Context): PendingIntent = PendingIntent.getActivity(
            context,
            0,
            Intent(context, PasskeyCreateActivity::class.java),
            KeyVaultCredentialProviderService.pendingIntentFlags(),
        )
    }
}
