package dev.camillobucciarelli.kdbxKeyVault.autofill

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * spec 023 T805 — the registration response a relying party reads, byte for
 * byte, and the rule that only a complete `done` answer becomes one.
 *
 * Fixture values are short public placeholders, not key material.
 */
class PasskeyRegistrationResponseTest {
    private fun doneAnswer(): MutableMap<String, Any?> = mutableMapOf(
        "status" to "done",
        "credentialId" to "AQIDBAU",
        "userHandle" to "CQk",
        "attestationObject" to "o2NmbXQ",
        "authenticatorData" to "SZYN5Q",
        "publicKeyCose" to "pQECAyY",
        "publicKeySpki" to "MFkwEw",
    )

    @Test
    fun clientDataIsACreateCeremonyWithTheChallengeUntouched() {
        val clientData = PasskeyRegistrationResponse.clientDataJson(
            challenge = "Y2hhbGxlbmdl-_",
            origin = "https://webauthn.io",
            androidPackageName = null,
        )

        assertEquals(
            """{"type":"webauthn.create","challenge":"Y2hhbGxlbmdl-_","origin":"https://webauthn.io"}""",
            String(clientData, Charsets.UTF_8),
        )
    }

    @Test
    fun aNativeCallerAddsItsPackageName() {
        val clientData = PasskeyRegistrationResponse.clientDataJson(
            challenge = "abc",
            origin = "android:apk-key-hash:Zm9v",
            androidPackageName = "com.example.app",
        )

        assertEquals(
            """{"type":"webauthn.create","challenge":"abc","origin":"android:apk-key-hash:Zm9v","androidPackageName":"com.example.app"}""",
            String(clientData, Charsets.UTF_8),
        )
    }

    @Test
    fun clientDataEscapesWhatWouldBreakTheJson() {
        val clientData = PasskeyRegistrationResponse.clientDataJson(
            challenge = "a\"b\\c\n",
            origin = "https://example.org",
            androidPackageName = null,
        )

        assertEquals(
            "{\"type\":\"webauthn.create\",\"challenge\":\"a\\\"b\\\\c\\u000a\"," +
                "\"origin\":\"https://example.org\"}",
            String(clientData, Charsets.UTF_8),
        )
    }

    @Test
    fun responseJsonCarriesEveryRegistrationField() {
        val created = PasskeyRegistrationResponse.createdFrom(doneAnswer())!!
        val json = PasskeyRegistrationResponse.json(
            created = created,
            clientDataJson = "{}".toByteArray(Charsets.UTF_8),
        )

        assertEquals(
            """{"id":"AQIDBAU","rawId":"AQIDBAU","type":"public-key",""" +
                """"authenticatorAttachment":"platform","response":{""" +
                """"clientDataJSON":"e30","attestationObject":"o2NmbXQ",""" +
                """"authenticatorData":"SZYN5Q","publicKey":"MFkwEw",""" +
                """"publicKeyAlgorithm":-7,"transports":["internal","hybrid"]},""" +
                """"clientExtensionResults":{}}""",
            json,
        )
    }

    @Test
    fun clientDataIsEncodedBase64UrlWithoutPadding() {
        // 0xfb 0xff encodes to "-_8=" in padded base64url.
        assertEquals(
            "-_8",
            PasskeyRegistrationResponse.base64Url(byteArrayOf(0xfb.toByte(), 0xff.toByte())),
        )
    }

    @Test
    fun onlyADoneAnswerBecomesAResponse() {
        for (status in listOf("noVault", "locked", "alreadyExists", "failed", "ready", "")) {
            val answer = doneAnswer().apply { put("status", status) }
            assertNull(status, PasskeyRegistrationResponse.createdFrom(answer))
        }
        assertNull(PasskeyRegistrationResponse.createdFrom(doneAnswer().apply { remove("status") }))
        assertNull(PasskeyRegistrationResponse.createdFrom(null))
        assertNull(PasskeyRegistrationResponse.createdFrom(emptyMap<String, Any?>()))
    }

    @Test
    fun aDoneAnswerMissingAValueIsNotASuccess() {
        for (key in listOf("credentialId", "attestationObject", "authenticatorData", "publicKeySpki")) {
            assertNull(key, PasskeyRegistrationResponse.createdFrom(doneAnswer().apply { remove(key) }))
            assertNull(key, PasskeyRegistrationResponse.createdFrom(doneAnswer().apply { put(key, "") }))
            assertNull(key, PasskeyRegistrationResponse.createdFrom(doneAnswer().apply { put(key, 7) }))
            assertNull(
                key,
                PasskeyRegistrationResponse.createdFrom(doneAnswer().apply { put(key, "not base64url!") }),
            )
        }
    }

    @Test
    fun paddingFromTheAppIsRemoved() {
        val created = PasskeyRegistrationResponse.createdFrom(
            doneAnswer().apply { put("credentialId", "AQIDBAU=") },
        )

        assertNotNull(created)
        assertEquals("AQIDBAU", created!!.credentialId)
    }

    @Test
    fun toStringCarriesNoValue() {
        val text = PasskeyRegistrationResponse.createdFrom(doneAnswer()).toString()

        assertFalse(text.contains("AQIDBAU"))
        assertFalse(text.contains("MFkwEw"))
    }
}
