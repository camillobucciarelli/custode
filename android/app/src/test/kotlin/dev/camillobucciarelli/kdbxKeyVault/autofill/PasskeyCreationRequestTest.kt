package dev.camillobucciarelli.kdbxKeyVault.autofill

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * spec 023 T805 — reading a site's `PublicKeyCredentialCreationOptionsJSON`:
 * the ES256 filter, and the refusal of a request with a required field
 * missing.
 */
class PasskeyCreationRequestTest {
    private fun request(
        rp: String? = """{"id":"WebAuthn.io","name":"WebAuthn"}""",
        user: String? = """{"id":"CQk","name":"ada","displayName":"Ada L."}""",
        challenge: String? = "\"Y2hhbGxlbmdl-_\"",
        params: String? = """[{"type":"public-key","alg":-7}]""",
        exclude: String? = null,
    ): String = listOfNotNull(
        exclude?.let { "\"excludeCredentials\":$it" },
        rp?.let { "\"rp\":$it" },
        user?.let { "\"user\":$it" },
        challenge?.let { "\"challenge\":$it" },
        params?.let { "\"pubKeyCredParams\":$it" },
    ).joinToString(prefix = "{", separator = ",", postfix = "}")

    @Test
    fun es256AmongOtherAlgorithmsIsAccepted() {
        val params = """[{"type":"public-key","alg":-257},{"type":"public-key","alg":-7}]"""

        assertTrue(PasskeyCreationRequest.supportsEs256(request(params = params)))
    }

    @Test
    fun aRequestWithoutEs256IsRefused() {
        val params = """[{"type":"public-key","alg":-257},{"type":"public-key","alg":-8}]"""

        assertFalse(PasskeyCreationRequest.supportsEs256(request(params = params)))
    }

    @Test
    fun absentNullOrEmptyParamsStateNoPreference() {
        assertTrue(PasskeyCreationRequest.supportsEs256(request(params = null)))
        assertTrue(PasskeyCreationRequest.supportsEs256(request(params = "null")))
        assertTrue(PasskeyCreationRequest.supportsEs256(request(params = "[]")))
    }

    @Test
    fun es256MustBeANumberOnAPublicKeyParam() {
        assertFalse(
            PasskeyCreationRequest.supportsEs256(
                request(params = """[{"type":"public-key","alg":"-7"}]"""),
            ),
        )
        assertFalse(
            PasskeyCreationRequest.supportsEs256(
                request(params = """[{"type":"something-else","alg":-7}]"""),
            ),
        )
        assertFalse(PasskeyCreationRequest.supportsEs256(request(params = """[-7]""")))
        assertFalse(PasskeyCreationRequest.supportsEs256(request(params = """{"alg":-7}""")))
        assertTrue(PasskeyCreationRequest.supportsEs256(request(params = """[{"alg":-7}]""")))
    }

    @Test
    fun malformedJsonIsRefusedNotThrown() {
        assertFalse(PasskeyCreationRequest.supportsEs256("not json"))
        assertFalse(PasskeyCreationRequest.supportsEs256(""))
        assertNull(PasskeyCreationRequest.parse("not json"))
        assertNull(PasskeyCreationRequest.parse("[]"))
    }

    @Test
    fun aCompleteRequestIsRead() {
        val options = PasskeyCreationRequest.parse(request())

        assertNotNull(options)
        assertEquals("webauthn.io", options!!.rpId)
        assertEquals("ada", options.username)
        assertEquals("CQk", options.userHandle)
        assertEquals("Y2hhbGxlbmdl-_", options.challenge)
    }

    @Test
    fun theRelyingPartyIdIsRequired() {
        assertNull(PasskeyCreationRequest.parse(request(rp = null)))
        assertNull(PasskeyCreationRequest.parse(request(rp = """{"name":"WebAuthn"}""")))
        assertNull(PasskeyCreationRequest.parse(request(rp = """{"id":"  "}""")))
        assertNull(PasskeyCreationRequest.parse(request(rp = """{"id":null}""")))
        assertNull(PasskeyCreationRequest.parse(request(rp = """{"id":42}""")))
        assertNull(PasskeyCreationRequest.parse(request(rp = "\"webauthn.io\"")))
        assertNull(
            PasskeyCreationRequest.parse(request(rp = """{"id":"${"a".repeat(254)}"}""")),
        )
    }

    @Test
    fun theChallengeIsRequired() {
        assertNull(PasskeyCreationRequest.parse(request(challenge = null)))
        assertNull(PasskeyCreationRequest.parse(request(challenge = "\"\"")))
        assertNull(PasskeyCreationRequest.parse(request(challenge = "null")))
        assertNull(PasskeyCreationRequest.parse(request(challenge = "12345")))
    }

    @Test
    fun anAccountNameIsRequired() {
        assertNull(PasskeyCreationRequest.parse(request(user = null)))
        assertNull(PasskeyCreationRequest.parse(request(user = """{"id":"CQk"}""")))
        assertNull(PasskeyCreationRequest.parse(request(user = """{"id":"CQk","name":" "}""")))
    }

    @Test
    fun theDisplayNameStandsInForAMissingName() {
        val options = PasskeyCreationRequest.parse(
            request(user = """{"id":"CQk","displayName":"Ada L."}"""),
        )

        assertEquals("Ada L.", options!!.username)
    }

    @Test
    fun aMissingUserHandleIsNullAndPaddingIsRemoved() {
        assertNull(PasskeyCreationRequest.parse(request(user = """{"name":"ada"}"""))!!.userHandle)
        assertNull(
            PasskeyCreationRequest.parse(request(user = """{"id":"","name":"ada"}"""))!!.userHandle,
        )
        assertEquals(
            "CQk",
            PasskeyCreationRequest.parse(request(user = """{"id":"CQk=","name":"ada"}"""))!!.userHandle,
        )
    }

    @Test
    fun excludedCredentialIdsAreReadWithoutPadding() {
        val options = PasskeyCreationRequest.parse(
            request(
                exclude = """[{"type":"public-key","id":"AQIDBAU"},""" +
                    """{"type":"public-key","id":"Bgc-_w==","transports":["internal"]}]""",
            ),
        )

        assertEquals(listOf("AQIDBAU", "Bgc-_w"), options!!.excludeCredentialIds)
    }

    @Test
    fun absentNullOrEmptyExcludeCredentialsIsAnEmptyList() {
        assertTrue(PasskeyCreationRequest.parse(request())!!.excludeCredentialIds.isEmpty())
        assertTrue(
            PasskeyCreationRequest.parse(request(exclude = "null"))!!.excludeCredentialIds.isEmpty(),
        )
        assertTrue(
            PasskeyCreationRequest.parse(request(exclude = "[]"))!!.excludeCredentialIds.isEmpty(),
        )
        assertTrue(
            PasskeyCreationRequest.parse(request(exclude = """{"id":"AQIDBAU"}"""))!!
                .excludeCredentialIds.isEmpty(),
        )
    }

    @Test
    fun unreadableExcludeEntriesAreSkippedAndDuplicatesCollapse() {
        val options = PasskeyCreationRequest.parse(
            request(
                exclude = """["AQIDBAU",{"type":"public-key"},{"id":7},{"id":null},{"id":""},""" +
                    """{"id":"not base64url!"},{"id":"AQIDBAU"},{"id":"AQIDBAU="}]""",
            ),
        )

        assertEquals(listOf("AQIDBAU"), options!!.excludeCredentialIds)
    }

    @Test
    fun toStringCarriesNoChallengeAndNoUserHandle() {
        val text = PasskeyCreationRequest.parse(request()).toString()

        assertFalse(text.contains("Y2hhbGxlbmdl"))
        assertFalse(text.contains("CQk"))
    }
}
