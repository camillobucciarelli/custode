package dev.camillobucciarelli.kdbxKeyVault.autofill

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** spec 024 T022 (parse, FR-4, FR-7) and T023 (FR-10 merge). */
class PasskeyProviderLogicTest {
    private val db = "sha256:abc"

    private fun createJson(params: String? = """[{"type":"public-key","alg":-7}]""", exclude: String = "[]") =
        """{"rp":{"id":"Example.com","name":"Ex"},"challenge":"Y2g","user":{"id":"dXNlcg==","name":"alice","displayName":"Alice"},""" +
            (if (params == null) "" else """"pubKeyCredParams":$params,""") +
            """"excludeCredentials":$exclude}"""

    private fun cached(id: String, username: String, rpId: String, credentialId: String) =
        AndroidAutofillCredentialMetadata(
            id = id, title = "T-$id", username = username, displayService = rpId,
            serviceIdentifiers = emptyList(), updatedAtEpochMs = 0,
            passkeys = listOf(AndroidAutofillPasskeyMetadata(rpId, credentialId)),
        )

    private fun pending(recordId: String, credentialId: String, rpId: String = "example.com", databaseId: String = db, username: String = "bob") =
        pendingRecord(recordId, credentialId, rpId, databaseId, username).metadata()

    private fun pendingRecord(recordId: String, credentialId: String, rpId: String = "example.com", databaseId: String = db, username: String = "bob") =
        PendingPasskeyRecord(
            recordId = recordId, databaseId = databaseId, createdAtEpochMs = 1, rpId = rpId,
            credentialId = credentialId, userHandle = "dQ", username = username, displayName = null,
            privateKeyPem = "SENTINEL", algorithm = "ES256", be = true, bs = true, origin = "https://example.com",
        )

    @Test
    fun parsesCreationRequest() {
        val o = PasskeyProviderLogic.parseCreation(createJson())!!
        assertEquals("example.com", o.rpId)
        assertEquals("Y2g", o.challenge)
        assertEquals("dXNlcg", o.userHandle)
        assertEquals("alice", o.userName)
        assertEquals("Alice", o.userDisplayName)
        assertTrue(o.offersEs256)
    }

    @Test
    fun rejectsMalformedOrIncompleteRequests() {
        assertNull(PasskeyProviderLogic.parseCreation("not json"))
        assertNull(PasskeyProviderLogic.parseCreation("""{"challenge":"x"}"""))
        assertNull(PasskeyProviderLogic.parseCreation("""{"rp":{"id":"a.com"}}"""))
    }

    @Test
    fun es256Gate() {
        assertFalse(PasskeyProviderLogic.parseCreation(createJson("""[{"type":"public-key","alg":-257},{"type":"public-key","alg":-8}]"""))!!.offersEs256)
        assertTrue(PasskeyProviderLogic.parseCreation(createJson("""[{"type":"public-key","alg":-8},{"type":"public-key","alg":-7}]"""))!!.offersEs256)
        // WebAuthn: absent or empty params mean ES256 and RS256.
        assertTrue(PasskeyProviderLogic.parseCreation(createJson(null))!!.offersEs256)
        assertTrue(PasskeyProviderLogic.parseCreation(createJson("[]"))!!.offersEs256)
        assertFalse(PasskeyProviderLogic.offersEs256("""{"pubKeyCredParams":[{"type":"public-key"}]}"""))
        assertFalse(PasskeyProviderLogic.offersEs256("garbage"))
    }

    @Test
    fun exclusionRefusesOnCachedOrPendingIdAndWarnsOnSameAccount() {
        val excludeCached = PasskeyProviderLogic.parseCreation(createJson(exclude = """[{"type":"public-key","id":"Q0lE"}]"""))!!
        val cachedHit = listOf(cached("e1", "carol", "example.com", "Q0lE"))
        assertEquals(PasskeyCreationConflict.ExcludedCredential, PasskeyProviderLogic.conflict(excludeCached, cachedHit, emptyList()))
        // Same id under another rp is not a match.
        assertEquals(PasskeyCreationConflict.None, PasskeyProviderLogic.conflict(excludeCached, listOf(cached("e1", "carol", "other.com", "Q0lE")), emptyList()))
        // Pending record of any vault counts, padding ignored.
        val excludePadded = PasskeyProviderLogic.parseCreation(createJson(exclude = """[{"type":"public-key","id":"UA=="}]"""))!!
        assertEquals(PasskeyCreationConflict.ExcludedCredential, PasskeyProviderLogic.conflict(excludePadded, emptyList(), listOf(pending("r1", "UA", databaseId = "sha256:other"))))

        val plain = PasskeyProviderLogic.parseCreation(createJson())!!
        assertEquals(PasskeyCreationConflict.SameAccount, PasskeyProviderLogic.conflict(plain, listOf(cached("e1", "Alice", "example.com", "X")), emptyList()))
        assertEquals(PasskeyCreationConflict.SameAccount, PasskeyProviderLogic.conflict(plain, emptyList(), listOf(pending("r1", "X", username = "alice"))))
        assertEquals(PasskeyCreationConflict.None, PasskeyProviderLogic.conflict(plain, listOf(cached("e1", "alice", "other.com", "X")), emptyList()))
    }

    @Test
    fun offersMergeCachedAndPendingWithoutDuplicates() {
        val cachedList = listOf(cached("e1", "alice", "example.com", "Q0lE"))
        val pendingList = listOf(
            pending("r-dup", "Q0lE"), // also cached: offered once, as cached
            pending("r-new", "TkVX"),
            pending("r-otherdb", "T0RC", databaseId = "sha256:other"),
            pending("r-otherrp", "T1JQ", rpId = "other.com"),
        )
        val offers = PasskeyProviderLogic.offers("example.com", emptySet(), db, cachedList, pendingList)
        assertEquals(listOf("e1" to null, null to "r-new"), offers.map { it.entryId to it.pendingRecordId })
        assertEquals("bob", offers[1].username)
        assertEquals("example.com", offers[1].displayName)
    }

    @Test
    fun offersHonourAllowCredentialsAndPublishedCache() {
        val cachedList = listOf(cached("e1", "alice", "example.com", "Q0lE"))
        val pendingList = listOf(pending("r-new", "TkVX"))
        val onlyPending = PasskeyProviderLogic.offers("example.com", setOf("TkVX=="), db, cachedList, pendingList)
        assertEquals(listOf("r-new"), onlyPending.map { it.pendingRecordId })
        assertTrue(PasskeyProviderLogic.offers("example.com", emptySet(), null, cachedList, pendingList).isEmpty())
        assertTrue(PasskeyProviderLogic.offers("", emptySet(), db, cachedList, pendingList).isEmpty())
    }

    @Test
    fun pendingPasskeyResolvesOnlyUnderSameRules() {
        val records = listOf(pendingRecord("r1", "TkVX"))
        val key = PasskeyProviderLogic.pendingPasskey(records, db, "r1", "Example.com", "TkVX")!!
        assertEquals(AndroidPasskeyAlgorithm.Es256, key.algorithm)
        assertTrue(key.backupEligible && key.backupState)
        assertEquals("dQ", key.userHandle)
        assertFalse(key.toString().contains("SENTINEL"))
        assertNull(PasskeyProviderLogic.pendingPasskey(records, null, "r1", "example.com", "TkVX"))
        assertNull(PasskeyProviderLogic.pendingPasskey(records, "sha256:other", "r1", "example.com", "TkVX"))
        assertNull(PasskeyProviderLogic.pendingPasskey(records, db, "r1", "other.com", "TkVX"))
        assertNull(PasskeyProviderLogic.pendingPasskey(records, db, "r1", "example.com", "WFhY"))
        assertNull(PasskeyProviderLogic.pendingPasskey(records, db, "r2", "example.com", null))
    }
}
