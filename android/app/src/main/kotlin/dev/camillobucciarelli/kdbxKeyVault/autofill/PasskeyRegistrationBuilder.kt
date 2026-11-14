package dev.camillobucciarelli.kdbxKeyVault.autofill

import java.math.BigInteger
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.interfaces.ECPrivateKey
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.util.Base64
import org.json.JSONArray
import org.json.JSONObject

/**
 * spec 024 T021 (FR-2, FR-3). Creates an ES256 passkey registration on the JVM:
 * JCA key pair (not AndroidKeyStore, the PKCS#8 PEM must be exportable), hand
 * written CBOR for the one fixed shape, byte for byte what the Dart
 * `PasskeyGenerator` produces (pinned by test/fixtures/passkeys/registration_vector.json).
 *
 * Nothing here logs; [Registration.privateKeyPem] is the secret.
 */
internal object PasskeyRegistrationBuilder {
    /** UP | UV | BE | BS | AT. */
    private const val FLAGS = 0x5d

    class Registration(
        val rpId: String,
        val credentialId: ByteArray,
        val privateKeyPem: String,
        val coseKey: ByteArray,
        val authenticatorData: ByteArray,
        val attestationObject: ByteArray,
        /** DER SubjectPublicKeyInfo, what `getPublicKey()` returns. */
        val publicKeySpki: ByteArray,
    ) {
        override fun toString(): String = "Registration(rpId=$rpId)"
    }

    fun generateKeyPair(): KeyPair =
        KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }
            .generateKeyPair()

    fun randomCredentialId(): ByteArray = ByteArray(32).also { SecureRandom().nextBytes(it) }

    /** [keyPair] and [credentialId] are injectable so a test can pin them. */
    fun create(
        rpId: String,
        keyPair: KeyPair = generateKeyPair(),
        credentialId: ByteArray = randomCredentialId(),
    ): Registration {
        val private = keyPair.private as ECPrivateKey
        val public = keyPair.public as ECPublicKey
        val x = fixed(public.w.affineX, 32)
        val y = fixed(public.w.affineY, 32)
        val cose = byteArrayOf(
            0xa5.toByte(), 0x01, 0x02, 0x03, 0x26, 0x20, 0x01,
            0x21, 0x58, 0x20, *x, 0x22, 0x58, 0x20, *y,
        )
        val rpIdHash = MessageDigest.getInstance("SHA-256").digest(rpId.toByteArray(Charsets.UTF_8))
        val authData = rpIdHash + byteArrayOf(FLAGS.toByte(), 0, 0, 0, 0) + ByteArray(16) +
            byteArrayOf((credentialId.size shr 8).toByte(), credentialId.size.toByte()) +
            credentialId + cose
        return Registration(
            rpId = rpId,
            credentialId = credentialId,
            privateKeyPem = pkcs8Pem(fixed(private.s, 32), byteArrayOf(0x04, *x, *y)),
            coseKey = cose,
            authenticatorData = authData,
            attestationObject = attestationObject(authData),
            publicKeySpki = public.encoded,
        )
    }

    /** `{fmt: "none", attStmt: {}, authData}`, canonical key order. */
    fun attestationObject(authData: ByteArray): ByteArray {
        val header = when {
            authData.size < 24 -> byteArrayOf((0x40 or authData.size).toByte())
            authData.size < 0x100 -> byteArrayOf(0x58, authData.size.toByte())
            authData.size < 0x10000 ->
                byteArrayOf(0x59, (authData.size shr 8).toByte(), authData.size.toByte())
            else -> throw IllegalArgumentException("authData is implausibly long")
        }
        return byteArrayOf(0xa3.toByte()) +
            byteArrayOf(0x63) + "fmt".toByteArray() + byteArrayOf(0x64) + "none".toByteArray() +
            byteArrayOf(0x67) + "attStmt".toByteArray() + byteArrayOf(0xa0.toByte()) +
            byteArrayOf(0x68) + "authData".toByteArray() + header + authData
    }

    fun clientDataJson(challenge: String, origin: String, androidPackageName: String?): ByteArray {
        val json = JSONObject()
            .put("type", "webauthn.create")
            .put("challenge", challenge)
            .put("origin", origin)
        if (androidPackageName != null) json.put("androidPackageName", androidPackageName)
        return json.toString().toByteArray(Charsets.UTF_8)
    }

    /** The JSON Credential Manager hands to the relying party's JS. */
    fun registrationResponseJson(registration: Registration, clientDataJson: ByteArray): String {
        val id = PasskeyAssertionBuilder.base64Url(registration.credentialId)
        val response = JSONObject()
            .put("clientDataJSON", PasskeyAssertionBuilder.base64Url(clientDataJson))
            .put("attestationObject", PasskeyAssertionBuilder.base64Url(registration.attestationObject))
            .put("transports", JSONArray().put("internal"))
            .put("authenticatorData", PasskeyAssertionBuilder.base64Url(registration.authenticatorData))
            .put("publicKey", PasskeyAssertionBuilder.base64Url(registration.publicKeySpki))
            .put("publicKeyAlgorithm", -7)
        return JSONObject()
            .put("id", id)
            .put("rawId", id)
            .put("type", "public-key")
            .put("authenticatorAttachment", "platform")
            .put("clientExtensionResults", JSONObject())
            .put("response", response)
            .toString()
    }

    /**
     * PKCS#8 wrapping an RFC 5915 ECPrivateKey with curve parameters and the
     * public point, same layout as the Dart generator (and the fixture).
     */
    private fun pkcs8Pem(d: ByteArray, point: ByteArray): String {
        val oidP256 = byteArrayOf(0x06, 0x08, 0x2a, 0x86.toByte(), 0x48, 0xce.toByte(), 0x3d, 0x03, 0x01, 0x07)
        val oidEcPublicKey = byteArrayOf(0x06, 0x07, 0x2a, 0x86.toByte(), 0x48, 0xce.toByte(), 0x3d, 0x02, 0x01)
        val ecPrivateKey = der(
            0x30,
            byteArrayOf(0x02, 0x01, 0x01) + der(0x04, d) + der(0xa0, oidP256) +
                der(0xa1, der(0x03, byteArrayOf(0) + point)),
        )
        val info = der(
            0x30,
            byteArrayOf(0x02, 0x01, 0x00) + der(0x30, oidEcPublicKey + oidP256) + der(0x04, ecPrivateKey),
        )
        val body = Base64.getEncoder().encodeToString(info)
        return "-----BEGIN PRIVATE KEY-----\n" + body.chunked(64).joinToString("\n") +
            "\n-----END PRIVATE KEY-----"
    }

    private fun der(tag: Int, body: ByteArray): ByteArray {
        val length = when {
            body.size < 0x80 -> byteArrayOf(body.size.toByte())
            body.size < 0x100 -> byteArrayOf(0x81.toByte(), body.size.toByte())
            else -> byteArrayOf(0x82.toByte(), (body.size shr 8).toByte(), body.size.toByte())
        }
        return byteArrayOf(tag.toByte()) + length + body
    }

    /** Left-pads (or strips the sign byte) to [length]. */
    private fun fixed(value: BigInteger, length: Int): ByteArray {
        val raw = value.toByteArray()
        val trimmed = if (raw.size > length) raw.copyOfRange(raw.size - length, raw.size) else raw
        return ByteArray(length - trimmed.size) + trimmed
    }
}
