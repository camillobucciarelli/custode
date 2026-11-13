package dev.camillobucciarelli.kdbxKeyVault.autofill

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.View
import android.widget.Button
import android.widget.TextView
import android.widget.Toast
import androidx.activity.OnBackPressedCallback
import androidx.annotation.RequiresApi
import androidx.credentials.CreatePublicKeyCredentialRequest
import androidx.credentials.CreatePublicKeyCredentialResponse
import androidx.credentials.exceptions.CreateCredentialCancellationException
import androidx.credentials.exceptions.CreateCredentialException
import androidx.credentials.exceptions.CreateCredentialUnknownException
import androidx.credentials.exceptions.domerrors.InvalidStateError
import androidx.credentials.exceptions.publickeycredential.CreatePublicKeyCredentialDomException
import androidx.credentials.provider.PendingIntentHandler
import androidx.fragment.app.FragmentActivity
import dev.camillobucciarelli.kdbxKeyVault.MainActivity
import dev.camillobucciarelli.kdbxKeyVault.R

/**
 * spec 023 T805 — creates a passkey for a site that asked Credential Manager.
 *
 * This activity owns the confirmation and the user presence check and nothing
 * else. It holds no key and writes no vault: only the running app can do
 * that, so the work is two calls on [PasskeyRegistrationBridge] — `prepare`
 * says whether a vault is open and whether a passkey would be replaced,
 * `commit` writes and returns the public values.
 *
 * The prompt appears **every time**, after the user has read what will be
 * created and before anything is written (FR-015). Success is reported only
 * for a `done` answer that carries every value the response needs.
 *
 * When the site lists, in `excludeCredentials`, a credential the vault already
 * holds, `prepare` answers `excluded`: the screen says so, `commit` is never
 * called, and the caller gets WebAuthn's `InvalidStateError`.
 */
@RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
class PasskeyCreateActivity : FragmentActivity() {
    private enum class Stage {
        Checking,
        Blocked,
        Ready,

        /** The site excluded a credential the vault holds. Nothing can be created. */
        Excluded,
        Authenticating,
        Committing,
        Finished,
    }

    private var stage = Stage.Checking

    /** What the user was last shown, and therefore what `commit` is told. */
    private var replaces = false

    /** Bumped whenever an in-flight `prepare` answer must no longer apply. */
    private var prepareGeneration = 0

    private var options: PasskeyCreationRequest.Options? = null
    private var caller: PasskeyCallerIdentity.Caller? = null

    private lateinit var messageView: TextView
    private lateinit var detailsView: View
    private lateinit var warningView: TextView
    private lateinit var primaryButton: Button
    private lateinit var cancelButton: Button

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val request = try {
            PendingIntentHandler.retrieveProviderCreateCredentialRequest(intent)
        } catch (error: Exception) {
            Log.w(TAG, "create request unreadable: ${error.javaClass.simpleName}")
            null
        }
        val publicKeyRequest = request?.callingRequest as? CreatePublicKeyCredentialRequest
        if (request == null || publicKeyRequest == null) {
            finishWith(CreateCredentialUnknownException("incomplete passkey request"))
            return
        }
        val parsed = PasskeyCreationRequest.parse(publicKeyRequest.requestJson)
        if (parsed == null) {
            finishWith(CreateCredentialUnknownException("incomplete passkey request"))
            return
        }
        if (!PasskeyCreationRequest.supportsEs256(publicKeyRequest.requestJson)) {
            finishWith(
                CreateCredentialUnknownException("Custode creates ES256 passkeys only"),
            )
            return
        }
        options = parsed
        caller = PasskeyCallerIdentity.resolve(this, request.callingAppInfo, parsed.rpId)

        bindContentView(parsed)
        onBackPressedDispatcher.addCallback(
            this,
            object : OnBackPressedCallback(true) {
                override fun handleOnBackPressed() {
                    cancel()
                }
            },
        )
        render()
    }

    override fun onResume() {
        super.onResume()
        // Also the way back from "Open Custode": the user unlocks the vault,
        // returns here, and the flow continues without another tap.
        if (stage == Stage.Checking || stage == Stage.Blocked || stage == Stage.Ready) {
            prepare()
        }
    }

    private fun bindContentView(options: PasskeyCreationRequest.Options) {
        setContentView(R.layout.passkey_create_activity)
        messageView = findViewById(R.id.passkey_create_message)
        detailsView = findViewById(R.id.passkey_create_details)
        warningView = findViewById(R.id.passkey_create_warning)
        primaryButton = findViewById(R.id.passkey_create_primary)
        cancelButton = findViewById(R.id.passkey_create_cancel)

        findViewById<TextView>(R.id.passkey_create_site).text = options.rpId
        findViewById<TextView>(R.id.passkey_create_account).text = options.username
        cancelButton.setOnClickListener { cancel() }
        primaryButton.setOnClickListener {
            when (stage) {
                Stage.Blocked -> openCustode()
                Stage.Ready -> confirm()
                Stage.Excluded -> finishExcluded()
                else -> Unit
            }
        }
    }

    private fun prepare() {
        val options = options ?: return
        val generation = ++prepareGeneration
        PasskeyRegistrationBridge.prepare(
            rpId = options.rpId,
            userHandle = options.userHandle,
            excludeCredentialIds = options.excludeCredentialIds,
        ) answer@{ prepared ->
            if (generation != prepareGeneration || isFinishing || isDestroyed) return@answer
            if (stage != Stage.Checking && stage != Stage.Blocked && stage != Stage.Ready) {
                return@answer
            }
            Log.i(TAG, "prepare status=${prepared.status}")
            when (prepared.status) {
                PasskeyRegistrationBridge.STATUS_READY -> {
                    replaces = prepared.replaces
                    stage = Stage.Ready
                }
                // Terminal: `onResume` does not ask again and no button leads
                // to `confirm`, so `commit` cannot follow.
                PasskeyRegistrationBridge.STATUS_EXCLUDED -> {
                    replaces = false
                    stage = Stage.Excluded
                }
                else -> {
                    replaces = false
                    stage = Stage.Blocked
                }
            }
            render()
        }
    }

    private fun render() {
        val showsRequest = stage == Stage.Ready ||
            stage == Stage.Authenticating ||
            stage == Stage.Committing
        messageView.setText(
            when (stage) {
                Stage.Checking -> R.string.passkey_create_checking
                Stage.Blocked -> R.string.passkey_create_blocked_message
                Stage.Excluded -> R.string.passkey_create_excluded_message
                Stage.Committing -> R.string.passkey_create_saving
                else -> R.string.passkey_create_ready_message
            },
        )
        detailsView.visibility = if (showsRequest) View.VISIBLE else View.GONE
        warningView.visibility = if (showsRequest && replaces) View.VISIBLE else View.GONE
        primaryButton.setText(
            when (stage) {
                Stage.Blocked -> R.string.passkey_create_open_custode
                Stage.Excluded -> R.string.passkey_create_close
                else -> R.string.passkey_create_confirm
            },
        )
        primaryButton.visibility = if (stage == Stage.Checking) View.INVISIBLE else View.VISIBLE
        primaryButton.isEnabled =
            stage == Stage.Blocked || stage == Stage.Ready || stage == Stage.Excluded
        // Once the app has been told to write, leaving would report a
        // cancellation for a passkey the vault may already hold.
        cancelButton.isEnabled = stage != Stage.Committing
        // Nothing is left to cancel once the answer is "already here": Close
        // is the only way out.
        cancelButton.visibility = if (stage == Stage.Excluded) View.GONE else View.VISIBLE
    }

    private fun openCustode() {
        val launch = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            startActivity(launch)
        } catch (error: Exception) {
            Log.w(TAG, "could not open the app: ${error.javaClass.simpleName}")
        }
    }

    private fun confirm() {
        // Any `prepare` still in flight must not repaint over the prompt.
        prepareGeneration++
        stage = Stage.Authenticating
        render()

        PasskeyUserPresence(this, R.string.passkey_create_prompt_subtitle).require presence@{ present ->
            if (isFinishing || isDestroyed || stage != Stage.Authenticating) return@presence
            if (!present) {
                Toast.makeText(this, R.string.passkey_create_auth_cancelled, Toast.LENGTH_SHORT)
                    .show()
                stage = Stage.Ready
                render()
                return@presence
            }
            commit()
        }
    }

    private fun commit() {
        val options = options ?: return
        val caller = caller ?: return
        stage = Stage.Committing
        render()

        PasskeyRegistrationBridge.commit(
            rpId = options.rpId,
            username = options.username,
            userHandle = options.userHandle,
            replaceExisting = replaces,
        ) answer@{ answer ->
            if (isFinishing || isDestroyed || stage != Stage.Committing) return@answer
            val status = answer["status"] as? String ?: PasskeyRegistrationBridge.STATUS_FAILED
            Log.i(TAG, "commit status=$status")
            val created = PasskeyRegistrationResponse.createdFrom(answer)
            if (created == null) {
                fail(status)
                return@answer
            }
            succeed(created, options, caller)
        }
    }

    private fun succeed(
        created: PasskeyRegistrationResponse.Created,
        options: PasskeyCreationRequest.Options,
        caller: PasskeyCallerIdentity.Caller,
    ) {
        val response = Intent()
        try {
            val json = PasskeyRegistrationResponse.json(
                created = created,
                clientDataJson = PasskeyRegistrationResponse.clientDataJson(
                    challenge = options.challenge,
                    origin = caller.origin,
                    androidPackageName = caller.androidPackageName,
                ),
            )
            PendingIntentHandler.setCreateCredentialResponse(
                response,
                CreatePublicKeyCredentialResponse(json),
            )
        } catch (error: Exception) {
            Log.w(TAG, "registration response failed: ${error.javaClass.simpleName}")
            fail(PasskeyRegistrationBridge.STATUS_FAILED)
            return
        }
        stage = Stage.Finished
        setResult(RESULT_OK, response)
        finish()
    }

    /** Any answer that is not a complete `done`. Never a success. */
    private fun fail(status: String) {
        val (toast, message) = when (status) {
            "alreadyExists" -> R.string.passkey_create_already_exists to
                "Custode already holds a passkey for this account"
            "locked", PasskeyRegistrationBridge.STATUS_NO_VAULT ->
                R.string.passkey_create_locked to
                    "Custode was locked or closed before the passkey was saved"
            else -> R.string.passkey_create_failed to "Custode could not save the passkey"
        }
        Toast.makeText(this, toast, Toast.LENGTH_LONG).show()
        finishWith(CreateCredentialUnknownException(message))
    }

    private fun cancel() {
        if (stage == Stage.Committing || stage == Stage.Finished) return
        if (stage == Stage.Excluded) {
            // Back on the "already here" screen is the same answer as Close.
            finishExcluded()
            return
        }
        finishWith(CreateCredentialCancellationException())
    }

    /** WebAuthn's answer for "the authenticator holds an excluded credential". */
    private fun finishExcluded() {
        finishWith(
            CreatePublicKeyCredentialDomException(
                InvalidStateError(),
                "Custode already holds a passkey for this account on this site",
            ),
        )
    }

    private fun finishWith(error: CreateCredentialException) {
        stage = Stage.Finished
        val response = Intent()
        PendingIntentHandler.setCreateCredentialException(response, error)
        setResult(RESULT_OK, response)
        finish()
    }

    companion object {
        private const val TAG = "CustodePasskey"

        /**
         * Its own request code, away from the per-entry codes of the sign-in
         * sheet. `FLAG_MUTABLE` because the platform fills the chosen request
         * into this intent before launching it; the intent names this class
         * explicitly, which a mutable PendingIntent must.
         */
        private const val REQUEST_CODE = 0x0805

        fun pendingIntent(context: Context): PendingIntent = PendingIntent.getActivity(
            context,
            REQUEST_CODE,
            Intent(context, PasskeyCreateActivity::class.java),
            KeyVaultCredentialProviderService.pendingIntentFlags(),
        )
    }
}
