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
        // mavenCentral 直连超时（2026-11-06 实测），阿里云镜像补位；
        // google() 直连可达保持原位
        maven(url = "https://maven.aliyun.com/repository/central")
        maven(url = "https://maven.aliyun.com/repository/gradle-plugin")
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

// 三方插件（如 webview_flutter_android）自带 buildscript{repositories}，
// pluginManagement 管不到：mavenCentral 直连 DNS 不通会让其
// kotlin-gradle-plugin 解析失败。给每个项目（含插件子项目）的 buildscript
// 仓库表前插镜像（additive，先到先用）
gradle.beforeProject {
    buildscript {
        repositories {
            maven(url = "https://maven.aliyun.com/repository/central")
            maven(url = "https://maven.aliyun.com/repository/google")
        }
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.1.0" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
}

include(":app")
