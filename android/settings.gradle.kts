pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    // Flutter 3.47.5 템플릿·검증 조합(tool/flutter-version). AGP 9 는 Flutter 3.47 이 지원(최대 9.2), JDK 17+.
    id("com.android.application") version "9.1.0" apply false
    // builtInKotlin=false(gradle.properties) 동안 Flutter Gradle Plugin 이 kotlin-android 를 붙일 때 쓰는 KGP.
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
}

include(":app")
