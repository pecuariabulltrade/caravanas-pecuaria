import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// Firma estable (opcional): si existe el keystore (lo genera el workflow desde un secret), se usa;
// si no, el APK sale firmado con la clave debug (hay que desinstalar antes de instalar otra versión).
val keystoreFile = rootProject.file("keystore/manga.jks")
val keystoreProps = Properties().apply {
    val f = rootProject.file("keystore/manga.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}

android {
    namespace = "com.pecuariabulltrade.manga"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.pecuariabulltrade.manga"
        minSdk = 26
        targetSdk = 35
        versionCode = (System.getenv("APP_VERSION_CODE") ?: "1").toInt()
        versionName = System.getenv("APP_VERSION_NAME") ?: "1.0.0"
    }

    signingConfigs {
        if (keystoreFile.exists()) {
            create("manga") {
                storeFile = keystoreFile
                storePassword = keystoreProps.getProperty("storePassword", "")
                keyAlias = keystoreProps.getProperty("keyAlias", "manga")
                keyPassword = keystoreProps.getProperty("keyPassword", "")
            }
        }
    }

    buildTypes {
        getByName("release") {
            isMinifyEnabled = false
            signingConfig = if (keystoreFile.exists()) signingConfigs.getByName("manga") else signingConfigs.getByName("debug")
        }
        getByName("debug") {
            if (keystoreFile.exists()) signingConfig = signingConfigs.getByName("manga")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("androidx.activity:activity-ktx:1.9.3")
    implementation("androidx.webkit:webkit:1.12.1")
    implementation("com.github.mik3y:usb-serial-for-android:3.8.1")
}
