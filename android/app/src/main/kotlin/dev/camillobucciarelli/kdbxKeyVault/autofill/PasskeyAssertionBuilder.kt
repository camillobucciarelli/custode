package dev.camillobucciarelli.kdbxKeyVault.autofill

import java.security.KeyFactory
import java.security.MessageDigest
import java.security.Signature
import java.security.spec.PKCS8EncodedKeySpec
import java.util.Base64
import org.json.JSONObject

/**
 * spec 023 T402 — builds a WebAuthn assertion from a stored passkey.
 *
 * The only code on Android that touches a passkey's private key. It logs
 * nothing at all: not the key, not the challenge, not the origin
 * (Constitution I).
 *
 * Unlike the Apple path, the caller here builds the `clientDataJSON` itself
 * and hands back both it and the signature, because Android's Credential
 * Manager expects the whole `PublicKeyCredential` JSON in the response.
 */
internal object PasskeyAssertionBuilder {
    private const val FLAG_USER_PRESENT = 0x01
    private const val FLAG_USER_VERIFIED = 0x04
    private const val FLAG_BACKUP_ELIGIBLE = 0x08
    private const val FLAG_BACKUP_STATE = 0x10

    class UnsupportedAlgorithm(algorithm: String) :
        IllegalStateException("unsupported passkey algorithm: $algorithm")

    class BadKey : IllegalStateException("passkey private key cannot be read")

    data class Assertion(
        val credentialId: String,
        val authenticatorData: ByteArray,
        val signature: ByteArray,
        val clientDataJson: ByteArray,
        val userHandle: String?,
    )

    /**
     * `rpIdHash ‖ flags ‖ signCount(0)` — 37 bytes.
     *
     * The sign counter is fixed at zero deliberately: a vault synced across
     * devices cannot keep one monotonic counter, and a counter that goes
     * backwards reads as a cloned authenticator. Zero means "this
     * authenticator does not count", which WebAuthn permits.
     */
    fun authenticatorData(
        rpId: String,
        backupEligible: Boolean,
        backupState: Boolean,
    ): ByteArray {
        var flags = FLAG_USER_PRESENT or FLAG_USER_VERIFIED
        if (backupEligible) flags = flags or FLAG_BACKUP_ELIGIBLE
        if (backupEligible && backupState) flags = flags or FLAG_BACKUP_STATE

        val hash = MessageDigest.getInstance("SHA-256").digest(rpId.toByteArray(Charsets.UTF_8))
        return hash + byteArrayOf(flags.toByte(), 0, 0, 0, 0)
    }

    /**
     * The client data the relying party will verify.
     *
     * [challenge] is passed through exactly as the site sent it: WebAuthn's
     * client data serialization is defined over that string, so re-encoding
     * it produces a signature over the wrong bytes.
     *
     * [androidPackageName] is set only when the request came from a native
     * app; for a browser, [origin] is the page's own origin and the field is
     * omitted, which is what relying parties expect from a web sign-in.
     */
    fun clientDataJson(
        challenge: String,
        origin: String,
        androidPackageName: String?,
    ): ByteArray {
        val json = JSONObject()
            .put("type", "webauthn.get")
            .put("challenge", challenge)
            .put("origin", origin)
        if (androidPackageName != null) {
            json.put("androidPackageName", androidPackageName)
        }
        return json.toString().toByteArray(Charsets.UTF_8)
    }

    fun assert(
        passkey: AndroidAutofillPasskey,
        challenge: String,
        origin: String,
        androidPackageName: String?,
        suppliedClientDataHash: ByteArray? = null,
    ): Assertion {
        val authData = authenticatorData(
            rpId = passkey.rpId,
            backupEligible = passkey.backupEligible,
            backupState = passkey.backupState,
        )
        val clientData = clientDataJson(challenge, origin, androidPackageName)
        // GetPublicKeyCredentialOption.clientDataHash: "a clientDataHash value
        // to sign over in place of assembling and hashing clientDataJSON". A
        // privileged caller (a browser) sends its own clientDataJSON to the
        // relying party, so the signature must cover its hash, not ours. The
        // clientDataJSON in the response is then only a well-formed
        // placeholder: the library documents nothing about it in this case.
        val clientDataHash = suppliedClientDataHash?.takeIf { it.isNotEmpty() }
            ?: MessageDigest.getInstance("SHA-256").digest(clientData)
        val message = authData + clientDataHash

        val der = derFromPem(passkey.privateKeyPem) ?: throw BadKey()
        val signature = when (passkey.algorithm) {
            AndroidPasskeyAlgorithm.Es256 -> sign(der, "EC", "SHA256withECDSA", message)
            AndroidPasskeyAlgorithm.Rs256 -> sign(der, "RSA", "SHA256withRSA", message)
            // Ed25519 landed in the platform's JCA provider in API 33. Below
            // that the provider throws and the caller reports the passkey as
            // unusable rather than producing a signature the site rejects.
            AndroidPasskeyAlgorithm.EdDsa -> sign(der, "Ed25519", "Ed25519", message)
        }

        return Assertion(
            credentialId = passkey.credentialId,
            authenticatorData = authData,
            signature = signature,
            clientDataJson = clientData,
            userHandle = passkey.userHandle,
        )
    }

    /**
     * The whole JSON a relying party's JS reads off the resolved promise.
     *
     * Field names and encoding are WebAuthn's: base64url without padding
     * everywhere. Credential Manager hands this string to the caller as-is.
     */
    fun publicKeyCredentialJson(assertion: Assertion): String {
        val response = JSONObject()
            .put("clientDataJSON", base64Url(assertion.clientDataJson))
            .put("authenticatorData", base64Url(assertion.authenticatorData))
            .put("signature", base64Url(assertion.signature))
            .put("userHandle", assertion.userHandle ?: JSONObject.NULL)
        return JSONObject()
            .put("id", assertion.credentialId)
            .put("rawId", assertion.credentialId)
            .put("type", "public-key")
            .put("authenticatorAttachment", "platform")
            .put("clientExtensionResults", JSONObject())
            .put("response", response)
            .toString()
    }

    private fun sign(
        pkcs8: ByteArray,
        keyAlgorithm: String,
        signatureAlgorithm: String,
        message: ByteArray,
    ): ByteArray {
        val key = try {
            KeyFactory.getInstance(keyAlgorithm).generatePrivate(PKCS8EncodedKeySpec(pkcs8))
        } catch (error: Exception) {
            throw BadKey()
        }
        return try {
            Signature.getInstance(signatureAlgorithm).run {
                initSign(key)
                update(message)
                sign()
            }
        } catch (error: Exception) {
            throw UnsupportedAlgorithm(signatureAlgorithm)
        }
    }

    /** Returns null when the text is not a single PEM block. */
    private fun derFromPem(pem: String): ByteArray? {
        val lines = pem.lineSequence().map { it.trim() }.filter { it.isNotEmpty() }.toList()
        if (lines.size < 3 ||
            !lines.first().startsWith("-----BEGIN ") ||
            !lines.last().startsWith("-----END ")
        ) {
            return null
        }
        return try {
            Base64.getDecoder().decode(
                lines.subList(1, lines.size - 1).joinToString(separator = ""),
            )
        } catch (error: IllegalArgumentException) {
            null
        }
    }

    fun base64Url(bytes: ByteArray): String =
        Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)

    /** base64url, padded or not — KeePassXC omits the padding. */
    fun decodeBase64Url(value: String): ByteArray? = try {
        Base64.getUrlDecoder().decode(value)
    } catch (error: IllegalArgumentException) {
        null
    }
}
