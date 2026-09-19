import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Signing rilis dipin ke keystore project (android/app/pos-signing.jks) agar
// tanda tangan APK KONSISTEN di semua build/mesin → update menimpa selalu
// dikenali (install -r), data lama TIDAK terhapus. Fallback ke debug bila
// key.properties tidak ada.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.candradigital.pos_resto"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.candradigital.pos_resto"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // versionCode otomatis dari waktu build (detik epoch dikurangi offset
        // 2023-11-14). Selalu naik tiap build → update menimpa di tablet selalu
        // dikenali sebagai versi baru, tanpa perlu edit pubspec.
        // Tetap jauh di bawah batas Android (2.100.000.000), aman s/d ~th 2089.
        // Split-per-abi menambah offset ABI (×1000) di atas nilai ini.
        versionCode = ((System.currentTimeMillis() / 1000) - 1_700_000_000L).toInt()
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String?
            keyPassword = keystoreProperties["keyPassword"] as String?
            storeFile = (keystoreProperties["storeFile"] as String?)?.let { file(it) }
            storePassword = keystoreProperties["storePassword"] as String?
        }
    }

    buildTypes {
        release {
            // Pakai keystore project bila ada (tanda tangan konsisten antar build);
            // selain itu fallback ke debug agar tetap bisa build.
            signingConfig = if (keystorePropertiesFile.exists())
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
