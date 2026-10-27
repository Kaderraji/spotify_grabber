import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) FileInputStream(file).use { load(it) }
}

android {
    namespace = "com.spotifygrabber.spotify_grabber"
    compileSdk = flutter.compileSdkVersion
    // AGP 9 needs an NDK even for apps without native code. The location comes
    // from ndk.dir in android/local.properties (git-ignored): on this machine
    // the NDK lives on another partition.
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Changing this makes Android treat the app as a new one: the installed
        // app, its preferences and its saved history do not come along.
        applicationId = "com.spotifygrabber.spotify_grabber"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        // Package arm64 only. yt-dlp, ffmpeg and deno ship as native libraries
        // for four ABIs and only one is ever loaded on a phone, so the other
        // three were ~120 MB of dead weight that also slowed install and first
        // launch. Remove this filter to build for an x86 emulator.
        ndk {
            abiFilters.add("arm64-v8a")
        }
    }

    // The release key lives in android/upload-keystore.jks with its passwords
    // in android/key.properties; both are git-ignored. Keep them somewhere
    // safe: Android only installs an update signed with the same key.
    signingConfigs {
        if (keystoreProperties.isNotEmpty()) {
            create("release") {
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // Falls back to the debug key when there is no key.properties, so a
            // fresh clone can still build and run in release mode.
            signingConfig = if (keystoreProperties.isNotEmpty()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }

    // youtubedl-android ships Python/yt-dlp/ffmpeg as .so files that have to be
    // extracted at install time so they can be executed.
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }
}

dependencies {
    // NotificationCompat and ContextCompat.startForegroundService.
    implementation("androidx.core:core:1.13.1")
    implementation("io.github.junkfood02.youtubedl-android:library:0.18.1")
    implementation("io.github.junkfood02.youtubedl-android:ffmpeg:0.18.1")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
