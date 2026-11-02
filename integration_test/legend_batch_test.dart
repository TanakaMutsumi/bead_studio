// 图例识别批量集成测试：脱离 UI、直接在设备进程里跑完整链路
// （Skia 解码 -> detectLegendCanonical 自动框图例 -> runLegendOcr 真实
// ML Kit OCR + 融合），每张图产出放大图/日志/结果供离线标注复核。
//
// 用法（仓库根目录）：
//   flutter test integration_test/legend_batch_test.dart -d <device>
// 输入图片内嵌在 testpics_data.dart（自动生成，base64）——设备上任何
// app 数据目录都不可靠：flutter test 重装 APK 清 cache，结束后卸载 app
// 且卸载的延迟清理还会把 external files 目录连同刚推上去的文件一起清掉
//（安装-推送-异步清理三方竞态实测无解）。内嵌进测试编译产物零设备依赖。
// 重新生成（.test 图片更新后）：
//   python -c 见本文件 git 历史或 legend_batch_test 生成脚本注释
// 产物写到 app external files 目录：测试运行期间稳定可读，宿主机循环
// adb pull 回拉（app 卸载后目录会被清，不能等测试结束再拉）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:bead_studio/core/decode_image.dart';
import 'package:bead_studio/core/legend_detect.dart';
import 'package:bead_studio/core/palette_registry.dart';
import 'package:bead_studio/features/restore/legend_ocr_runner.dart';

import 'testpics_data.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    '图例识别批量：自动框选+OCR+融合（t1-t4 用户四张竖条图例）',
    (tester) async {
      // t4（微信 _198054_11，三行竖条 15/14/7 条目）放首位：app 卸载竞态只吞
      // 末位图片的产物（缩放图/日志），首位的产物在运行中段就被宿主拉回
      const names = ['t4', 't1', 't2', 't3'];
      final tmp = await getExternalStorageDirectory();
      final base = tmp?.path ?? (await getTemporaryDirectory()).path;
      final pal = await PaletteRegistry.loadSelected();
      final summary = <String>[
        'palette=${pal.id} ${pal.palette.colors.length}色',
      ];
      for (final n in names) {
        final picBytes = kTestPics[n];
        if (picBytes == null) {
          summary.add('$n: 图片缺失（kTestPics 无此键）');
          continue;
        }
        final sw = Stopwatch()..start();
        final image = await decodeImageRobust(base64Decode(picBytes));
        summary.add(
          '$n: 解码OK ${image.width}x${image.height} ${sw.elapsedMilliseconds}ms',
        );
        final det = detectLegendCanonical(image);
        if (det == null) {
          summary.add('$n: 自动框图例 null');
          continue;
        }
        summary.add(
          '$n: 框(${det.left},${det.top} ${det.right - det.left}x'
          '${det.bottom - det.top})',
        );
        sw.reset();
        final run = await runLegendOcr(
          image,
          pal.palette,
          det.left.toDouble(),
          det.top.toDouble(),
          (det.right - det.left).toDouble(),
          (det.bottom - det.top).toDouble(),
          source: '自动扫描',
        );
        summary.add(
          '$n: OCR ${sw.elapsedMilliseconds}ms pairs=${run.pairs?.length ?? 'null'} '
          'segFails=${run.segFails} 色卡外=${run.orphanNotes.toSet().join("/")}',
        );
        // 日志关键行（框选/result=）直接进 stdout：app 卸载竞态会连 external
        // 产物目录一起清掉，靠设备文件不可靠（t4 复测实际踩中）
        final cachePath = (await getTemporaryDirectory()).path;
        final log = File('$cachePath/legend_ocr_log.txt');
        if (log.existsSync()) {
          for (final l in log.readAsLinesSync()) {
            if (l.startsWith('框选') || l.startsWith('result=')) {
              summary.add('$n| $l');
            }
          }
          log.deleteSync();
        }
        // 放大图仍归档到 external（宿主侧尽早 adb pull；卸载竞态时丢失）
        final png = File('$cachePath/legend_ocr.png');
        if (png.existsSync()) {
          png.copySync('$base/${n}_scaled.png');
          png.deleteSync();
        }
      }
      File('$base/batch_summary.txt').writeAsStringSync(
        summary.join('\n'),
      );
      // 汇总进测试输出，CI/本地失败报告里也能看
      for (final l in summary) {
        // ignore: avoid_print
        print('[batch] $l');
      }
      expect(summary.length, greaterThan(1));
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
