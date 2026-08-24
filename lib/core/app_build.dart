/// 应用构建标识
///
/// 构建时间戳由交付构建命令注入：--dart-define=BUILD_TS=MM-dd_HH:mm:ss。
/// 直接 flutter run / 未注入时为空串，界面显示「自编译」——
/// 帮助区分「模拟器上跑的到底是哪次构建」（现场排障用）。
const String appBuildStamp = String.fromEnvironment("BUILD_TS");

/// 界面显示用的构建标识（空则标注自编译）
String get appBuildLabel => appBuildStamp.isEmpty ? "自编译" : appBuildStamp;
