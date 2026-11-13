package dev.camillobucciarelli.kdbxKeyVault.autofill

import org.json.JSONException
import org.json.JSONObject

/**
 * spec 023 T805 — what Custode reads from a WebAuthn
 * `PublicKeyCredentialCreationOptionsJSON`.
 *
 * The request comes from another app, so every field is treated as possibly
 * missing or of the wrong type, and a request that cannot be read is refused
 * rather than guessed at. It logs nothing.
 */
internal object PasskeyCreationRequest {
    private const val MAX_RP_ID_LENGTH = 253
    private const val MAX_USERNAME_LENGTH = 512
    private const val KEY_PARAMS = "pubKeyCredParams"

    /** Far above what a site sends; bounds what one request can make the app compare. */
    private const val MAX_EXCLUDE_CREDENTIALS = 256

    /**
     * [userHandle] is `user.id` as sent, base64url without padding.
     * [challenge] is untouched: client data is defined over that exact string.
     * [excludeCredentialIds] are the `excludeCredentials[].id` values, base64url
     * without padding: credentials the site says this account already has.
     */
    class Options(
        val rpId: String,
        val username: String,
        val userHandle: String?,
        val challenge: String,
        val excludeCredentialIds: List<String> = emptyList(),
    ) {
        override fun toString(): String = "Options(redacted)"
    }

    /**
     * Whether the site accepts ES256, the only algorithm Custode creates.
     *
     * A request with no `pubKeyCredParams`, or an empty list, states no
     * preference and is accepted. A list that names only other algorithms is
     * not: answering it would hand the site a key it said it cannot use.
     */
    fun supportsEs256(requestJson: String): Boolean {
        val json = parseObject(requestJson) ?: return false
        if (json.isNull(KEY_PARAMS)) return true
        val params = json.optJSONArray(KEY_PARAMS) ?: return false
        if (params.length() == 0) return true
        for (index in 0 until params.length()) {
            val param = params.optJSONObject(index) ?: continue
            val type = param.opt("type")
            if (type != null && type != JSONObject.NULL && type != "public-key") continue
            val algorithm = (param.opt("alg") as? Number)?.toDouble() ?: continue
            if (algorithm == PasskeyRegistrationResponse.ALGORITHM_ES256.toDouble()) return true
        }
        return false
    }

    /** Null when the request lacks a relying party, an account or a challenge. */
    fun parse(requestJson: String): Options? {
        val json = parseObject(requestJson) ?: return null
        val rpId = json.optJSONObject("rp")
            ?.text("id")
            ?.trim()
            ?.lowercase()
            ?.takeIf { it.isNotEmpty() && it.length <= MAX_RP_ID_LENGTH }
            ?: return null
        val user = json.optJSONObject("user") ?: return null
        val username = (
            user.text("name")?.trim()?.takeIf { it.isNotEmpty() }
                ?: user.text("displayName")?.trim()?.takeIf { it.isNotEmpty() }
            )
            ?.take(MAX_USERNAME_LENGTH)
            ?: return null
        val userHandle = user.text("id")?.trim()?.trimEnd('=')?.takeIf { it.isNotEmpty() }
        val challenge = json.text("challenge")?.takeIf { it.isNotEmpty() } ?: return null
        return Options(
            rpId = rpId,
            username = username,
            userHandle = userHandle,
            challenge = challenge,
            excludeCredentialIds = excludeCredentialIds(json),
        )
    }

    /**
     * An entry that is not an object, has no string id, or whose id is not
     * base64url is skipped rather than failing the request: it cannot name a
     * credential Custode holds. An absent list is an empty one.
     */
    private fun excludeCredentialIds(json: JSONObject): List<String> {
        val entries = json.optJSONArray("excludeCredentials") ?: return emptyList()
        val ids = LinkedHashSet<String>()
        for (index in 0 until entries.length()) {
            if (ids.size >= MAX_EXCLUDE_CREDENTIALS) break
            val id = entries.optJSONObject(index)?.text("id")?.trim()?.trimEnd('=') ?: continue
            if (id.isNotEmpty() && id.all(::isBase64UrlChar)) ids.add(id)
        }
        return ids.toList()
    }

    private fun isBase64UrlChar(char: Char): Boolean =
        char in 'A'..'Z' || char in 'a'..'z' || char in '0'..'9' || char == '-' || char == '_'

    private fun parseObject(value: String): JSONObject? = try {
        JSONObject(value)
    } catch (error: JSONException) {
        null
    }

    /** The value only when it really is a JSON string: never a coerced number or `null`. */
    private fun JSONObject.text(key: String): String? =
        if (isNull(key)) null else opt(key) as? String
}
