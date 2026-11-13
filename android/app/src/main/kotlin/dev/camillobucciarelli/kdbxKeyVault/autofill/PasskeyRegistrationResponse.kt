package dev.camillobucciarelli.kdbxKeyVault.autofill

/**
 * spec 023 T805 — the WebAuthn `RegistrationResponseJSON` Credential Manager
 * hands back to the caller after Custode created a passkey.
 *
 * Pure Kotlin on purpose: no Android framework type and no `org.json`, so the
 * exact bytes a relying party will read are checked by plain JVM tests.
 *
 * Nothing here generates or sees a private key. The app creates the key pair
 * and writes the vault; this object only arranges the public values it
 * returned. It logs nothing.
 */
internal object PasskeyRegistrationResponse {
    /** COSE algorithm identifier of ES256, the only algorithm Custode creates. */
    const val ALGORITHM_ES256 = -7

    const val STATUS_DONE = "done"

    /**
     * The public values of a passkey the app has already written to the vault,
     * each base64url without padding.
     */
    class Created(
        val credentialId: String,
        val attestationObject: String,
        val authenticatorData: String,
        val publicKeySpki: String,
    ) {
        override fun toString(): String = "Created(redacted)"
    }

    /**
     * Reads the answer of `commitPasskeyRegistration`.
     *
     * Null unless the status is `done` AND every value the response needs is
     * present and well formed: a success must never be reported from a partial
     * answer.
     */
    fun createdFrom(result: Map<*, *>?): Created? {
        if (result == null || result["status"] != STATUS_DONE) return null
        return Created(
            credentialId = base64UrlValue(result["credentialId"]) ?: return null,
            attestationObject = base64UrlValue(result["attestationObject"]) ?: return null,
            authenticatorData = base64UrlValue(result["authenticatorData"]) ?: return null,
            publicKeySpki = base64UrlValue(result["publicKeySpki"]) ?: return null,
        )
    }

    /**
     * The client data of a registration ceremony.
     *
     * [challenge] is passed through exactly as the site sent it.
     * [androidPackageName] is set only when the request came from a native
     * app, as on the sign-in path.
     */
    fun clientDataJson(
        challenge: String,
        origin: String,
        androidPackageName: String?,
    ): ByteArray {
        val json = StringBuilder()
            .append("{\"type\":\"webauthn.create\"")
            .append(",\"challenge\":").append(quote(challenge))
            .append(",\"origin\":").append(quote(origin))
        if (androidPackageName != null) {
            json.append(",\"androidPackageName\":").append(quote(androidPackageName))
        }
        return json.append('}').toString().toByteArray(Charsets.UTF_8)
    }

    /** The whole JSON a relying party's code reads off the resolved promise. */
    fun json(created: Created, clientDataJson: ByteArray): String =
        StringBuilder()
            .append("{\"id\":").append(quote(created.credentialId))
            .append(",\"rawId\":").append(quote(created.credentialId))
            .append(",\"type\":\"public-key\"")
            .append(",\"authenticatorAttachment\":\"platform\"")
            .append(",\"response\":{")
            .append("\"clientDataJSON\":").append(quote(base64Url(clientDataJson)))
            .append(",\"attestationObject\":").append(quote(created.attestationObject))
            .append(",\"authenticatorData\":").append(quote(created.authenticatorData))
            .append(",\"publicKey\":").append(quote(created.publicKeySpki))
            .append(",\"publicKeyAlgorithm\":").append(ALGORITHM_ES256)
            .append(",\"transports\":[\"internal\",\"hybrid\"]")
            .append('}')
            .append(",\"clientExtensionResults\":{}")
            .append('}')
            .toString()

    fun base64Url(bytes: ByteArray): String =
        java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)

    /** A non-empty base64url string with any padding removed, or null. */
    private fun base64UrlValue(value: Any?): String? {
        val text = (value as? String)?.trim()?.trimEnd('=') ?: return null
        if (text.isEmpty()) return null
        val wellFormed = text.all { char ->
            char in 'A'..'Z' || char in 'a'..'z' || char in '0'..'9' || char == '-' || char == '_'
        }
        return if (wellFormed) text else null
    }

    /** A JSON string literal. */
    private fun quote(value: String): String {
        val out = StringBuilder(value.length + 2).append('"')
        for (char in value) {
            when {
                char == '"' -> out.append("\\\"")
                char == '\\' -> out.append("\\\\")
                char.code < 0x20 -> out.append("\\u").append(String.format("%04x", char.code))
                else -> out.append(char)
            }
        }
        return out.append('"').toString()
    }
}
