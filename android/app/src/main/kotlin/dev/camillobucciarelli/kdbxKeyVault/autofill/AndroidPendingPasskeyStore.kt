package dev.camillobucciarelli.kdbxKeyVault.autofill

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Log
import java.io.File
import java.io.FileOutputStream
import java.security.KeyStore
import java.security.SecureRandom
import java.util.Base64
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import org.json.JSONObject

/** spec 024 T020. One decrypted queue record. The PEM is the secret. */
internal data class PendingPasskeyRecord(
    val recordId: String,
    val databaseId: String,
    val createdAtEpochMs: Long,
    val rpId: String,
    val credentialId: String,
    val userHandle: String?,
    val username: String,
    val displayName: String?,
    val privateKeyPem: String,
    val algorithm: String,
    val be: Boolean,
    val bs: Boolean,
    val origin: String,
) {
    override fun toString(): String = "PendingPasskeyRecord(recordId=$recordId, rpId=$rpId)"

    fun metadata() = PendingPasskeyMetadata(recordId, databaseId, createdAtEpochMs, rpId, credentialId, username)
}

/**
 * The plaintext envelope fields: enough to list and match a record without
 * the key. Authenticated only when the record is opened, so never sign from it.
 */
internal data class PendingPasskeyMetadata(
    val recordId: String,
    val databaseId: String,
    val createdAtEpochMs: Long,
    val rpId: String,
    val credentialId: String,
    val username: String,
)

internal class PendingPasskeyReadResult(
    val records: List<PendingPasskeyRecord>,
    val unreadableCount: Int,
)

/**
 * Pure JVM part of the pending queue format v1: AAD, payload JSON, envelope,
 * AES-256-GCM given a [SecretKey]. Exceptions carry fixed messages only
 * (org.json messages can echo content, so they are never propagated).
 */
internal object PendingPasskeyCodec {
    const val VERSION = 1
    const val ALGORITHM = "AES-256-GCM"
    const val KEY_ID = "passkey-pending-v1"
    private const val NONCE_BYTES = 12
    private const val TAG_BITS = 128

    class Unreadable : Exception("pending passkey record unreadable")

    /** The username is base64url so a "|" in it cannot make two envelopes share an AAD. */
    fun aad(
        recordId: String,
        databaseId: String,
        createdAtEpochMs: Long,
        rpId: String,
        credentialId: String,
        username: String,
    ): ByteArray {
        val usernameB64 = Base64.getUrlEncoder().withoutPadding()
            .encodeToString(username.toByteArray(Charsets.UTF_8))
        return "$VERSION|$recordId|$databaseId|$createdAtEpochMs|$rpId|$credentialId|$usernameB64"
            .toByteArray(Charsets.UTF_8)
    }

    private fun aad(m: PendingPasskeyMetadata) =
        aad(m.recordId, m.databaseId, m.createdAtEpochMs, m.rpId, m.credentialId, m.username)

    /** Compact, fixture key order, "/" not escaped, absent optionals as null. */
    fun payloadJson(r: PendingPasskeyRecord): String = buildString {
        fun s(v: String?) = if (v == null) append("null") else quote(v, this)
        append("{\"rpId\":"); s(r.rpId)
        append(",\"credentialId\":"); s(r.credentialId)
        append(",\"userHandle\":"); s(r.userHandle)
        append(",\"username\":"); s(r.username)
        append(",\"displayName\":"); s(r.displayName)
        append(",\"privateKeyPem\":"); s(r.privateKeyPem)
        append(",\"algorithm\":"); s(r.algorithm)
        append(",\"be\":").append(r.be)
        append(",\"bs\":").append(r.bs)
        append(",\"origin\":"); s(r.origin)
        append('}')
    }

    private fun quote(v: String, out: StringBuilder) {
        out.append('"')
        for (c in v) when {
            c == '"' -> out.append("\\\"")
            c == '\\' -> out.append("\\\\")
            c == '\n' -> out.append("\\n")
            c == '\r' -> out.append("\\r")
            c == '\t' -> out.append("\\t")
            c < ' ' -> out.append("\\u%04x".format(c.code))
            else -> out.append(c)
        }
        out.append('"')
    }

    /** [nonce] null lets the cipher pick one (required for AndroidKeyStore keys). */
    fun seal(key: SecretKey, aad: ByteArray, plaintext: ByteArray, nonce: ByteArray? = null): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        if (nonce == null) {
            cipher.init(Cipher.ENCRYPT_MODE, key)
        } else {
            cipher.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(TAG_BITS, nonce))
        }
        cipher.updateAAD(aad)
        val body = cipher.doFinal(plaintext)
        return Base64.getEncoder().encodeToString(cipher.iv + body)
    }

    fun unseal(key: SecretKey, aad: ByteArray, sealed: String): ByteArray = try {
        val raw = Base64.getDecoder().decode(sealed)
        if (raw.size < NONCE_BYTES + TAG_BITS / 8) throw Unreadable()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            key,
            GCMParameterSpec(TAG_BITS, raw.copyOfRange(0, NONCE_BYTES)),
        )
        cipher.updateAAD(aad)
        cipher.doFinal(raw, NONCE_BYTES, raw.size - NONCE_BYTES)
    } catch (e: Exception) {
        throw Unreadable()
    }

    fun envelopeJson(r: PendingPasskeyRecord, sealed: String): String = JSONObject()
        .put("version", VERSION)
        .put("algorithm", ALGORITHM)
        .put("keyId", KEY_ID)
        .put("recordId", r.recordId)
        .put("databaseId", r.databaseId)
        .put("createdAtEpochMs", r.createdAtEpochMs)
        .put("rpId", r.rpId)
        .put("credentialId", r.credentialId)
        .put("username", r.username)
        .put("sealed", sealed)
        .toString()

    fun seal(key: SecretKey, r: PendingPasskeyRecord, nonce: ByteArray? = null): String = envelopeJson(
        r,
        seal(key, aad(r.metadata()), payloadJson(r).toByteArray(Charsets.UTF_8), nonce),
    )

    private fun JSONObject.str(name: String): String = get(name) as? String ?: throw Unreadable()

    private fun parse(envelopeText: String, expectedRecordId: String): Pair<PendingPasskeyMetadata, String> = try {
        val env = JSONObject(envelopeText)
        val m = PendingPasskeyMetadata(
            recordId = env.str("recordId"),
            databaseId = env.str("databaseId"),
            createdAtEpochMs = (env.get("createdAtEpochMs") as? Number)?.toLong() ?: throw Unreadable(),
            rpId = env.str("rpId"),
            credentialId = env.str("credentialId"),
            username = env.str("username"),
        )
        if ((env.get("version") as? Number)?.toInt() != VERSION || env.str("algorithm") != ALGORITHM ||
            env.str("keyId") != KEY_ID || m.recordId != expectedRecordId
        ) throw Unreadable()
        m to env.str("sealed")
    } catch (e: Exception) {
        throw Unreadable()
    }

    /** Envelope fields only: no key, no decryption, nothing authenticated. */
    fun metadata(envelopeText: String, expectedRecordId: String): PendingPasskeyMetadata =
        parse(envelopeText, expectedRecordId).first

    /** Parses and authenticates an envelope; [expectedRecordId] is the file name. */
    fun open(key: SecretKey, envelopeText: String, expectedRecordId: String): PendingPasskeyRecord = try {
        val (m, sealed) = parse(envelopeText, expectedRecordId)
        val plain = unseal(key, aad(m), sealed)
        val p = JSONObject(String(plain, Charsets.UTF_8))
        // The payload must agree with the (authenticated) plaintext fields.
        if (p.getString("rpId") != m.rpId || p.getString("credentialId") != m.credentialId ||
            p.getString("username") != m.username
        ) throw Unreadable()
        PendingPasskeyRecord(
            recordId = m.recordId,
            databaseId = m.databaseId,
            createdAtEpochMs = m.createdAtEpochMs,
            rpId = m.rpId,
            credentialId = m.credentialId,
            userHandle = if (p.isNull("userHandle")) null else p.getString("userHandle"),
            username = m.username,
            displayName = if (p.isNull("displayName")) null else p.getString("displayName"),
            privateKeyPem = p.getString("privateKeyPem"),
            algorithm = p.getString("algorithm"),
            be = p.getBoolean("be"),
            bs = p.getBoolean("bs"),
            origin = p.getString("origin"),
        )
    } catch (e: Exception) {
        throw Unreadable()
    }
}

/**
 * Android-only layer: files under `autofill_v2/passkey_pending_v1/` and an own
 * AndroidKeyStore key. [AndroidAutofillStore.clearCredentials] touches neither
 * (it deletes named cache files and its own alias only).
 */
internal class AndroidPendingPasskeyStore(
    context: Context,
    private val keyProvider: (create: Boolean) -> SecretKey? = ::keystoreKey,
) {
    private val directory = File(File(context.applicationContext.filesDir, "autofill_v2"), DIR_NAME)

    /** Writes atomically and reads back; throws (and removes the file) on any mismatch. */
    fun write(record: PendingPasskeyRecord) {
        require(isRecordId(record.recordId)) { "recordId must be a UUID" }
        check(directory.isDirectory || directory.mkdirs()) { "cannot create queue directory" }
        purgeStaleTemps(directory, System.currentTimeMillis())
        val key = keyProvider(true) ?: error("pending key unavailable")
        val target = File(directory, record.recordId + SUFFIX)
        val temp = File(directory, record.recordId + ".tmp")
        try {
            FileOutputStream(temp).use { out ->
                out.write(PendingPasskeyCodec.seal(key, record).toByteArray(Charsets.UTF_8))
                out.flush()
                out.fd.sync() // FR-5: on disk before the rename and before the site is told.
            }
            check(temp.renameTo(target)) { "cannot publish pending record" }
            syncDirectory()
            val back = PendingPasskeyCodec.open(key, target.readText(Charsets.UTF_8), record.recordId)
            check(back == record) { "pending record read-back mismatch" }
        } catch (e: Exception) {
            runCatching { temp.delete() }
            runCatching { target.delete() }
            Log.w(TAG, "pending passkey write failed recordId=${record.recordId} rpId=${record.rpId}")
            throw IllegalStateException("pending passkey write failed")
        }
        Log.i(TAG, "pending passkey queued recordId=${record.recordId} rpId=${record.rpId}")
    }

    /** Best effort: persists the rename itself where the platform allows opening a directory. */
    private fun syncDirectory() {
        runCatching {
            android.system.Os.open(directory.path, android.system.OsConstants.O_RDONLY, 0).let { fd ->
                try { android.system.Os.fsync(fd) } finally { android.system.Os.close(fd) }
            }
        }
    }

    private fun files() = directory.listFiles { f -> f.isFile && f.name.endsWith(SUFFIX) }.orEmpty().sortedBy { it.name }

    /** Record files, readable or not, for all vaults. No key access, no decryption. */
    fun count(): Int = files().size

    /** Listing and matching only: no key access, no decryption. Invalid envelopes are skipped. */
    fun readMetadata(): List<PendingPasskeyMetadata> = files().mapNotNull { file ->
        val id = file.name.removeSuffix(SUFFIX)
        if (!isRecordId(id)) null else runCatching {
            PendingPasskeyCodec.metadata(file.readText(Charsets.UTF_8), id)
        }.getOrNull()
    }

    /** One authenticated, decrypted record, or null. Call only after user verification. */
    fun readRecord(recordId: String): PendingPasskeyRecord? {
        if (!isRecordId(recordId)) return null
        val key = runCatching { keyProvider(false) }.getOrNull() ?: return null
        return runCatching {
            PendingPasskeyCodec.open(key, File(directory, recordId + SUFFIX).readText(Charsets.UTF_8), recordId)
        }.getOrNull()
    }

    /** Unauthenticated or malformed records are counted, never deleted or logged. */
    fun read(): PendingPasskeyReadResult {
        val files = files()
        if (files.isEmpty()) return PendingPasskeyReadResult(emptyList(), 0)
        val key = runCatching { keyProvider(false) }.getOrNull()
        val records = mutableListOf<PendingPasskeyRecord>()
        var unreadable = 0
        for (file in files) {
            val id = file.name.removeSuffix(SUFFIX)
            val record = if (key == null || !isRecordId(id)) null else runCatching {
                PendingPasskeyCodec.open(key, file.readText(Charsets.UTF_8), id)
            }.getOrNull()
            if (record == null) unreadable += 1 else records += record
        }
        return PendingPasskeyReadResult(records, unreadable)
    }

    /** True when the file is gone afterwards (including already absent). */
    fun resolve(recordId: String): Boolean {
        require(isRecordId(recordId)) { "recordId must be a UUID" }
        val file = File(directory, recordId + SUFFIX)
        val gone = !file.exists() || file.delete()
        Log.i(TAG, "pending passkey resolved recordId=$recordId gone=$gone")
        return gone
    }

    companion object {
        const val DIR_NAME = "passkey_pending_v1"
        private const val SUFFIX = ".sealed.json"
        private const val TAG = "CustodeAutofill"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val KEY_ALIAS = "dev.camillobucciarelli.keyvault.passkey_pending_v1"

        fun isRecordId(value: String): Boolean = try {
            UUID.fromString(value).toString() == value.lowercase()
        } catch (e: IllegalArgumentException) {
            false
        }

        private const val STALE_TEMP_MS = 10 * 60 * 1000L

        /**
         * Removes `.tmp` leftovers of a crash between create and rename, once
         * older than [STALE_TEMP_MS]. Never touches `.sealed.json` records.
         */
        internal fun purgeStaleTemps(directory: File, nowMs: Long, maxAgeMs: Long = STALE_TEMP_MS): Int =
            directory.listFiles { f -> f.isFile && f.name.endsWith(".tmp") }.orEmpty()
                .count { nowMs - it.lastModified() > maxAgeMs && it.delete() }

        fun newRecordId(): String = UUID.randomUUID().toString()

        private fun keystoreKey(create: Boolean): SecretKey? {
            val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
            (keyStore.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
            if (!create) return null
            val spec = KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setRandomizedEncryptionRequired(true)
                .build()
            return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
                .apply { init(spec) }.generateKey()
        }
    }
}
