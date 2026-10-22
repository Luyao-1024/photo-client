package com.photoviewer.photo_client

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.Settings
import android.system.Os
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        init {
            // Load through the JVM first so JNI_OnLoad can cache the app class
            // loader, then hand the bridge class to Rust. Dart later reopens
            // the same library.
            System.loadLibrary("photo_bridge")
            AndroidMediaBridge.ensureInitialized()
        }

        private const val MEDIA_PERMISSION_REQUEST = 41
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        // Rust's std::env::temp_dir() follows TMPDIR. Android ships no writable
        // /tmp, so point temp files at the app cache before the core starts.
        try {
            Os.setenv("TMPDIR", cacheDir.absolutePath, true)
        } catch (_: Exception) {
        }
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "photo_client/android")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "paths" -> result.success(
                        mapOf(
                            "filesDir" to filesDir.absolutePath,
                            "cacheDir" to cacheDir.absolutePath,
                            "externalRoot" to Environment.getExternalStorageDirectory().absolutePath,
                            "hasAllFiles" to hasAllFilesAccess(),
                            "sdk" to Build.VERSION.SDK_INT,
                        ),
                    )
                    "hasAllFiles" -> result.success(hasAllFilesAccess())
                    "requestAllFiles" -> {
                        requestAllFilesAccess()
                        result.success(null)
                    }
                    "requestMediaPermissions" -> {
                        requestMediaPermissions()
                        result.success(null)
                    }
                    "appSettings" -> {
                        startActivity(
                            Intent(
                                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                Uri.fromParts("package", packageName, null),
                            ),
                        )
                        result.success(null)
                    }
                    "mediaScan" -> {
                        val paths = call.arguments as? List<*>
                        val files = paths
                            ?.mapNotNull { it as? String }
                            ?.filter { it.startsWith("/") }
                            .orEmpty()
                        if (files.isNotEmpty()) {
                            MediaScannerConnection.scanFile(this, files.toTypedArray(), null, null)
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun hasAllFilesAccess(): Boolean = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        Environment.isExternalStorageManager()
    } else {
        checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
    }

    private fun requestAllFilesAccess() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                startActivity(
                    Intent(
                        Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                        Uri.parse("package:$packageName"),
                    ),
                )
            } catch (_: Exception) {
                startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
            }
        } else {
            requestPermissions(
                arrayOf(
                    Manifest.permission.READ_EXTERNAL_STORAGE,
                    Manifest.permission.WRITE_EXTERNAL_STORAGE,
                ),
                MEDIA_PERMISSION_REQUEST,
            )
        }
    }

    private fun requestMediaPermissions() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            requestPermissions(
                arrayOf(
                    Manifest.permission.READ_MEDIA_IMAGES,
                    Manifest.permission.READ_MEDIA_VIDEO,
                ),
                MEDIA_PERMISSION_REQUEST,
            )
        } else if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            requestPermissions(
                arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE),
                MEDIA_PERMISSION_REQUEST,
            )
        }
    }
}
