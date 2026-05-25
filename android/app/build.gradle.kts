plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "io.disproid.receiver"
    compileSdk = 34
    ndkVersion = "27.2.12479018"

    defaultConfig {
        applicationId = "io.disproid.receiver"
        minSdk = 26
        targetSdk = 34
        versionCode = 1
        versionName = "0.4.0-phaseD"

        ndk {
            // 当面は実機(Lenovo Yoga Pad Pro)に合わせ arm64-v8a のみ。
            // OpenSSL も arm64-v8a だけクロスコンパイル済み。
            abiFilters += "arm64-v8a"
        }
        externalNativeBuild {
            cmake {
                // 純 C のため C++ STL 不要。
                arguments += "-DANDROID_STL=none"
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
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
