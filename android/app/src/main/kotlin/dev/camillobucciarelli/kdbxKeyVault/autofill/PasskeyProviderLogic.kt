package dev.camillobucciarelli.kdbxKeyVault.autofill

import org.json.JSONObject

/**
 * spec 024 T022/T023. Pure JVM decisions of the Credential Manager provider:
 * reading a create request, the ES256 gate (FR-4), the exclusion check (FR-7)
 * and the list of passkeys offered for a sign-in, cached plus pending (FR-10).
 * No Android types, no key material kept: the activities and the service stay
 * thin and this file is what the unit tests pin.
 */
internal class PasskeyCreationOptions(
    val rpId: String,
    val challenge: String,
    /** `user.id`, base64url as the site sent it, unpadded. */
    val userHandle: String?,
    val userName: String,
    val userDisplayName: String?,
    val offersEs256: Boolean,
    val excludeCredentialIds: Set<String>,
)

internal enum class PasskeyCreationConflict { None, SameAccount, ExcludedCredential }

/** One row of the sign-in sheet: exactly one of [entryId] and [pendingRecordId] is set. */
internal data class PasskeyOffer(
    val entryId: String?,
    val pendingRecordId: String?,
    val rpId: String,
    val credentialId: String,
    val username: String,
    val displayName: String,
)

internal object PasskeyProviderLogic {
    private const val COSE_ES256 = -7

    /** Null when the JSON is not a usable creation request (no rp id or challenge). */
    fun parseCreation(requestJson: String): PasskeyCreationOptions? = try {
        val json = JSONObject(requestJson)
        val rpId = json.optJSONObject("rp")?.optString("id")?.trim()?.lowercase().orEmpty()
        val challenge = json.optString("challenge")
        val user = json.optJSONObject("user")
        if (rpId.isEmpty() || challenge.isEmpty()) {
            null
        } else {
            PasskeyCreationOptions(
                rpId = rpId,
                challenge = challenge,
                userHandle = user?.optString("id")?.let(::unpadded)?.takeIf { it.isNotEmpty() },
                userName = user?.optString("name")?.trim().orEmpty(),
                userDisplayName = user?.optString("displayName")?.trim()?.takeIf { it.isNotEmpty() },
                offersEs256 = offersEs256(json),
                excludeCredentialIds = credentialIds(json, "excludeCredentials"),
            )
        }
    } catch (error: Exception) {
        // org.json messages can echo request content: never propagate them.
        null
    }

    /** FR-4 on the raw JSON, for the begin stage where nothing else is needed. */
    fun offersEs256(requestJson: String): Boolean = try {
        offersEs256(JSONObject(requestJson))
    } catch (error: Exception) {
        false
    }

    /**
     * An absent or empty `pubKeyCredParams` means ES256 and RS256 (WebAuthn L3
     * 5.1.3, "if pubKeyCredParams is empty, append ES256 and RS256").
     */
    private fun offersEs256(json: JSONObject): Boolean {
        val params = json.optJSONArray("pubKeyCredParams") ?: return true
        if (params.length() == 0) return true
        for (index in 0 until params.length()) {
            val param = params.optJSONObject(index) ?: continue
            if (param.optString("type", "public-key") == "public-key" &&
                param.has("alg") && param.optInt("alg", 0) == COSE_ES256
            ) {
                return true
            }
        }
        return false
    }

    fun credentialIds(json: JSONObject, field: String): Set<String> {
        val array = json.optJSONArray(field) ?: return emptySet()
        return buildSet {
            for (index in 0 until array.length()) {
                val id = array.optJSONObject(index)?.optString("id")?.let(::unpadded)
                if (!id.isNullOrEmpty()) add(id)
            }
        }
    }

    /**
     * FR-7. An excluded credential id the user already holds for this rp
     * refuses; the same `(rpId, username)` only warns. Pending records of any
     * vault count: the credential exists on this device either way.
     */
    fun conflict(
        options: PasskeyCreationOptions,
        cached: List<AndroidAutofillCredentialMetadata>,
        pending: List<PendingPasskeyMetadata>,
    ): PasskeyCreationConflict {
        val rpId = options.rpId
        val cachedForRp = cached.flatMap { record ->
            record.passkeys.filter { it.rpId.equals(rpId, ignoreCase = true) }.map { record to it }
        }
        val pendingForRp = pending.filter { it.rpId.equals(rpId, ignoreCase = true) }

        val excluded = options.excludeCredentialIds
        if (excluded.isNotEmpty() &&
            (cachedForRp.any { unpadded(it.second.credentialId) in excluded } ||
                pendingForRp.any { unpadded(it.credentialId) in excluded })
        ) {
            return PasskeyCreationConflict.ExcludedCredential
        }

        val name = options.userName
        if (cachedForRp.any { it.first.username.equals(name, ignoreCase = true) } ||
            pendingForRp.any { it.username.equals(name, ignoreCase = true) }
        ) {
            return PasskeyCreationConflict.SameAccount
        }
        return PasskeyCreationConflict.None
    }

    /**
     * FR-10. Cached passkeys and pending records for [rpId], filtered by
     * [allowed] (empty means any). Nothing is offered without a published
     * cache; a pending record is offered only for the published vault, and
     * not twice when the vault already holds the same credential.
     */
    fun offers(
        rpId: String,
        allowed: Set<String>,
        publishedDatabaseId: String?,
        cached: List<AndroidAutofillCredentialMetadata>,
        pending: List<PendingPasskeyMetadata>,
    ): List<PasskeyOffer> {
        if (publishedDatabaseId.isNullOrEmpty() || rpId.isEmpty()) return emptyList()
        val allowedIds = allowed.map(::unpadded).toSet()
        fun isAllowed(id: String) = allowedIds.isEmpty() || unpadded(id) in allowedIds

        val offers = mutableListOf<PasskeyOffer>()
        for (record in cached) {
            // One row per record, as before 024: the first matching passkey.
            val passkey = record.passkeys.firstOrNull {
                it.rpId.equals(rpId, ignoreCase = true) && isAllowed(it.credentialId)
            } ?: continue
            offers += PasskeyOffer(
                entryId = record.id,
                pendingRecordId = null,
                rpId = passkey.rpId,
                credentialId = passkey.credentialId,
                username = record.username.ifEmpty { record.title },
                displayName = record.title,
            )
        }
        val cachedIds = cached.flatMap { record ->
            record.passkeys.filter { it.rpId.equals(rpId, ignoreCase = true) }
                .map { unpadded(it.credentialId) }
        }.toSet()
        for (record in pending) {
            if (record.databaseId != publishedDatabaseId) continue
            if (!record.rpId.equals(rpId, ignoreCase = true)) continue
            if (!isAllowed(record.credentialId)) continue
            if (unpadded(record.credentialId) in cachedIds) continue
            offers += PasskeyOffer(
                entryId = null,
                pendingRecordId = record.recordId,
                rpId = record.rpId,
                credentialId = record.credentialId,
                username = record.username,
                displayName = record.rpId,
            )
        }
        return offers
    }

    /**
     * The signing key of one pending record, under the same rules as
     * [offers]: same published vault, same rp, the credential the sheet named.
     */
    fun pendingPasskey(
        records: List<PendingPasskeyRecord>,
        publishedDatabaseId: String?,
        recordId: String,
        rpId: String,
        credentialId: String?,
    ): AndroidAutofillPasskey? {
        if (publishedDatabaseId.isNullOrEmpty()) return null
        val record = records.firstOrNull {
            it.recordId == recordId &&
                it.databaseId == publishedDatabaseId &&
                it.rpId.equals(rpId, ignoreCase = true) &&
                (credentialId == null || unpadded(it.credentialId) == unpadded(credentialId))
        } ?: return null
        val algorithm = AndroidPasskeyAlgorithm.fromRawValue(record.algorithm) ?: return null
        return AndroidAutofillPasskey(
            rpId = record.rpId,
            credentialId = record.credentialId,
            userHandle = record.userHandle,
            username = record.username,
            privateKeyPem = record.privateKeyPem,
            algorithm = algorithm,
            backupEligible = record.be,
            backupState = record.bs,
        )
    }

    private fun unpadded(value: String): String = value.trim().trimEnd('=')
}
