package dev.camillobucciarelli.kdbxKeyVault

import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.BarcodeFormat
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class QrDecoderTest {
    private val uri = "otpauth://totp/Example:alice@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Example"

    /** A Y plane like the camera's: [stride] bytes per row, padding included. */
    private fun plane(
        size: Int = 300,
        stride: Int = 320,
        inverted: Boolean = false,
        rotated: Boolean = false,
    ): ByteArray {
        val matrix = QRCodeWriter().encode(uri, BarcodeFormat.QR_CODE, size, size)
        val dark: Byte = if (inverted) 0xFF.toByte() else 0x00
        val light: Byte = if (inverted) 0x00 else 0xFF.toByte()
        return ByteArray(stride * size) { i ->
            val x = i % stride
            val y = i / stride
            when {
                x >= size -> 0x55 // row padding: must be ignored
                (if (rotated) matrix.get(y, size - 1 - x) else matrix.get(x, y)) -> dark
                else -> light
            }
        }
    }

    @Test
    fun decodesAPaddedLuminancePlane() {
        assertEquals(uri, QrDecoder.decode(plane(), 300, 300, 320))
    }

    @Test
    fun decodesARotatedCode() {
        assertEquals(uri, QrDecoder.decode(plane(rotated = true), 300, 300, 320))
    }

    @Test
    fun decodesAnInvertedCode() {
        assertEquals(uri, QrDecoder.decode(plane(inverted = true), 300, 300, 320))
    }

    @Test
    fun acceptsALastRowWithoutPadding() {
        val full = plane()
        assertEquals(uri, QrDecoder.decode(full.copyOf(full.size - 20), 300, 300, 320))
    }

    @Test
    fun returnsNullWithoutACode() {
        assertNull(QrDecoder.decode(ByteArray(320 * 300) { 0x7F }, 300, 300, 320))
    }

    @Test
    fun returnsNullWhenTheBufferIsTooShort() {
        assertNull(QrDecoder.decode(ByteArray(100), 300, 300, 320))
        assertNull(QrDecoder.decode(ByteArray(100), 300, 300, 200))
    }
}
