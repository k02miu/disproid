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
        versionName = "0.5.0"

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
    // UI は Material 3 を使用（見栄え重視）。コア機能(NsdManager/Service/JNI)は引き続き
    // フレームワーク API のみ。
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
    implementation("androidx.core:core-splashscreen:1.0.1")
}
