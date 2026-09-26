allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// file_picker 11.0.2 는 AGP 9 이상이면 built-in Kotlin 을 가정하고 kotlin-android 를 적용하지 않는다. 이 앱은 다른 플러그인
// (in_app_review·package_info_plus·share_plus·workmanager_android 등)이 KGP 를 적용해 android.builtInKotlin=false 라서, 그대로면
// file_picker 의 Kotlin 소스가 컴파일되지 않는다(FilePickerPlugin 없음). Flutter Gradle Plugin 은 스크립트에 kotlin-android
// 문자열이 있어 자동 적용을 건너뛴다. 그래서 이 프로젝트에만 AGP 적용 직후 KGP 를 붙인다(FGP 가 KGP 없는 플러그인에 하는 것과 같음).
// 제거 조건: builtInKotlin=true 로 바꿀 때, 또는 file_picker 를 KGP 판단이 맞는 버전으로 올릴 때.
subprojects {
    if (name == "file_picker") {
        pluginManager.withPlugin("com.android.library") {
            pluginManager.apply("org.jetbrains.kotlin.android")
            extensions.configure<org.jetbrains.kotlin.gradle.dsl.KotlinAndroidProjectExtension> {
                compilerOptions.jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
