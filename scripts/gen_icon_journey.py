# -*- coding: utf-8 -*-
"""「豆田」图标设计迭代长图:13 稿 + 5 轮用户反馈,一张图讲完
用法: python scripts/gen_icon_journey.py   -> docs/icon_design_journey.png
"""
import os, sys
from PIL import Image, ImageDraw, ImageFont
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_app_icon as g

ROOT = g.ROOT
W, MARGIN = 1240, 60
CARD_ICON = 210
FINAL_ICON = 300

F = lambda sz, bold=False: ImageFont.truetype(
    os.path.join(ROOT, 'assets', 'fonts',
                 'NotoSansSC-Bold.otf' if bold else 'NotoSansSC-Regular.otf'), sz)

BG = (244, 245, 247)
CARD, CARD_BD = (255, 255, 255), (224, 227, 232)
INK, SUB = (34, 36, 40), (138, 143, 152)
GREEN = (62, 142, 62)
BUBBLE, BUBBLE_BD, BUBBLE_TX = (231, 245, 219), (191, 224, 166), (47, 74, 42)
GOLD = (232, 195, 74)

ROUNDS = [
    dict(title='第 1 轮 · 圆豆初稿', keys='ABC', cap=['九宫豆田', '田字四豆', '彩虹豆田'],
         quote='观感不佳：希望去掉圆形元素，改用渐变过渡色，或尝试方格方案',
         note='调整 → 去掉所有圆豆，改走渐变过渡色 + 方格构成'),
    dict(title='第 2 轮 · 渐变方格', keys='DEF', cap=['渐变方格', '渐变田', '方格豆阶'],
         quote='抽象几何仍不理想：希望参考真实拼豆作品的视觉样式来设计',
         note='调整 → 回到拼豆本体：格板上用一颗颗豆拼出图案'),
    dict(title='第 3 轮 · 拼豆成品风', keys='GHI', cap=['拼豆豆苗(圆豆)', '拼豆田字·四金豆(圆豆)', '方豆豆苗'],
         quote='圆形豆子依然不要；豆苗这一意象获得认可',
         note='调整 → 豆苗意象保留，圆豆全部换成方豆'),
    dict(title='第 4 轮 · 方豆豆苗', keys='JKL', cap=['原比例', '大叶版', '大叶无土版'],
         quote='豆苗排布认可「原比例」一稿；格子样式需对齐正常拼豆图纸的样子',
         note='调整 → 沿用 J 的豆苗排布，格子改成正常拼豆图纸的完整格线'),
]
FINAL_NOTE = ['纸底 · 填色格紧贴格线 · 覆盖式格线 + 圆角外框',
              '已铺满 Android 自适应图标(背景/前景/单色三层)与 legacy、web 四图标 + favicon',
              '并把全部 13 稿与四轮改善过程整理成本长图存档']

_arts = {}


def art(k):
    if k not in _arts:
        _arts[k] = g.ARTS[k]('full')
    return _arts[k]


def icon(k, size):
    return g.masked_icon(art(k), size, 'rounded')


def wrap(text, font, maxw):
    lines, line = [], ''
    for ch in text:
        if font.getlength(line + ch) > maxw:
            lines.append(line)
            line = ch
        else:
            line += ch
    lines.append(line)
    return lines


def measure(items):
    """先跑一遍排版逻辑拿总高"""
    h = 190
    for rd in ROUNDS:
        h += 96                       # 轮次标题
        h += CARD_ICON + 92           # 卡片行
        q = wrap(rd['quote'], F(25), W - 2 * MARGIN - 300)
        h += 46 + len(q) * 38 + 30    # 气泡
        h += 58 + 46                  # 调整注记 + 箭头
    h += 96 + FINAL_ICON + 130 + 40
    return h


def main():
    H = measure(ROUNDS)
    board = Image.new('RGB', (W, H), BG)
    d = ImageDraw.Draw(board)
    # 页眉
    d.text((MARGIN, 46), '「豆田」应用图标诞生记', font=F(46, True), fill=INK)
    d.text((MARGIN, 116), '13 稿 · 5 轮用户反馈迭代 · 2026-11-07 · 生成脚本 scripts/gen_app_icon.py',
           font=F(24), fill=SUB)
    fin = icon('M', 104)
    board.paste(fin, (W - MARGIN - 104, 40), fin)

    y = 190
    for i, rd in enumerate(ROUNDS):
        # 轮次标题
        d.ellipse([MARGIN, y, MARGIN + 44, y + 44], fill=GREEN)
        d.text((MARGIN + 22, y + 10), str(i + 1), font=F(24, True), fill=(255, 255, 255),
               anchor='mm')
        d.text((MARGIN + 62, y + 2), rd['title'], font=F(30, True), fill=INK)
        y += 96
        # 卡片行
        n = len(rd['keys'])
        gap = 30
        cw = (W - 2 * MARGIN - gap * (n - 1)) // n
        for j, k in enumerate(rd['keys']):
            x0 = MARGIN + j * (cw + gap)
            d.rounded_rectangle([x0, y, x0 + cw, y + CARD_ICON + 74], radius=16,
                                fill=CARD, outline=CARD_BD, width=2)
            ic = icon(k, CARD_ICON)
            board.paste(ic, (x0 + (cw - CARD_ICON) // 2, y + 18), ic)
            d.text((x0 + cw // 2, y + CARD_ICON + 38), rd['cap'][j], font=F(23),
                   fill=INK, anchor='ma')
        y += CARD_ICON + 92
        # 反馈气泡
        lines = wrap(rd['quote'], F(25), W - 2 * MARGIN - 300)
        bh = 46 + len(lines) * 38
        bx0, bx1 = MARGIN + 40, W - MARGIN - 20
        d.rounded_rectangle([bx0, y, bx1, y + bh], radius=14, fill=BUBBLE,
                            outline=BUBBLE_BD, width=2)
        d.text((bx0 + 24, y + 14), '改善需求', font=F(23, True), fill=GREEN)
        for li, ln in enumerate(lines):
            d.text((bx0 + 24, y + 48 + li * 38), ln, font=F(25), fill=BUBBLE_TX)
        y += bh + 14
        d.text((bx0 + 6, y), rd['note'], font=F(23), fill=SUB)
        y += 58
        # 向下箭头
        if i < len(ROUNDS):
            cx = W // 2
            d.polygon([(cx - 13, y), (cx + 13, y), (cx, y + 24)], fill=(180, 186, 196))
        y += 46

    # 定稿区
    d.rounded_rectangle([MARGIN, y, W - MARGIN, y + FINAL_ICON + 130], radius=18,
                        fill=(255, 250, 236), outline=GOLD, width=3)
    d.ellipse([MARGIN + 24, y + 22, MARGIN + 68, y + 66], fill=GOLD)
    d.text((MARGIN + 46, y + 34), '✓', font=F(26, True), fill=(255, 255, 255), anchor='mm')
    d.text((MARGIN + 86, y + 20), '第 5 轮 · 定稿「图纸格豆苗」', font=F(30, True), fill=INK)
    big = icon('M', FINAL_ICON)
    board.paste(big, (MARGIN + 90, y + 76), big)
    ty = y + 96
    d.text((MARGIN + 90 + FINAL_ICON + 50, ty), '确认定稿', font=F(26, True), fill=GREEN)
    for ln in FINAL_NOTE:
        ty += 46
        d.text((MARGIN + 90 + FINAL_ICON + 50, ty), '· ' + ln, font=F(24), fill=INK)

    out = os.path.join(ROOT, 'docs', 'icon_design_journey.png')
    os.makedirs(os.path.dirname(out), exist_ok=True)
    board.save(out)
    print('JOURNEY ->', out, board.size)


if __name__ == '__main__':
    main()
