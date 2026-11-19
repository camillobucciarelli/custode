package dev.camillobucciarelli.kdbxKeyVault

import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.LuminanceSource
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.ReaderException
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.qrcode.QRCodeReader

/**
 * Decodes a QR code from a camera frame's luminance (Y) plane with ZXing.
 *
 * No rotation step: a QR code's finder patterns make it readable at any
 * angle, so the sensor-oriented (landscape) frame is decoded as it comes.
 */
object QrDecoder {
    private val hints = mapOf(
        DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE),
        DecodeHintType.TRY_HARDER to true,
    )

    /**
     * @param luminance row-major Y plane; each row is [bytesPerRow] bytes, of
     *   which the first [width] are pixels. The last row may omit the padding.
     * @return the QR text, or null when no code is found or the arguments do
     *   not describe the buffer.
     */
    fun decode(luminance: ByteArray, width: Int, height: Int, bytesPerRow: Int): String? {
        if (width <= 0 || height <= 0 || bytesPerRow < width) return null
        if (luminance.size.toLong() < bytesPerRow.toLong() * (height - 1) + width) return null
        val source = PlanarYUVLuminanceSource(
            luminance, bytesPerRow, height, 0, 0, width, height, false,
        )
        // Light-on-dark codes (dark-mode setup pages) need the inverted image.
        return read(source) ?: read(source.invert())
    }

    private fun read(source: LuminanceSource): String? = try {
        QRCodeReader().decode(BinaryBitmap(HybridBinarizer(source)), hints).text
    } catch (e: ReaderException) {
        null
    }
}
