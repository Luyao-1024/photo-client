package com.photoviewer.photo_client

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.media.ExifInterface
import android.media.MediaMetadataRetriever
import android.os.Environment
import androidx.annotation.Keep
import java.io.File
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone
import kotlin.math.max

/**
 * Called from the Rust core over JNI. Android owns video/HEIC decoding so the
 * catalog and thumbnail pipeline stay identical to the Linux core.
 */
@Keep
object AndroidMediaBridge {
    private external fun nativeBind()

    init {
        nativeBind()
    }

    /** Forces class initialization so Rust caches this class before any scan. */
    fun ensureInitialized() = Unit

    /** Returns [width, height, durationMs, rotation, captureTimeMs] or an empty array. */
    @JvmStatic
    fun probeVideo(path: String): LongArray {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(path)
            val width = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
                ?.toLongOrNull() ?: 0L
            val height = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
                ?.toLongOrNull() ?: 0L
            if (width <= 0 || height <= 0) return longArrayOf()
            val duration = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull() ?: 0L
            val rotation = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
                ?.toLongOrNull() ?: 0L
            val date = parseDate(
                retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DATE),
            )
            longArrayOf(width, height, duration, rotation, date)
        } catch (_: Exception) {
            longArrayOf()
        } finally {
            retriever.release()
        }
    }

    /** Returns [width, height, exifOrientation, captureTimeMs] or an empty array. */
    @JvmStatic
    fun probeImage(path: String): LongArray {
        return try {
            val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, options)
            if (options.outWidth <= 0 || options.outHeight <= 0) return longArrayOf()
            val exif = try {
                ExifInterface(path)
            } catch (_: Exception) {
                null
            }
            val orientation = exif?.getAttributeInt(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL,
            ) ?: ExifInterface.ORIENTATION_NORMAL
            longArrayOf(
                options.outWidth.toLong(),
                options.outHeight.toLong(),
                orientation.toLong(),
                exifCaptureTime(exif),
            )
        } catch (_: Exception) {
            longArrayOf()
        }
    }

    /** Standard public media folders that currently exist. */
    @JvmStatic
    @Suppress("DEPRECATION")
    fun mediaDirectories(): Array<String> {
        val root = Environment.getExternalStorageDirectory()
        return arrayOf("DCIM", "Pictures", "Movies", "Download")
            .map { File(root, it) }
            .filter { it.isDirectory }
            .map { it.absolutePath }
            .toTypedArray()
    }

    /**
     * EXIF wall time is only an instant when the original offset is present,
     * matching the Linux header reader.
     */
    private fun exifCaptureTime(exif: ExifInterface?): Long {
        if (exif == null) return 0L
        return try {
            val raw = exif.getAttribute(ExifInterface.TAG_DATETIME_ORIGINAL) ?: return 0L
            val offset = exif.getAttribute(ExifInterface.TAG_OFFSET_TIME_ORIGINAL) ?: return 0L
            if (!Regex("^[+-](0\\d|1[0-4]):[0-5]\\d$").matches(offset)) return 0L
            val format = SimpleDateFormat("yyyy:MM:dd HH:mm:ss", Locale.US)
            format.timeZone = TimeZone.getTimeZone("GMT$offset")
            format.parse(raw)?.time ?: 0L
        } catch (_: Exception) {
            0L
        }
    }

    @JvmStatic
    fun imageThumbnail(path: String, destination: String, maxEdge: Int): Boolean {
        return try {
            val source = ImageDecoder.createSource(File(path))
            val bitmap = ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
                val longest = max(info.size.width, info.size.height)
                var sample = 1
                while (longest / (sample * 2) >= maxEdge) sample *= 2
                if (sample > 1) decoder.setTargetSampleSize(sample)
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            }
            writeJpeg(bitmap, destination, maxEdge)
        } catch (_: Exception) {
            false
        }
    }

    @JvmStatic
    fun videoThumbnail(path: String, destination: String, maxEdge: Int): Boolean {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(path)
            val frame = retriever.getFrameAtTime(
                0,
                MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
            ) ?: return false
            val rotation = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
                ?.toIntOrNull() ?: 0
            var bitmap = frame
            if (rotation % 360 != 0) {
                val matrix = android.graphics.Matrix()
                matrix.postRotate(rotation.toFloat())
                bitmap = Bitmap.createBitmap(
                    frame,
                    0,
                    0,
                    frame.width,
                    frame.height,
                    matrix,
                    true,
                )
            }
            writeJpeg(bitmap, destination, maxEdge)
        } catch (_: Exception) {
            false
        } finally {
            retriever.release()
        }
    }

    private fun writeJpeg(bitmap: Bitmap, destination: String, maxEdge: Int): Boolean {
        val longest = max(bitmap.width, bitmap.height)
        val scaled = if (longest > maxEdge) {
            val ratio = maxEdge.toFloat() / longest.toFloat()
            Bitmap.createScaledBitmap(
                bitmap,
                max(1, (bitmap.width * ratio).toInt()),
                max(1, (bitmap.height * ratio).toInt()),
                true,
            )
        } else {
            bitmap
        }
        val target = File(destination)
        target.parentFile?.mkdirs()
        return FileOutputStream(target).use { output ->
            scaled.compress(Bitmap.CompressFormat.JPEG, 90, output)
        }
    }

    private fun parseDate(value: String?): Long {
        if (value.isNullOrBlank()) return 0L
        val patterns = arrayOf(
            "yyyyMMdd'T'HHmmss.SSS'Z'",
            "yyyyMMdd'T'HHmmss'Z'",
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXX",
            "yyyy-MM-dd'T'HH:mm:ssXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'",
            "yyyy-MM-dd'T'HH:mm:ss'Z'",
        )
        for (pattern in patterns) {
            try {
                val format = SimpleDateFormat(pattern, Locale.US)
                format.timeZone = TimeZone.getTimeZone("UTC")
                return format.parse(value)?.time ?: 0L
            } catch (_: Exception) {
                // Try the next documented form.
            }
        }
        return 0L
    }
}
