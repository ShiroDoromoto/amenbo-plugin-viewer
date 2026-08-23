import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The upload key lives outside the repository; key.properties points at it.
// Without that file — on a machine that only runs the app — the release build
// falls back to the debug key, so `flutter run --release` still works.
val keystoreProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}

android {
    namespace = "work.amenbo.viewer"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "work.amenbo.viewer"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Three apps, not three builds of one: what is being tried out must never land on top of
    // what someone uses every day. The version and the build number stay shared — only the
    // identifier and the name on the home screen move.
    //
    // The namespace above stays `work.amenbo.viewer` on all three: it names the Kotlin package
    // and the generated R class, and the method channels are written against it. Only
    // `applicationId` — what the device installs under — takes a suffix.
    flavorDimensions += "identity"

    productFlavors {
        create("local") {
            dimension = "identity"
            applicationIdSuffix = ".local"
            manifestPlaceholders["appName"] = "Amenbo Local"
        }
        create("dev") {
            dimension = "identity"
            applicationIdSuffix = ".dev"
            manifestPlaceholders["appName"] = "Amenbo Dev"
        }
        create("store") {
            dimension = "identity"
            manifestPlaceholders["appName"] = "Amenbo Viewer"
        }
    }

    signingConfigs {
        if (keystoreProperties.isNotEmpty()) {
            create("upload") {
                storeFile = keystoreProperties.getProperty("storeFile")?.let { file(it) }
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // Play refuses a bundle signed with the debug key, so a release
            // meant for the store has to be built where key.properties exists.
            signingConfig = signingConfigs.findByName("upload")
                ?: signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
