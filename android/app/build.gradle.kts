plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.beadstudio.bead_studio"
    compileSdk = flutter.compileSdkVersion
    // 不声明 ndkVersion：原生层只有 Kotlin（OCR 后台线程通道），无 NDK
    // 代码，声明会触发 AGP 经 sdkmanager 自动下载 NDK（~600MB，且
    // sdkmanager 不走代理连不上 dl.google.com 导致构建挂死）

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.beadstudio.bead_studio"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            // 关闭 R8 混淆：Dart 已 AOT 编译，R8 只压 Java 插件层收益小；
            // 且 google_mlkit_text_recognition 引用的可选语种识别器
            // （chinese/japanese/korean/devanagari）不在 classpath，R8 缺类报错
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // MainActivity 自建 OCR 通道（bead_native_ocr）直接引用 ML Kit：
    // 插件模块的依赖是 implementation 不外漏，app 侧显式声明（版本对齐
    // gradle 缓存已有构件，离线构建不拉新）
    implementation("com.google.mlkit:text-recognition:16.0.1")
    implementation("com.google.android.gms:play-services-base:18.5.0")
}

flutter {
    source = "../.."
}
