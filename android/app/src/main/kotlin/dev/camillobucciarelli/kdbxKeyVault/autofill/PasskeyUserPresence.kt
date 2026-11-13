package dev.camillobucciarelli.kdbxKeyVault.autofill

import android.app.KeyguardManager
import android.os.Build
import androidx.annotation.StringRes
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import dev.camillobucciarelli.kdbxKeyVault.R

/**
 * spec 023 FR-015 — the user proves they are present before any signature.
 *
 * Every time. Deliberately not [AutofillAuthGate], which honours the password
 * path's reuse window: that window exists because one login prompts for a
 * username and then a password, and a passkey has no such pair. Here a window
 * would only buy a signature nobody watched happen.
 *
 * `BIOMETRIC_STRONG or DEVICE_CREDENTIAL`, so a user whose fingerprint fails
 * can still sign in with the device credential rather than being locked out.
 */
internal class PasskeyUserPresence(
    private val activity: FragmentActivity,
    /** What the prompt says is about to happen: signing in, or creating a passkey. */
    @StringRes private val subtitle: Int = R.string.passkey_auth_prompt_subtitle,
) {

    fun require(onResult: (Boolean) -> Unit) {
        if (!hasAuthenticator()) {
            // A device that cannot prove presence must not sign: failing
            // closed costs one sign-in, failing open costs the key.
            onResult(false)
            return
        }

        val prompt = BiometricPrompt(
            activity,
            ContextCompat.getMainExecutor(activity),
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(
                    result: BiometricPrompt.AuthenticationResult,
                ) {
                    onResult(true)
                }

                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                    onResult(false)
                }
            },
        )
        prompt.authenticate(promptInfo())
    }

    private fun promptInfo(): BiometricPrompt.PromptInfo {
        val builder = BiometricPrompt.PromptInfo.Builder()
            .setTitle(activity.getString(R.string.passkey_auth_prompt_title))
            .setSubtitle(activity.getString(subtitle))
            .setConfirmationRequired(false)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            builder.setAllowedAuthenticators(
                BiometricManager.Authenticators.BIOMETRIC_STRONG or
                    BiometricManager.Authenticators.DEVICE_CREDENTIAL,
            )
        } else {
            @Suppress("DEPRECATION")
            builder.setDeviceCredentialAllowed(true)
        }
        return builder.build()
    }

    private fun hasAuthenticator(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            return BiometricManager.from(activity).canAuthenticate(
                BiometricManager.Authenticators.BIOMETRIC_STRONG or
                    BiometricManager.Authenticators.DEVICE_CREDENTIAL,
            ) == BiometricManager.BIOMETRIC_SUCCESS
        }
        return activity.getSystemService(KeyguardManager::class.java)?.isDeviceSecure == true
    }
}
