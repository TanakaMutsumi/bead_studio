import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:bead_studio/core/douyin_link.dart';

void main() {
  group('extractDouyinLink', () {
    test('从分享文案提取短链（前后贴中文/emoji/数字）', () {
      const text = '7.92 复制打开抖音，看看【你困不困啊的图文作品】耍起！'
          '# steamhappy # 拼豆图纸 # … https://v.douyin.com/6ARM84jrb5w/ '
          's@r.EU 05/25 :5pm wSl:/ 4.87';
      expect(extractDouyinLink(text), 'https://v.douyin.com/6ARM84jrb5w/');
    });

    test('提取直链（share/note 与 douyin.com/note）', () {
      expect(
        extractDouyinLink('看 https://www.iesdouyin.com/share/note/'
            '7696956677741325050/?a=1 好'),
        'https://www.iesdouyin.com/share/note/7696956677741325050/?a=1',
      );
      expect(
        extractDouyinLink('https://www.douyin.com/note/7687190758894337000'),
        'https://www.douyin.com/note/7687190758894337000',
      );
    });

    test('无链接返回 null，不误抓其他域名', () {
      expect(extractDouyinLink('https://xhslink.cn/abc 洛天依'), isNull);
      expect(extractDouyinLink('没有链接的文案'), isNull);
    });
  });

  group('_parseNote（真实 SSR fixture）', () {
    final html = File('test/fixtures/douyin_share_ssr.html').readAsStringSync();
    final note = parseDouyinNoteHtmlForTest(html)!;

    test('解析出标题与全部正文图', () {
      // fixture = 洛天依拼豆图纸（3 张正文图）
      expect(note.images, hasLength(3));
      expect(note.title, contains('拼豆'));
    });

    test('全是 q75 签名 URL，多镜像已去重', () {
      final keys = note.images.map((e) => e.uriKey).toSet();
      expect(keys, hasLength(note.images.length));
      for (final img in note.images) {
        expect(img.url, contains('~tplv-dy-aweme-images'));
        expect(img.url, startsWith('https://'));
      }
    });

    test('混入的分享卡缩略图（自定义模板规格）被排除', () {
      for (final img in note.images) {
        expect(img.url.contains('p14lwwcsbr'), isFalse);
      }
    });
  });
}
