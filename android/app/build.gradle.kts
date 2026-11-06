import java.security.MessageDigest
import java.net.URI

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
        versionName = "1.0.0"

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

// Generated, offline-readable notices are part of every APK, not a manual release step.
val ossAssets = layout.buildDirectory.dir("generated/ossAssets")
val runtimeArtifacts = provider { configurations.getByName("debugRuntimeClasspath") }
val prepareOssNotices = tasks.register<Exec>("prepareOssNotices") {
    // Git revision/dirty state and resolved dependency hashes must be refreshed each build.
    outputs.upToDateWhen { false }
    doFirst {
        val args = mutableListOf("python3", rootProject.file("../scripts/distribution.py").path,
            "notices", "--output", ossAssets.get().dir("oss").asFile.path)
        runtimeArtifacts.get().resolvedConfiguration.resolvedArtifacts.sortedBy { it.file.name }.forEach {
            args.addAll(listOf("--artifact", it.file.path))
        }
        commandLine(args)
    }
}
android.sourceSets["main"].assets.srcDir(ossAssets)
tasks.named("preBuild").configure { dependsOn(prepareOssNotices) }

// Source releases include sources for the actual resolved runtime graph, including transitives.
tasks.register("collectRuntimeSources") {
    doLast {
        val output = layout.buildDirectory.dir("oss-sources").get().asFile
        output.deleteRecursively()
        output.mkdirs()
        val missing = mutableListOf<String>()
        val entries = runtimeArtifacts.get().resolvedConfiguration.resolvedArtifacts
            .distinctBy { it.moduleVersion.id }.sortedBy { it.moduleVersion.id.toString() }.mapNotNull { artifact ->
                val id = artifact.moduleVersion.id
                val coordinate = "${id.group}:${id.name}:${id.version}"
                val base = "${id.group}-${id.name}-${id.version}"
                fun sha(file: File) = MessageDigest.getInstance("SHA-256")
                    .digest(file.readBytes()).joinToString("") { "%02x".format(it) }
                fun fetch(suffix: String, filename: String): File {
                    val dep = dependencies.create("$coordinate$suffix")
                    val config = configurations.detachedConfiguration(dep).apply { isTransitive = false }
                    val file = config.singleFile // Fail closed if corresponding sources are unavailable.
                    return file.copyTo(output.resolve(filename), overwrite = true)
                }
                // Google Maven did not publish source JARs for these 2.0.1 modules.
                // Official tag 2.0.1 imports this version; build.gradle confirms both coordinates.
                val sourceOrigin = if (id.group == "androidx.constraintlayout" && id.version == "2.0.1" &&
                    id.name in setOf("constraintlayout", "constraintlayout-solver"))
                    "https://codeload.github.com/androidx/constraintlayout/tar.gz/272719edf76066c3bee82987012da9349c760233"
                    else "maven:$coordinate:sources@jar"
                val source = try {
                    if (sourceOrigin.startsWith("https:")) {
                        output.resolve("androidx-constraintlayout-2.0.1.tar.gz").also { file ->
                            if (!file.exists()) URI(sourceOrigin).toURL().openStream().use { input -> file.outputStream().use { input.copyTo(it) } }
                            check(sha(file) == "ea687071fb3a30cedcf4037d693f0c10ab6864e6fad4a6f9f7f90f91919654ea") {
                                "ConstraintLayout source archive checksum mismatch"
                            }
                        }
                    } else fetch(":sources@jar", "$base-sources.jar")
                } catch (e: org.gradle.api.artifacts.ResolveException) {
                    missing.add(coordinate)
                    return@mapNotNull null
                }
                val pom = fetch("@pom", "$base.pom")
                mapOf("coordinate" to coordinate, "source" to source.name, "pom" to pom.name,
                    "source_sha256" to sha(source), "pom_sha256" to sha(pom),
                    "binary_sha256" to sha(artifact.file), "source_origin" to sourceOrigin)
            }
        check(missing.isEmpty()) { "Missing corresponding source artifacts: ${missing.joinToString()}. Do not publish binaries without these sources." }
        output.resolve("dependencies.json").writeText(groovy.json.JsonOutput.prettyPrint(groovy.json.JsonOutput.toJson(entries)) + "\n")
    }
}
