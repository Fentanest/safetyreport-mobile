import java.util.Properties

plugins {
    id("com.android.application")
    // kotlin-android 는 적용하지 않는다(AGP 9). builtInKotlin=false 동안 Flutter Gradle Plugin 이 붙인다.
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// key.properties 로드 (서명 설정용)
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(keystorePropertiesFile.inputStream())
}
// 서명키가 없을 때 release 를 debug 키로 조용히 서명하지 않는다. 검증용 빌드만 ALLOW_DEBUG_SIGNED_RELEASE=1 로 허용하고,
// 빌드 스크립트가 산출물 이름·메타에 debug 서명을 표시한다(배포용 성공으로 취급하지 않는다).
val allowDebugSignedRelease = System.getenv("ALLOW_DEBUG_SIGNED_RELEASE") == "1"

android {
    namespace = "com.fentanest.mysafetyreport"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.fentanest.mysafetyreport"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = when {
                keystorePropertiesFile.exists() -> signingConfigs.getByName("release")
                allowDebugSignedRelease -> signingConfigs.getByName("debug")
                else -> null
            }
            // R8(코드 축소·난독화·최적화)과 리소스 축소를 명시한다(Flutter Gradle Plugin 기본값과 같은 값).
            // AGP 9 는 optimized resource shrinking 이 기본. 끄거나 전체 keep 으로 우회하지 않는다.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

// 서명키도 명시 허용도 없으면 release 패키징을 멈춘다(unsigned·debug 서명 산출물이 배포 경로로 새지 않게).
if (!keystorePropertiesFile.exists() && !allowDebugSignedRelease) {
    tasks.configureEach {
        if (name == "packageRelease" || name == "signReleaseBundle") {
            doFirst {
                throw GradleException(
                    "release 서명키(android/key.properties)가 없습니다. 배포용은 build_android_release.sh 로 서명키를 배치하고, " +
                        "검증용 debug 서명 빌드만 ALLOW_DEBUG_SIGNED_RELEASE=1 로 실행하세요.",
                )
            }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // WebSocket 클라이언트 (WsService용)
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
}
