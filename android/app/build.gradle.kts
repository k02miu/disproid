plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "io.disproid.receiver"
    compileSdk = 34

    defaultConfig {
        applicationId = "io.disproid.receiver"
        minSdk = 26
        targetSdk = 34
        versionCode = 1
        versionName = "0.1.0-phaseA"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }

    // ソースを kotlin/ に置く（java/ ではなく）
    sourceSets["main"].java.srcDirs("src/main/kotlin")
}

dependencies {
    // 外部依存ゼロ: AndroidX/Compose/Material を使わず、フレームワーク API のみで実装する。
    // （NsdManager / app.Service / app.Activity / java.net.ServerSocket）
}
