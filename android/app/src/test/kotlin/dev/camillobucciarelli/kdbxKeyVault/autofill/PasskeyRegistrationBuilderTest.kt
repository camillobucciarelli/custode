package dev.camillobucciarelli.kdbxKeyVault.autofill

import java.io.File
import java.math.BigInteger
import java.security.KeyFactory
import java.security.KeyPair
import java.security.Signature
import java.security.AlgorithmParameters
import java.security.interfaces.ECPrivateKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import java.security.spec.PKCS8EncodedKeySpec
import java.util.Base64
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** spec 024 T021. Fixture-only key material, see the fixture's `note`. */
class PasskeyRegistrationBuilderTest {
    private val vector = JSONObject(File(fixtureDir(), "registration_vector.json").readText())

    private fun hex(name: String): ByteArray {
        val s = vector.getString(name)
        return ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    }

    private fun toHex(b: ByteArray) = b.joinToString("") { "%02x".format(it) }

    private fun fixtureKeyPair(): KeyPair {
        val pem = vector.getString("privateKeyPkcs8Pem")
        val der = Base64.getDecoder().decode(
            pem.lines().filterNot { it.startsWith("-----") }.joinToString(""),
        )
        val kf = KeyFactory.getInstance("EC")
        val private = kf.generatePrivate(PKCS8EncodedKeySpec(der))
        val params = AlgorithmParameters.getInstance("EC")
            .apply { init(ECGenParameterSpec("secp256r1")) }
            .getParameterSpec(ECParameterSpec::class.java)
        val point = ECPoint(
            BigInteger(vector.getString("publicKeyXHex"), 16),
            BigInteger(vector.getString("publicKeyYHex"), 16),
        )
        return KeyPair(kf.generatePublic(ECPublicKeySpec(point, params)), private)
    }

    @Test
    fun reproducesTheSharedVectorByteForByte() {
        val reg = PasskeyRegistrationBuilder.create(
            rpId = vector.getString("rpId"),
            keyPair = fixtureKeyPair(),
            credentialId = hex("credentialIdHex"),
        )
        assertEquals(vector.getString("coseKeyHex"), toHex(reg.coseKey))
        assertEquals(vector.getString("authDataHex"), toHex(reg.authenticatorData))
        assertEquals(vector.getString("attestationObjectHex"), toHex(reg.attestationObject))
        assertEquals(vector.getString("privateKeyPkcs8Pem"), reg.privateKeyPem)
    }

    @Test
    fun generatedPemIsAValidPkcs8EcKeyThatSigns() {
        val reg = PasskeyRegistrationBuilder.create("example.com")
        assertEquals(32, reg.credentialId.size)
        val der = Base64.getDecoder().decode(
            reg.privateKeyPem.lines().filterNot { it.startsWith("-----") }.joinToString(""),
        )
        val key = KeyFactory.getInstance("EC").generatePrivate(PKCS8EncodedKeySpec(der))
        assertTrue(key is ECPrivateKey)
        val sig = Signature.getInstance("SHA256withECDSA").run {
            initSign(key); update(byteArrayOf(1, 2, 3)); sign()
        }
        val pub = KeyFactory.getInstance("EC")
            .generatePublic(java.security.spec.X509EncodedKeySpec(reg.publicKeySpki))
        assertTrue(
            Signature.getInstance("SHA256withECDSA").run {
                initVerify(pub); update(byteArrayOf(1, 2, 3)); verify(sig)
            },
        )
        assertEquals("Registration(rpId=example.com)", reg.toString())
    }

    @Test
    fun responseJsonCarriesTheRegistrationFields() {
        val reg = PasskeyRegistrationBuilder.create("example.com")
        val client = PasskeyRegistrationBuilder.clientDataJson("abc", "https://example.com", null)
        val json = JSONObject(PasskeyRegistrationBuilder.registrationResponseJson(reg, client))
        val id = PasskeyAssertionBuilder.base64Url(reg.credentialId)
        assertEquals(id, json.getString("id"))
        assertEquals(id, json.getString("rawId"))
        val response = json.getJSONObject("response")
        assertArrayEquals(
            reg.attestationObject,
            PasskeyAssertionBuilder.decodeBase64Url(response.getString("attestationObject")),
        )
        assertEquals(-7, response.getInt("publicKeyAlgorithm"))
        assertEquals("webauthn.create", JSONObject(String(client)).getString("type"))
        assertFalse(JSONObject(String(client)).has("androidPackageName"))
    }

    private fun fixtureDir(): File {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val candidate = File(dir, "test/fixtures/passkeys")
            if (candidate.isDirectory) return candidate
            dir = dir.parentFile
        }
        error("test/fixtures/passkeys not found")
    }
}
