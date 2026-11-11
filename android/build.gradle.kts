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
// 部分外掛（onnxruntime 1.4.1）把 compileSdk 寫死為 33，低於其 AndroidX 相依套件要求的 34，
// 導致 checkAarMetadata 失敗。統一提高到 36（只影響編譯用的 API 版本，不改 minSdk / targetSdk）。
// 必須在 evaluationDependsOn 之前註冊，才能在 Android 外掛讀取設定前生效。
subprojects {
    afterEvaluate {
        extensions.findByType(com.android.build.api.dsl.LibraryExtension::class.java)?.let { android ->
            if ((android.compileSdk ?: 0) < 36) android.compileSdk = 36
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
