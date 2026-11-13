package dev.camillobucciarelli.kdbxKeyVault.autofill

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log

/**
 * spec 023 T405 — whether this device can be a passkey provider, and the
 * runtime switch that makes it one.
 *
 * Credential Manager's provider side arrived in API 34. Below that the
 * platform has nothing to register with, so the manifest ships the service
 * `android:enabled="false"` and it is turned on here, once, on a device that
 * can use it. A service declared and visible on API 29–33 would show the user
 * a setting that silently does nothing (FR-013).
 */
internal object AndroidPasskeyProviderAvailability {
    private const val TAG = "CustodePasskey"

    /** API 34. */
    const val MINIMUM_API_LEVEL = Build.VERSION_CODES.UPSIDE_DOWN_CAKE

    val isSupported: Boolean get() = Build.VERSION.SDK_INT >= MINIMUM_API_LEVEL

    /**
     * Brings the manifest component into line with [isSupported].
     *
     * Idempotent and best-effort: a failure here costs passkey sign-in, not
     * the app, so it is logged and swallowed rather than thrown at the
     * channel.
     */
    fun reconcile(context: Context) {
        val component = ComponentName(
            context,
            KeyVaultCredentialProviderService::class.java,
        )
        val wanted = if (isSupported) {
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED
        } else {
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED
        }
        try {
            val manager = context.packageManager
            if (manager.getComponentEnabledSetting(component) == wanted) return
            manager.setComponentEnabledSetting(
                component,
                wanted,
                PackageManager.DONT_KILL_APP,
            )
        } catch (error: Exception) {
            Log.w(TAG, "provider reconcile failed: ${error.javaClass.simpleName}")
        }
    }

    /** What the settings row reads. Never says which passkeys exist. */
    fun availabilityMap(): Map<String, Any> = mapOf(
        "available" to isSupported,
        "apiLevel" to Build.VERSION.SDK_INT,
    )
}
