import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:bead_studio/core/xhs_link.dart';

/// 小红书链接解析单测：链接提取走合成样例；页面解析用 2026-11-03 实存
/// 的爱莉希雅笔记 SSR HTML（.test/ 已 gitignore，素材不在时跳过——
/// 该用例主要在开发机回归"页面结构变更导致的解析回退"）。
void main() {
  group('extractXhsLink', () {
    test('从分享文案提取短链', () {
      const text = '存好内容，去【小红书】一睹为快~ https://xhslink.cn/o/3WbxX6zX9kF';
      expect(extractXhsLink(text), 'https://xhslink.cn/o/3WbxX6zX9kF');
    });

    test('提取笔记直链（带 xsec_token）', () {
      const text =
          'https://www.xiaohongshu.com/explore/6a5c8bfd?xsec_token=ABC123&xsec_source=app_share';
      expect(
        extractXhsLink(text),
        startsWith('https://www.xiaohongshu.com/explore/6a5c8bfd'),
      );
    });

    test('discovery/item 分享链也可识别', () {
      const text = '看这个 http://www.xiaohongshu.com/discovery/item/abc?xsec_token=x';
      expect(extractXhsLink(text), isNotNull);
    });

    test('整段真实分享文案（标题+描述+链接+口号）', () {
      const text = '爱莉希雅拼豆图纸 里面h1全部换成h2，然后有一些h18在... '
          'https://xhslink.cn/o/3WbxX6zX9kF 存好内容，去【小红书】一睹为快~';
      expect(extractXhsLink(text), 'https://xhslink.cn/o/3WbxX6zX9kF');
    });

    test('链接紧贴中文标点（无空格分隔）不吞标点', () {
      expect(
        extractXhsLink('看这个https://xhslink.cn/o/3WbxX6zX9kF，很好看'),
        'https://xhslink.cn/o/3WbxX6zX9kF',
      );
      expect(
        extractXhsLink('图纸在https://xhslink.cn/o/3WbxX6zX9kF。'),
        'https://xhslink.cn/o/3WbxX6zX9kF',
      );
    });

    test('链接后紧跟 emoji 不吞入 URL', () {
      expect(
        extractXhsLink('https://xhslink.cn/o/3WbxX6zX9kF🎉快看'),
        'https://xhslink.cn/o/3WbxX6zX9kF',
      );
    });

    test('无链接返回 null', () {
      expect(extractXhsLink('普通文本'), isNull);
    });
  });

  group('parseNote（实存 HTML 夹具）', () {
    final fixture = File('.test/xhs_note.html');
    test('解析出 4 张图 + 原图路径', () {
      if (!fixture.existsSync()) {
        // 素材只在开发机（.test/ 不入库），CI/新 clone 跳过
        return;
      }
      final note = parseXhsNoteHtmlForTest(fixture.readAsStringSync());
      expect(note, isNotNull);
      expect(note!.images, hasLength(4));
      final img0 = note.images.first;
      // 页面元数据里的原始尺寸
      expect(img0.width, 6400);
      expect(img0.height, 6400);
      // 缩略图是签名 1080 URL
      expect(img0.thumbUrl, contains('!h5_1080jpg'));
      // 原图路径保留 notes_pre_post 段（丢了即 404 的那个坑）
      expect(
        img0.originalPath,
        'notes_pre_post/1040g3k0322pdpo2b705g5orr4ntnri2h3crn5lo',
      );
      expect(img0.originalUrl,
          'https://sns-img-bd.xhscdn.com/notes_pre_post/1040g3k0322pdpo2b705g5orr4ntnri2h3crn5lo');
      // 无前缀的老图路径不含多余段
      expect(
        note.images.map((e) => e.originalPath),
        contains('1040g2sg323jgs51d72kg5orr4ntnri2hrt02d60'),
      );
    });

    test('垃圾 HTML 返回 null', () {
      expect(parseXhsNoteHtmlForTest('<html></html>'), isNull);
    });

    test('视频笔记抛业务异常', () {
      const html =
          '<script>window.__INITIAL_STATE__={"noteData":{"data":{"noteData":'
          '{"type":"video","imageList":[]}}}}</script>';
      expect(() => parseXhsNoteHtmlForTest(html),
          throwsA(isA<XhsLinkException>()));
    });

    test('PC 版 noteDetailMap 路径可解析（含 undefined/Map 字面量清洗）', () {
      const html =
          '<script>window.__INITIAL_STATE__={"note":{"noteDetailMap":'
          '{"abc":{"note":{"type":"normal","title":"t",'
          '"imageList":[{"width":3,"height":4,"url":'
          '"http://sns-webpic-qc.xhscdn.com/20261103/299416b4dfb515a98775b4c54b54eabc/notes_pre_post/1040g3k0322pdpo2b70305orr4ntnri2h2i8spdo!h5_1080jpg",'
          '"infoList":[{"imageScene":"H5_DTL","url":"http://sns-webpic-qc.xhscdn.com/20261103/299416b4dfb515a98775b4c54b54eabc/notes_pre_post/1040g3k0322pdpo2b70305orr4ntnri2h2i8spdo!h5_1080jpg"}]}]}}}},'
          '"AiNoteDetailStore":{"noteDetailMap":new Map([])},"X":undefined}</script>';
      final note = parseXhsNoteHtmlForTest(html);
      expect(note, isNotNull);
      expect(note!.title, 't');
      final img = note.images.single;
      expect(img.width, 3);
      // http 强制转 https
      expect(img.thumbUrl, startsWith('https://'));
      expect(
        img.originalPath,
        'notes_pre_post/1040g3k0322pdpo2b70305orr4ntnri2h2i8spdo',
      );
    });
  });
}
