package dev.camillobucciarelli.kdbxKeyVault.autofill

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import org.json.JSONObject

internal class AndroidAutofillStore(context: Context) {
    private val appContext = context.applicationContext
    private val directory = File(appContext.filesDir, "autofill_v2")
    private val metadataFile = File(directory, "android_autofill_metadata_v2.json")
    private val encryptedFile = File(directory, "android_autofill_cache_v2.sealed.json")
    private val pendingAssociationsFile = File(directory, "android_autofill_pending_associations_v2.json")
    private val authSessionFile = File(directory, "android_autofill_session_v2.json")
    private val declinedSavesFile = File(directory, "android_autofill_declined_saves_v2.json")

    fun publishCredentials(
        databaseId: String,
        entries: List<AndroidAutofillPublishEntry>,
        authSessionTtlMs: Long = 0L,
    ): Map<String, Any> {
        val normalizedDatabaseId = databaseId.trim()
        require(normalizedDatabaseId.isNotEmpty()) { "databaseId is required" }
        require(entries.size <= MAX_ENTRIES) { "entries exceeds maximum" }
        require(authSessionTtlMs >= 0L) { "authSessionTtlMs must not be negative" }

        val generatedAt = System.currentTimeMillis()
        val seenIds = mutableSetOf<String>()
        val metadataEntries = mutableListOf<AndroidAutofillCredentialMetadata>()
        val secretEntries = mutableListOf<AndroidAutofillCredentialSecret>()
        var skippedCount = 0
        val warnings = sortedSetOf<String>()

        for (entry in entries) {
            val id = entry.id.trim()
            if (id.isEmpty()) {
                skippedCount += 1
                warnings.add("entry_without_id_skipped")
                continue
            }
            if (!seenIds.add(id)) {
                skippedCount += 1
                warnings.add("duplicate_entry_id_skipped")
                continue
            }
            // spec 023: a passkey-only record has nothing to fill but
            // something to sign with, so an empty password no longer
            // disqualifies it. A record with neither is still nothing to
            // publish.
            val passkeys = entry.passkeys.filter { it.rpId.isNotEmpty() }
            if (entry.password.isEmpty() && passkeys.isEmpty()) {
                skippedCount += 1
                warnings.add("entry_without_password_skipped")
                continue
            }

            val identifiers = AndroidAutofillNormalizer.normalizedServiceIdentifiers(
                url = entry.url,
                provided = entry.serviceIdentifiers,
            )
            val username = entry.username.trim().take(MAX_METADATA_LENGTH)
            val rawTitle = entry.title.trim().take(MAX_METADATA_LENGTH)
            val displayService = AndroidAutofillNormalizer.displayService(identifiers)
            val title = rawTitle.ifEmpty { displayService.ifEmpty { "Untitled" } }

            metadataEntries.add(
                AndroidAutofillCredentialMetadata(
                    id = id,
                    title = title,
                    username = username,
                    displayService = displayService,
                    serviceIdentifiers = identifiers,
                    updatedAtEpochMs = generatedAt,
                    passkeys = passkeys.map {
                        AndroidAutofillPasskeyMetadata(
                            rpId = it.rpId,
                            credentialId = it.credentialId,
                        )
                    },
                    hasPassword = entry.password.isNotEmpty(),
                ),
            )
            secretEntries.add(
                AndroidAutofillCredentialSecret(
                    id = id,
                    username = username,
                    password = entry.password,
                    passkeys = passkeys,
                ),
            )
        }

        val sortedMetadata = metadataEntries.sortedBy { it.sortKey }
        if (sortedMetadata.isEmpty()) {
            clearAuthSessionBestEffort()
            removeCacheFilesBestEffort()
            val keyCleared = deleteKeyBestEffort()
            if (!keyCleared) {
                warnings.add("keystore_key_not_cleared")
            }
            return mapOf(
                "publishedCount" to 0,
                "skippedCount" to skippedCount,
                "identityCount" to 0,
                "identityStoreSynced" to false,
                "passkeyPublishedCount" to 0,
                "warnings" to warnings.toList(),
            )
        }

        val metadata = AndroidAutofillMetadataCache(
            version = ANDROID_AUTOFILL_CACHE_VERSION,
            databaseId = normalizedDatabaseId,
            generatedAtEpochMs = generatedAt,
            entries = sortedMetadata,
        )
        val metadataBytes = AndroidAutofillJson.metadataCacheToJson(metadata).toByteArray(Charsets.UTF_8)
        val secretBytes = AndroidAutofillJson.secretsToJson(
            version = ANDROID_AUTOFILL_CACHE_VERSION,
            databaseId = normalizedDatabaseId,
            generatedAtEpochMs = generatedAt,
            entries = secretEntries,
        ).toByteArray(Charsets.UTF_8)

        directory.mkdirs()
        val envelope = encrypt(secretBytes, metadataBytes, normalizedDatabaseId, generatedAt)
        writePrivate(metadataFile, metadataBytes)
        writePrivate(encryptedFile, envelope.toByteArray(Charsets.UTF_8))
        // A fresh cache always starts unauthenticated.
        writeAuthSession(AndroidAutofillAuthSession(authSessionTtlMs, null))

        Log.i(TAG, "Android Autofill cache published count=${sortedMetadata.size}")
        return mapOf(
            "publishedCount" to sortedMetadata.size,
            "skippedCount" to skippedCount,
            "identityCount" to sortedMetadata.size,
            "identityStoreSynced" to true,
            "passkeyPublishedCount" to sortedMetadata.sumOf { it.passkeys.size },
            "warnings" to warnings.toList(),
        )
    }

    fun clearCredentials(databaseId: String?): Map<String, Any> {
        val pendingCleared = clearPendingAssociationsBestEffort()
        val currentDatabaseId = readMetadataCache()?.databaseId
        val requestedDatabaseId = databaseId?.trim()?.takeIf { it.isNotEmpty() }
        if (requestedDatabaseId != null && currentDatabaseId != null && requestedDatabaseId != currentDatabaseId) {
            val warnings = mutableListOf("database_id_mismatch")
            if (!pendingCleared) {
                warnings.add("pending_associations_not_cleared")
            }
            return mapOf(
                "cleared" to false,
                "identityStoreCleared" to false,
                "keychainKeyCleared" to false,
                "warnings" to warnings,
            )
        }

        clearAuthSessionBestEffort()
        // Declines hold usernames; clearing the cache forgets them too.
        runCatching { declinedSavesFile.delete() }
        removeCacheFilesBestEffort()
        val keyCleared = deleteKeyBestEffort()
        val warnings = mutableListOf<String>()
        if (!pendingCleared) {
            warnings.add("pending_associations_not_cleared")
        }
        if (!keyCleared) {
            warnings.add("keystore_key_not_cleared")
        }
        return mapOf(
            "cleared" to true,
            "identityStoreCleared" to true,
            "keychainKeyCleared" to keyCleared,
            "warnings" to warnings,
        )
    }

    fun status(): AndroidAutofillStoreStatus {
        val metadata = readMetadataCache()
        val encryptedExists = encryptedFile.exists()
        val session = readAuthSession()
        return AndroidAutofillStoreStatus(
            metadataCount = metadata?.entries?.size ?: 0,
            encryptedCacheAvailable = encryptedExists,
            cacheAvailable = metadata != null && encryptedExists,
            databaseId = metadata?.databaseId,
            generatedAtEpochMs = metadata?.generatedAtEpochMs,
            authSessionTtlMs = session.authSessionTtlMs,
            lastAuthenticatedAtEpochMs = session.lastAuthenticatedAtEpochMs,
        )
    }

    fun readAuthSession(): AndroidAutofillAuthSession {
        return runCatching {
            if (!authSessionFile.exists()) {
                null
            } else {
                AndroidAutofillJson.authSessionFromJson(authSessionFile.readText(Charsets.UTF_8))
            }
        }.getOrNull() ?: EMPTY_AUTH_SESSION
    }

    /** Stamps a successful device authentication. Best effort: a failure only costs an extra prompt. */
    fun recordAuthentication(nowEpochMs: Long) {
        runCatching {
            writeAuthSession(readAuthSession().copy(lastAuthenticatedAtEpochMs = nowEpochMs))
        }.onFailure {
            Log.w(TAG, "Auth session stamp failed: ${it.javaClass.simpleName}")
        }
    }

    private fun writeAuthSession(session: AndroidAutofillAuthSession) {
        directory.mkdirs()
        writePrivate(
            authSessionFile,
            AndroidAutofillJson.authSessionToJson(session).toByteArray(Charsets.UTF_8),
        )
    }

    private fun clearAuthSessionBestEffort() {
        runCatching { authSessionFile.delete() }
    }

    /**
     * Remembers that the user declined this save, so the same submission is not
     * offered again (FR-011). Records the association and the username only.
     */
    fun recordDeclinedSave(association: String?, username: String) {
        val normalizedAssociation = association?.trim().orEmpty()
        if (normalizedAssociation.isEmpty()) {
            return
        }
        runCatching {
            val key = AndroidAutofillDeclinedSave.keyOf(normalizedAssociation, username)
            val records = readDeclinedSaves()
                .filterNot { AndroidAutofillDeclinedSave.keyOf(it.association, it.username) == key }
                .plus(
                    AndroidAutofillDeclinedSave(
                        association = normalizedAssociation,
                        username = username.trim(),
                        declinedAtEpochMs = System.currentTimeMillis(),
                    ),
                )
                .takeLast(MAX_DECLINED_SAVES)
            directory.mkdirs()
            writePrivate(
                declinedSavesFile,
                AndroidAutofillJson.declinedSavesToJson(records).toByteArray(Charsets.UTF_8),
            )
        }.onFailure {
            Log.w(TAG, "Declined save record failed: ${it.javaClass.simpleName}")
        }
    }

    fun isDeclinedSave(association: String?, username: String): Boolean {
        if (association?.trim().isNullOrEmpty()) {
            return false
        }
        val key = AndroidAutofillDeclinedSave.keyOf(association, username)
        return readDeclinedSaves().any {
            AndroidAutofillDeclinedSave.keyOf(it.association, it.username) == key
        }
    }

    fun readDeclinedSaves(): List<AndroidAutofillDeclinedSave> {
        return runCatching {
            if (!declinedSavesFile.exists()) {
                emptyList()
            } else {
                AndroidAutofillJson.declinedSavesFromJson(declinedSavesFile.readText(Charsets.UTF_8))
            }
        }.getOrDefault(emptyList())
    }

    fun readCredentialMetadata(): List<AndroidAutofillCredentialMetadata> {
        return readMetadataCache()?.entries.orEmpty()
    }

    fun readCredentialSecret(id: String): AndroidAutofillCredentialSecret? {
        val metadataBytes = metadataFile.takeIf { it.exists() }?.readBytes() ?: return null
        val metadata = AndroidAutofillJson.metadataCacheFromJson(metadataBytes.toString(Charsets.UTF_8))
        val envelope = encryptedFile.takeIf { it.exists() }?.readText(Charsets.UTF_8) ?: return null
        val plaintext = decrypt(envelope, metadataBytes)
        val (version, databaseId, secrets) = AndroidAutofillJson.secretsFromJson(
            plaintext.toString(Charsets.UTF_8),
        )
        if (version != ANDROID_AUTOFILL_CACHE_VERSION || databaseId != metadata.databaseId) {
            return null
        }
        return secrets.firstOrNull { it.id == id }
    }

    fun readPendingAssociations(): List<AndroidAutofillPendingAssociation> {
        return runCatching { loadPendingAssociations() }
            .onFailure { Log.w(TAG, "Pending association read failed: ${it.javaClass.simpleName}") }
            .getOrDefault(emptyList())
    }

    fun clearPendingAssociations(ids: List<String>? = null): Int {
        if (!pendingAssociationsFile.exists()) {
            return 0
        }
        if (ids == null) {
            val count = loadPendingAssociations().size
            pendingAssociationsFile.delete()
            return count
        }

        val idsToClear = ids.map { it.trim() }.filter { it.isNotEmpty() }.toSet()
        if (idsToClear.isEmpty()) {
            return 0
        }
        val associations = loadPendingAssociations()
        val remaining = associations.filterNot { it.id in idsToClear }
        val cleared = associations.size - remaining.size
        if (cleared > 0) {
            if (remaining.isEmpty()) {
                pendingAssociationsFile.delete()
            } else {
                writePendingAssociations(remaining)
            }
        }
        return cleared
    }

    fun savePendingAssociation(
        metadata: AndroidAutofillCredentialMetadata,
        requestedTargets: List<AndroidAutofillServiceIdentifier>,
    ) {
        val cache = readMetadataCache() ?: return
        val databaseId = cache.databaseId.trim()
        val entryId = metadata.id.trim()
        val target = requestedTargets.firstOrNull { it.value.isNotBlank() } ?: return
        if (databaseId.isEmpty() || entryId.isEmpty()) {
            return
        }
        val displayService = AndroidAutofillNormalizer.displayService(listOf(target)).ifEmpty { target.value }
        val pending = AndroidAutofillPendingAssociation(
            id = java.util.UUID.randomUUID().toString(),
            databaseId = databaseId,
            entryId = entryId,
            serviceIdentifierType = target.type.rawValue,
            serviceIdentifierValue = target.value,
            displayService = displayService,
            createdAtEpochMs = System.currentTimeMillis(),
        )

        runCatching {
            val associations = loadPendingAssociations()
                .filterNot {
                    it.databaseId == pending.databaseId &&
                        it.entryId == pending.entryId &&
                        it.serviceIdentifierType == pending.serviceIdentifierType &&
                        it.serviceIdentifierValue == pending.serviceIdentifierValue
                }
                .plus(pending)
                .takeLast(MAX_PENDING_ASSOCIATIONS)
            writePendingAssociations(associations)
            Log.i(TAG, "Android Autofill pending association saved count=${associations.size}")
        }.onFailure {
            Log.w(TAG, "Pending association save failed: ${it.javaClass.simpleName}")
        }
    }

    private fun readMetadataCache(): AndroidAutofillMetadataCache? {
        return runCatching {
            if (!metadataFile.exists()) {
                null
            } else {
                AndroidAutofillJson.metadataCacheFromJson(metadataFile.readText(Charsets.UTF_8))
                    .takeIf { it.version == ANDROID_AUTOFILL_CACHE_VERSION }
            }
        }.getOrNull()
    }

    private fun loadPendingAssociations(): List<AndroidAutofillPendingAssociation> {
        if (!pendingAssociationsFile.exists()) {
            return emptyList()
        }
        return AndroidAutofillJson.pendingAssociationsFromJson(
            pendingAssociationsFile.readText(Charsets.UTF_8),
        )
    }

    private fun writePendingAssociations(associations: List<AndroidAutofillPendingAssociation>) {
        directory.mkdirs()
        writePrivate(
            pendingAssociationsFile,
            AndroidAutofillJson.pendingAssociationsToJson(associations).toByteArray(Charsets.UTF_8),
        )
    }

    private fun clearPendingAssociationsBestEffort(): Boolean {
        return runCatching {
            clearPendingAssociations(ids = null)
            true
        }.getOrDefault(false)
    }

    private fun removeCacheFilesBestEffort() {
        runCatching { metadataFile.delete() }
        runCatching { encryptedFile.delete() }
    }

    private fun writePrivate(file: File, bytes: ByteArray) {
        directory.mkdirs()
        val tempFile = File(file.parentFile, "${file.name}.tmp")
        tempFile.writeBytes(bytes)
        if (file.exists()) {
            file.delete()
        }
        check(tempFile.renameTo(file)) { "Unable to replace autofill file" }
    }

    private fun encrypt(
        plaintext: ByteArray,
        metadataBytes: ByteArray,
        databaseId: String,
        generatedAtEpochMs: Long,
    ): String {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateSecretKey())
        cipher.updateAAD(metadataBytes)
        val ciphertext = cipher.doFinal(plaintext)
        return JSONObject()
            .put("version", ANDROID_AUTOFILL_CACHE_VERSION)
            .put("algorithm", "AES/GCM/NoPadding")
            .put("databaseId", databaseId)
            .put("generatedAtEpochMs", generatedAtEpochMs)
            .put("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
            .put("ciphertext", Base64.encodeToString(ciphertext, Base64.NO_WRAP))
            .toString()
    }

    private fun decrypt(envelopeValue: String, metadataBytes: ByteArray): ByteArray {
        val envelope = JSONObject(envelopeValue)
        if (envelope.optInt("version") != ANDROID_AUTOFILL_CACHE_VERSION) {
            throw IllegalStateException("Invalid cache version")
        }
        val iv = Base64.decode(envelope.getString("iv"), Base64.NO_WRAP)
        val ciphertext = Base64.decode(envelope.getString("ciphertext"), Base64.NO_WRAP)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, getOrCreateSecretKey(), GCMParameterSpec(GCM_TAG_LENGTH_BITS, iv))
        cipher.updateAAD(metadataBytes)
        return cipher.doFinal(ciphertext)
    }

    private fun getOrCreateSecretKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (keyStore.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.let {
            return it.secretKey
        }

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        val spec = KeyGenParameterSpec.Builder(
            KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setRandomizedEncryptionRequired(true)
            .build()
        generator.init(spec)
        return generator.generateKey()
    }

    private fun deleteKeyBestEffort(): Boolean {
        return runCatching {
            val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
            if (keyStore.containsAlias(KEY_ALIAS)) {
                keyStore.deleteEntry(KEY_ALIAS)
            }
            true
        }.getOrDefault(false)
    }

    private companion object {
        private val EMPTY_AUTH_SESSION = AndroidAutofillAuthSession(
            authSessionTtlMs = 0L,
            lastAuthenticatedAtEpochMs = null,
        )
        private const val TAG = "CustodeAutofill"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val KEY_ALIAS = "dev.camillobucciarelli.keyvault.android_autofill_v2"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val GCM_TAG_LENGTH_BITS = 128
        private const val MAX_ENTRIES = 10_000
        private const val MAX_METADATA_LENGTH = 512
        private const val MAX_PENDING_ASSOCIATIONS = 200
        private const val MAX_DECLINED_SAVES = 200
    }
}
