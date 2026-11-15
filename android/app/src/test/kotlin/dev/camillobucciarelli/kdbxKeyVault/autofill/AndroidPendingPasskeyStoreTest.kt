package dev.camillobucciarelli.kdbxKeyVault.autofill

import java.io.File
import javax.crypto.spec.SecretKeySpec
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** spec 024 T020, against test/fixtures/passkeys/pending_record_v1.json. */
class AndroidPendingPasskeyStoreTest {
    private val fixture = JSONObject(File(fixtureDir(), "pending_record_v1.json").readText())
    private val env = fixture.getJSONObject("envelope")

    private fun unhex(s: String) = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    private val key = SecretKeySpec(unhex(fixture.getString("aesKeyHex")), "AES")
    private val envelopeText = env.toString()
    private val id = env.getString("recordId")

    @Test
    fun aadMatchesFixture() {
        assertEquals(
            fixture.getString("aad"),
            String(
                PendingPasskeyCodec.aad(
                    id, env.getString("databaseId"), env.getLong("createdAtEpochMs"),
                    env.getString("rpId"), env.getString("credentialId"), env.getString("username"),
                ),
            ),
        )
        assertEquals(
            "a|b|c",
            String(java.util.Base64.getUrlDecoder().decode(
                String(PendingPasskeyCodec.aad(id, "d", 1, "r", "c", "a|b|c")).substringAfterLast('|'),
            )),
        )
    }

    @Test
    fun metadataReadsEnvelopeWithoutKey() {
        val m = PendingPasskeyCodec.metadata(envelopeText, id)
        assertEquals("example.com", m.rpId)
        assertEquals("alice", m.username)
        assertEquals(env.getString("credentialId"), m.credentialId)
        assertEquals(env.getLong("createdAtEpochMs"), m.createdAtEpochMs)
    }

    @Test
    fun metadataRejectsInvalidOrIncompleteEnvelopes() {
        for (bad in listOf("not json", JSONObject(envelopeText).apply { remove("rpId") }.toString(),
            JSONObject(envelopeText).apply { remove("username") }.toString(),
            JSONObject(envelopeText).put("version", 2).toString())) {
            try {
                PendingPasskeyCodec.metadata(bad, id)
                fail("expected Unreadable")
            } catch (e: PendingPasskeyCodec.Unreadable) {
            }
        }
    }

    @Test
    fun alteredPlaintextMetadataFailsAuthentication() {
        for (field in listOf("rpId", "credentialId", "username")) {
            try {
                PendingPasskeyCodec.open(key, JSONObject(envelopeText).put(field, "x").toString(), id)
                fail("expected Unreadable for $field")
            } catch (e: PendingPasskeyCodec.Unreadable) {
            }
        }
    }

    @Test
    fun payloadDisagreeingWithEnvelopeIsUnreadable() {
        val r = PendingPasskeyCodec.open(key, envelopeText, id)
        // Sealed under the envelope's AAD but with a payload for another rp.
        val other = r.copy(rpId = "evil.com")
        val sealed = PendingPasskeyCodec.seal(
            key,
            PendingPasskeyCodec.aad(id, r.databaseId, r.createdAtEpochMs, r.rpId, r.credentialId, r.username),
            PendingPasskeyCodec.payloadJson(other).toByteArray(),
        )
        try {
            PendingPasskeyCodec.open(key, PendingPasskeyCodec.envelopeJson(r, sealed), id)
            fail("expected Unreadable")
        } catch (e: PendingPasskeyCodec.Unreadable) {
        }
    }

    @Test
    fun opensFixtureAndReencodesPayloadByteForByte() {
        val r = PendingPasskeyCodec.open(key, envelopeText, id)
        assertEquals(fixture.getString("payloadJson"), PendingPasskeyCodec.payloadJson(r))
        assertEquals("example.com", r.rpId)
        assertTrue(r.be && r.bs)
    }

    @Test
    fun sealWithFixtureNonceReproducesSealedField() {
        val r = PendingPasskeyCodec.open(key, envelopeText, id)
        val sealed = PendingPasskeyCodec.seal(key, r, unhex(fixture.getString("nonceHex")))
        assertEquals(env.getString("sealed"), JSONObject(sealed).getString("sealed"))
    }

    @Test
    fun otherDatabaseIdFailsAuthentication() {
        val tampered = JSONObject(envelopeText).put("databaseId", "other").toString()
        try {
            PendingPasskeyCodec.open(key, tampered, id)
            fail("expected Unreadable")
        } catch (e: PendingPasskeyCodec.Unreadable) {
            assertFalse(e.message.orEmpty().contains("BEGIN"))
        }
    }

    @Test
    fun renamedRecordFails() {
        try {
            PendingPasskeyCodec.open(key, envelopeText, "00000000-0000-4000-8000-000000000002")
            fail("expected Unreadable")
        } catch (e: PendingPasskeyCodec.Unreadable) {
        }
    }

    @Test
    fun nullOptionalsRoundTripAndRecordIdValidation() {
        val r = PendingPasskeyCodec.open(key, envelopeText, id).copy(userHandle = null, displayName = null)
        val back = PendingPasskeyCodec.open(key, PendingPasskeyCodec.seal(key, r), id)
        assertEquals(r, back)
        assertTrue(AndroidPendingPasskeyStore.isRecordId(id))
        assertFalse(AndroidPendingPasskeyStore.isRecordId("../../etc/passwd"))
        assertFalse(r.toString().contains("PRIVATE"))
    }

    private fun fixtureDir(): File {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val c = File(dir, "test/fixtures/passkeys")
            if (c.isDirectory) return c
            dir = dir.parentFile
        }
        error("fixtures not found")
    }

    @Test
    fun purgeStaleTempsRemovesOnlyOldTmpFiles() {
        val dir = java.nio.file.Files.createTempDirectory("pending").toFile()
        try {
            val old = File(dir, "a.tmp").apply { writeText("x"); setLastModified(1_000) }
            val fresh = File(dir, "b.tmp").apply { writeText("x"); setLastModified(1_000_000) }
            val record = File(dir, "c.sealed.json").apply { writeText("x"); setLastModified(1_000) }
            val removed = AndroidPendingPasskeyStore.purgeStaleTemps(dir, nowMs = 1_000_000, maxAgeMs = 60_000)
            assertEquals(1, removed)
            assertFalse(old.exists())
            assertTrue(fresh.exists())
            assertTrue(record.exists())
        } finally {
            dir.deleteRecursively()
        }
    }
}
