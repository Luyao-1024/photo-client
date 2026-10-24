package com.photoviewer.photo_client

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ImageDecoder
import android.media.ExifInterface
import android.media.MediaMetadataRetriever
import android.media.MediaCodecList
import android.os.SystemClock
import android.util.Log
import android.os.Environment
import androidx.annotation.Keep
import java.io.File
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.max

/**
 * Called from the Rust core over JNI. Android owns platform image/video decoding so the
 * catalog and thumbnail pipeline stay identical to the Linux core.
 */
@Keep
object AndroidMediaBridge {
    private external fun nativeBind()

    init {
        nativeBind()
    }

    /** Forces class initialization so Rust caches this class before any scan. */
    fun ensureInitialized() {
        val hardware = try {
            MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos
                .filter { !it.isEncoder && it.isHardwareAccelerated && !it.name.endsWith(".secure") }
                .joinToString(";") { codec -> "${codec.name}:${codec.supportedTypes.joinToString(",")}" }
        } catch (_: Exception) { "unavailable" }
        Log.i("PhotoDecode", "policy=platform-first hardware_decoders=$hardware")
    }

    private val reportedImageTypes = ConcurrentHashMap.newKeySet<String>()

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
        val started = SystemClock.elapsedRealtime()
        var bitmap: Bitmap? = null
        var mime = "unknown"
        return try {
            if (maxEdge <= 0) return false
            val source = ImageDecoder.createSource(File(path))
            val decoded = ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
                mime = info.mimeType
                require(info.size.width.toLong() * info.size.height <= 256L * 1024 * 1024)
                val longest = max(info.size.width, info.size.height)
                val ratio = minOf(1.0, maxEdge.toDouble() / longest)
                decoder.setTargetSize(
                    max(1, (info.size.width * ratio).toInt()),
                    max(1, (info.size.height * ratio).toInt()),
                )
                // This selects the cache encoder's CPU-readable output memory,
                // not the underlying codec. HEIF can still use MediaCodec hardware.
                // A GPU bitmap would add an upload/readback before JPEG encoding.
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            }
            bitmap = decoded
            val success = writeJpeg(decoded, destination, maxEdge)
            val elapsed = SystemClock.elapsedRealtime() - started
            if (reportedImageTypes.add(mime) || elapsed >= 250) {
                Log.i("PhotoDecode", "image_decode backend=android-platform mime=$mime max_edge=$maxEdge elapsed_ms=$elapsed result=${if (success) "complete" else "failed"}")
            }
            success
        } catch (error: Exception) {
            Log.w("PhotoDecode", "image_decode backend=android-platform mime=$mime result=failed error=${error.javaClass.simpleName}")
            false
        } finally {
            bitmap?.recycle()
        }
    }

    @JvmStatic
    fun videoThumbnail(path: String, destination: String, maxEdge: Int): Boolean {
        val retriever = MediaMetadataRetriever()
        var frame: Bitmap? = null
        return try {
            if (maxEdge <= 0) return false
            retriever.setDataSource(path)
            // Keep the platform's hardware-capable media codec path, requesting
            // a bounded frame instead of materialising a full 4K/8K bitmap.
            val decoded = try {
                retriever.getScaledFrameAtTime(
                    0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, maxEdge, maxEdge,
                )
            } catch (_: Exception) { null }
                ?: retriever.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                ?: return false
            frame = decoded
            // The retriever already applies the container display matrix.
            // Rotating again by METADATA_KEY_VIDEO_ROTATION turns portrait
            // clips sideways; the platform's own ThumbnailUtils relies on the
            // returned frame as-is too.
            writeJpeg(decoded, destination, maxEdge)
        } catch (_: Exception) {
            false
        } finally {
            frame?.recycle()
            retriever.release()
        }
    }

    private fun writeJpeg(bitmap: Bitmap, destination: String, maxEdge: Int): Boolean {
        val longest = max(bitmap.width, bitmap.height)
        val scaled = if (longest > maxEdge) {
            val ratio = maxEdge.toFloat() / longest.toFloat()
            Bitmap.createScaledBitmap(
                bitmap, max(1, (bitmap.width * ratio).toInt()),
                max(1, (bitmap.height * ratio).toInt()), true,
            )
        } else bitmap
        var opaque: Bitmap? = null
        return try {
            // Match the shared thumbnail encoder's white alpha composition.
            val outputBitmap = if (scaled.hasAlpha()) {
                Bitmap.createBitmap(scaled.width, scaled.height, Bitmap.Config.ARGB_8888).also {
                    opaque = it
                    val canvas = Canvas(it)
                    canvas.drawColor(Color.WHITE)
                    canvas.drawBitmap(scaled, 0f, 0f, null)
                }
            } else scaled
            val target = File(destination)
            target.parentFile?.mkdirs()
            FileOutputStream(target).use { output ->
                outputBitmap.compress(Bitmap.CompressFormat.JPEG, 90, output)
            }
        } finally {
            opaque?.recycle()
            if (scaled !== bitmap) scaled.recycle()
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
