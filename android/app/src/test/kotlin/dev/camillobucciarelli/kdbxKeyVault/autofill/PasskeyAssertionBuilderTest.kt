package dev.camillobucciarelli.kdbxKeyVault.autofill

import java.security.KeyFactory
import java.security.MessageDigest
import java.security.Signature
import java.security.spec.X509EncodedKeySpec
import java.util.Base64
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * spec 023 T004. Mirrors test/features/password_manager/data/services/
 * desktop_passkey_signer_test.dart on the JVM (no Android classes).
 */
class PasskeyAssertionBuilderTest {
    // Fixture-only keys, copied from test/fixtures/passkeys/vectors.dart.
    // Never registered anywhere; not secrets.
    private val es256PrivateKeyPem = """
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgsXPNUCtYJvj/t3pO
j0l+8lPDf+Hj3BOQG+G9CqFKr9+hRANCAASowUEpj6dRNu1qqBNMFeTTEN/dfNmD
mXl5Ff0wo+76ViV5+FstAJS7jCG7WJ5DnJcOKuzypVCKEhWwiJgycFXw
-----END PRIVATE KEY-----
"""

    private val es256PublicKeyPem = """
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEqMFBKY+nUTbtaqgTTBXk0xDf3XzZ
g5l5eRX9MKPu+lYlefhbLQCUu4whu1ieQ5yXDirs8qVQihIVsIiYMnBV8A==
-----END PUBLIC KEY-----
"""

    private val rs256PrivateKeyPem = """
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCwsRJQhg8SR7ZI
h+74xB8Z2Mx5CollW5o6YKe1je3zV8qXviQuSOFq6VQPWOLPoft7biwOB911P/l/
4dtbHo2qT5un7SaZbnkGX6HWGKO2keX5DdzUIVKdo+06zi7iyQKmO+4ctPs9U3Kz
tGpDeopZcV/a9rvSK+cqMFy8xbnE0docEXkcy5SKbmYZiJUZeRTxOBNnlmOjUAK6
bJ12G+RHa2KrW8ryaUU1budjNSIQ2+6KjYP5QQlR0jDzHrT33B7Ua5XAyEoNwYAY
e0+/4zAZZgl3acMYXsXzgrHSS680P86IsJfXdCJLb4gZnzvlB09xYpLXhYjhLbwh
rwSoVoAdAgMBAAECggEAUb2RIfRq24OWdgaAzM/6LVxo96QivOO8PT6Cx5CB4N4f
6MQ7e7gWpH2N+E2gG/stWsQ0mEcWMgxnEby8XHKNihkrAuxIu5lqXsL2HRQoBKmJ
UQcTPoWt8SSpdld1RFBGq/20oc4uHohQ24be1BnIECnNdQBJEqlh11gpRuFYGA9R
C2z88vXZwS9w3QkWACzroHkHDtF/0M7DZli6dTqlap64HGU36SwmTpdhS4dMlOKg
kycNeNybVrd7AuusXTBRuTqgrjnB+aHqcafTvx6oGaxJJJQi6M03XnCGB1ojLyWz
nGQiVAmR/IoVQdEWrLv6LEiyLhuTMAAsOoR1ZO89xwKBgQDt0JKZqcUJ+axoomk6
B9VeMSrnzwNBbH9tUuj4D4taTlO3riyfbipd6U8tg2bZQ7mL7LPdZ+Q2cI/b0aRU
uL+j7vVu1iOd/s/uTUtTkwZi2E2EcmP2aK0+LcownPUF41QiGgk1m1FC8WeGj1xr
8mNqe3hvTf+PiPj8KMFMY9l4EwKBgQC+M/Z3UnoQ5miuR9WC2nXt/EmUlgyyQbPG
tdl4KwxisvzRu1381z4RWEs+7SvefDmhi4jl/CDO/BHBCr3pEKTiZyQWrBJiLDxX
ikL5ylRmit6Hp7rt8Tplm5zqTLAqCJSLkHxSwql0y62z1WpULoRxQjz8AFP/XlVI
D9sZFXKNDwKBgC9Ef37vUWyUJYJ+lW+lUvFv0FlWugzs5b7y9b8oR8hhPR6LDe96
VA1qbARd07lnTp/TIkTle2SeptlIJ+N2/RA2VK38/gNPPEDfOBOaa3CGEZI7skat
s5FiRIe5CrJq5rQIfMAc6N/nX25NXE9QVBY8CEoHNL5wuRxVdWYbioPlAoGAAcgu
2PNW3W2rMWbO40j0reQdNF0rhUgETSpK/Us59HrEz5o3yTSjCjqPieli7dSwHYlX
IQB5tja6W9qj6NkVEmHw/p1iFrVfY1qSQhDZNZS7fP3fTHdkGquYjsFlLR+jdKNH
5uaX+9YkrHilZGCDMSRzudCu+MeDeQddACEpT5UCgYEAlQ2oiEU9ow/i7cHqMXi9
spEktxPLLsJD3p4ZRsLGW9ofCASFAvbB7FqNjYFQXynsR6CUfov/bDCI0vUF32yW
6sxAAwWmkjl8tlK5AoN7NEw14s3vwfzWsp7OogM2jlH3zgSuIaKC8gYad2jKXIqd
S3j5FI3TDfF5Y0USOnDKs6c=
-----END PRIVATE KEY-----
"""

    private val rs256PublicKeyPem = """
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAsLESUIYPEke2SIfu+MQf
GdjMeQqJZVuaOmCntY3t81fKl74kLkjhaulUD1jiz6H7e24sDgfddT/5f+HbWx6N
qk+bp+0mmW55Bl+h1hijtpHl+Q3c1CFSnaPtOs4u4skCpjvuHLT7PVNys7RqQ3qK
WXFf2va70ivnKjBcvMW5xNHaHBF5HMuUim5mGYiVGXkU8TgTZ5Zjo1ACumyddhvk
R2tiq1vK8mlFNW7nYzUiENvuio2D+UEJUdIw8x6099we1GuVwMhKDcGAGHtPv+Mw
GWYJd2nDGF7F84Kx0kuvND/OiLCX13QiS2+IGZ875QdPcWKS14WI4S28Ia8EqFaA
HQIDAQAB
-----END PUBLIC KEY-----
"""

    private val eddsaPrivateKeyPem = """
-----BEGIN PRIVATE KEY-----
MC4CAQAwBQYDK2VwBCIEIE/KNjFb/g7qelADCTqrUfJnMgM3wVBpkXgH6uT7QnUn
-----END PRIVATE KEY-----
"""

    private val eddsaPublicKeyPem = """
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAfvhLh0hetAAPqudMFN0ZkH6r6IFukCxUBJERIDY8dSc=
-----END PUBLIC KEY-----
"""

    private val rpId = "webauthn.io"
    private val rpIdHashHex = "74a6ea9213c99c2f74b22492b320cf40262a94c1a950a0397f29250b60841ef0"
    private val challenge = "dGVzdC1jaGFsbGVuZ2U"
    private val origin = "https://webauthn.io"

    private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it) }

    private fun passkey(pem: String, algorithm: AndroidPasskeyAlgorithm) = AndroidAutofillPasskey(
        rpId = rpId,
        credentialId = "CQgH",
        userHandle = "AQ",
        username = "alice",
        privateKeyPem = pem,
        algorithm = algorithm,
        backupEligible = true,
        backupState = true,
    )

    private fun verify(
        keyAlgorithm: String,
        signatureAlgorithm: String,
        publicPem: String,
        assertion: PasskeyAssertionBuilder.Assertion,
    ): Boolean {
        val der = Base64.getDecoder().decode(
            publicPem.lines().filter { !it.startsWith("-----") }.joinToString(""),
        )
        val key = KeyFactory.getInstance(keyAlgorithm).generatePublic(X509EncodedKeySpec(der))
        val message = assertion.authenticatorData +
            MessageDigest.getInstance("SHA-256").digest(assertion.clientDataJson)
        return Signature.getInstance(signatureAlgorithm).run {
            initVerify(key)
            update(message)
            verify(assertion.signature)
        }
    }

    private fun assertion(pem: String, algorithm: AndroidPasskeyAlgorithm) =
        PasskeyAssertionBuilder.assert(
            passkey(pem, algorithm), challenge, origin, null,
            callerIsVerifiedBrowser = false, suppliedClientDataHash = null,
        )

    @Test
    fun authenticatorDataMatchesVector() {
        val bytes = PasskeyAssertionBuilder.authenticatorData(rpId, true, true)
        assertEquals(rpIdHashHex + "1d00000000", hex(bytes))
        assertEquals(37, bytes.size)
    }

    @Test
    fun flagsDropBackupBitsWhenOff() {
        assertEquals(0x05, PasskeyAssertionBuilder.authenticatorData(rpId, false, false)[32].toInt())
        // BS without BE is never set.
        assertEquals(0x05, PasskeyAssertionBuilder.authenticatorData(rpId, false, true)[32].toInt())
    }

    @Test
    fun clientDataJsonIsWebAuthnGet() {
        val json = JSONObject(String(PasskeyAssertionBuilder.clientDataJson(challenge, origin, null)))
        assertEquals("webauthn.get", json.getString("type"))
        assertEquals(challenge, json.getString("challenge"))
        assertEquals(origin, json.getString("origin"))
        assertTrue(!json.has("androidPackageName"))
        val app = JSONObject(String(PasskeyAssertionBuilder.clientDataJson(challenge, origin, "com.x")))
        assertEquals("com.x", app.getString("androidPackageName"))
    }

    @Test
    fun es256SignatureVerifies() {
        val a = assertion(es256PrivateKeyPem, AndroidPasskeyAlgorithm.Es256)
        assertTrue(verify("EC", "SHA256withECDSA", es256PublicKeyPem, a))
        assertEquals("CQgH", a.credentialId)
        assertEquals("AQ", a.userHandle)
    }

    @Test
    fun rs256SignatureVerifies() {
        val a = assertion(rs256PrivateKeyPem, AndroidPasskeyAlgorithm.Rs256)
        assertTrue(verify("RSA", "SHA256withRSA", rs256PublicKeyPem, a))
        assertEquals(256, a.signature.size)
    }

    @Test
    fun eddsaSignatureVerifiesWhereJvmSupportsEd25519() {
        // Ed25519 needs JDK 15+; skip silently on older test JVMs.
        val supported = try {
            KeyFactory.getInstance("Ed25519"); true
        } catch (e: Exception) {
            false
        }
        if (!supported) return
        val a = assertion(eddsaPrivateKeyPem, AndroidPasskeyAlgorithm.EdDsa)
        assertTrue(verify("Ed25519", "Ed25519", eddsaPublicKeyPem, a))
    }

    @Test
    fun truncatedKeyIsBadKey() {
        val truncated = es256PrivateKeyPem.lines().take(2).joinToString("\n") +
            "\n-----END PRIVATE KEY-----"
        try {
            assertion(truncated, AndroidPasskeyAlgorithm.Es256)
            fail("expected BadKey")
        } catch (e: PasskeyAssertionBuilder.BadKey) {
        }
    }

    @Test
    fun base64UrlRoundTripsAndAcceptsPadding() {
        val bytes = byteArrayOf(-5, -1, 0, 9, 8)
        val encoded = PasskeyAssertionBuilder.base64Url(bytes)
        assertTrue(!encoded.contains("=") && !encoded.contains("+") && !encoded.contains("/"))
        assertArrayEquals(bytes, PasskeyAssertionBuilder.decodeBase64Url(encoded))
        assertArrayEquals(bytes, PasskeyAssertionBuilder.decodeBase64Url(encoded + "="))
        assertNull(PasskeyAssertionBuilder.decodeBase64Url("!!"))
    }

    @Test
    fun publicKeyCredentialJsonCarriesBase64UrlFields() {
        val a = assertion(es256PrivateKeyPem, AndroidPasskeyAlgorithm.Es256)
        val json = JSONObject(PasskeyAssertionBuilder.publicKeyCredentialJson(a))
        assertEquals("CQgH", json.getString("rawId"))
        assertEquals("public-key", json.getString("type"))
        assertEquals(
            PasskeyAssertionBuilder.base64Url(a.signature),
            json.getJSONObject("response").getString("signature"),
        )
    }

    private fun verifyOver(message: ByteArray, a: PasskeyAssertionBuilder.Assertion): Boolean {
        val der = Base64.getDecoder().decode(
            es256PublicKeyPem.lines().filter { !it.startsWith("-----") }.joinToString(""),
        )
        val key = KeyFactory.getInstance("EC").generatePublic(X509EncodedKeySpec(der))
        return Signature.getInstance("SHA256withECDSA").run {
            initVerify(key)
            update(message)
            verify(a.signature)
        }
    }

    private val nativeOrigin = "android:apk-key-hash:AAAA"
    private val spoofedHash =
        MessageDigest.getInstance("SHA-256").digest("browser client data".toByteArray())

    private fun gated(verifiedBrowser: Boolean, hash: ByteArray?) = PasskeyAssertionBuilder.assert(
        passkey(es256PrivateKeyPem, AndroidPasskeyAlgorithm.Es256),
        challenge,
        if (verifiedBrowser) origin else nativeOrigin,
        if (verifiedBrowser) null else "com.evil.app",
        callerIsVerifiedBrowser = verifiedBrowser,
        suppliedClientDataHash = hash,
    )

    private fun overProviderBuilt(a: PasskeyAssertionBuilder.Assertion) =
        verifyOver(a.authenticatorData + MessageDigest.getInstance("SHA-256").digest(a.clientDataJson), a)

    @Test
    fun nonPrivilegedCallerCannotChooseTheSignedHash() {
        // Origin spoofing: a native app supplies the hash of a clientDataJSON
        // claiming a web origin. It must get a signature over its own
        // android:apk-key-hash client data and nothing else.
        val a = gated(verifiedBrowser = false, hash = spoofedHash)
        assertTrue(overProviderBuilt(a))
        assertTrue(!verifyOver(a.authenticatorData + spoofedHash, a))
        val clientData = JSONObject(String(a.clientDataJson))
        assertEquals(nativeOrigin, clientData.getString("origin"))
        assertEquals("com.evil.app", clientData.getString("androidPackageName"))
    }

    @Test
    fun privilegedBrowserHashIsSignedInsteadOfOurOwn() {
        val a = gated(verifiedBrowser = true, hash = spoofedHash)
        assertTrue(verifyOver(a.authenticatorData + spoofedHash, a))
        assertTrue(!overProviderBuilt(a))
    }

    @Test
    fun privilegedBrowserWithoutHashKeepsProviderBuiltClientData() {
        for (hash in listOf(null, ByteArray(0))) {
            assertTrue(overProviderBuilt(gated(verifiedBrowser = true, hash = hash)))
        }
    }

    @Test
    fun clientDataHashToHonourRequiresAVerifiedBrowser() {
        assertNull(PasskeyAssertionBuilder.clientDataHashToHonour(false, spoofedHash))
        assertNull(PasskeyAssertionBuilder.clientDataHashToHonour(true, null))
        assertNull(PasskeyAssertionBuilder.clientDataHashToHonour(true, ByteArray(0)))
        assertArrayEquals(
            spoofedHash,
            PasskeyAssertionBuilder.clientDataHashToHonour(true, spoofedHash),
        )
    }
}
