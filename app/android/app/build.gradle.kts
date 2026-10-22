plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.photoviewer.photo_client"
    compileSdk = flutter.compileSdkVersion
    // Match the NDK used by tools/platform for the Rust Android targets.
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.photoviewer.photo_client"
        // Android 11 is the first release with the all-files access contract the
        // path-based library needs for a Linux-equivalent photo manager.
        minSdk = 30
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // Signed with the debug key so `flutter build apk --release` and
            // `tools/run_app android --build` install directly. Replaced when a
            // distribution keystore is configured.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    packaging {
        jniLibs {
            // Dart opens libphoto_bridge.so by soname; extracted libraries are
            // reachable from the app's nativeLibraryDir on every Android release.
            useLegacyPackaging = true
        }
    }
}

dependencies {
    implementation("androidx.annotation:annotation:1.9.1")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
