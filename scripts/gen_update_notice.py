# -*- coding: utf-8 -*-
"""「豆田」v0.2.0 更新公告长图生成器(版式 v2)
用法: python scripts/gen_update_notice.py  -> dist/更新公告_v0.2.0.png
版式: 图纸格纹理头图 + 大图标 / 定名卡 / 数据块一排 / 五个功能卡(编号章+
粗体短条目) / 安装卡;不做设计过程叙事,只讲最终结果。
"""
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_app_icon as g

ROOT = g.ROOT
W, MARGIN = 2160, 96
INNER = W - 2 * MARGIN
PAD = 70
F = lambda sz, bold=False: ImageFont.truetype(
    os.path.join(ROOT, 'assets', 'fonts',
                 'NotoSansSC-Bold.otf' if bold else 'NotoSansSC-Regular.otf'), sz)

BG = (245, 243, 238)
CARD, CARD_BD = (255, 255, 255), (228, 224, 216)
INK, SUB = (43, 42, 38), (120, 116, 106)
RED = (206, 84, 72)
GREEN = (86, 148, 74)
GREEN_SOFT = (123, 182, 97)
GREEN_PALE = (238, 246, 234)
INSTALL_BD = (191, 224, 166)
GRID_LINE = (236, 232, 222)

FS, FS_LH = 44, 76          # 条目字号/行高

STATS = [('15', '项改进'), ('37 秒', '6K 原图识别'), ('2~16', '截图墙每行列数'), ('无损', '抖音图文原图')]

FEATURES = [
    ('01', '识别更准了', [
        ('空白格不虚涨', '图纸外的空白格直接算空白；印了色号的白豆一颗不丢'),
        ('漏读自动补认', '太小、压线的字逐格裁出放大再读，认出色号按色号来'),
    ]),
    ('02', '大图识别又快又稳', [
        ('不再卡死崩溃', '超大原图不再放大出上亿像素中间图，自动控制规模'),
        ('全程进度可见', '进行到哪一步、已确认多少格，一眼可见不用干等'),
    ]),
    ('03', '复核更省力了', [
        ('整片拖选', '按住半秒锁定，起点拖到终点一次选中，贴边自动滚屏'),
        ('每行 2~16 格', '想多看几格调大、想看清格内字调小，自定义直接输'),
        ('共 N 颗徽标', '图例右侧实时总数，和图纸标注一眼对账'),
        ('识别中锁定画面', '防止中途误碰改动导致认错位'),
    ]),
    ('04', '导入的图更清楚了', [
        ('抖音变原图', '和作者上传的完全一样清楚，免登录、操作不变'),
        ('小红书更稳', '链接粘贴修复，大图放大更清楚'),
    ]),
    ('05', '拼豆入口更顺手了', [
        ('开始拼豆先选豆板', '缩略图、件数、保存时间一目了然，可重命名/删除/新建'),
        ('对齐步长档 0.01~1', '格子大小与上下左右微调统一按当前档位走'),
        ('链接导入防误触', '解析、下载期间面板锁定，不怕误关中断'),
    ]),
]

INSTALL = ('下载 bead_studio_v0.2.0.apk 直接安装即可（覆盖旧版本），作品和拼豆进度'
           '全部保留；安装后桌面会显示新的「豆田」图标。')


def adaptive_circle(size, frac=0.72):
    bg = g.art_M('bg')[..., :3]
    fg = g.art_M('shapes')
    a = fg[..., 3:]
    rgb = np.clip(fg[..., :3] * a + bg * (1 - a), 0, 1)
    img = Image.fromarray((rgb * 255).astype(np.uint8)).resize((size * 2, size * 2), Image.LANCZOS)
    m = Image.new('L', img.size, 0)
    ImageDraw.Draw(m).ellipse([0, 0, img.size[0], img.size[1]], fill=255)
    m = m.resize((size, size), Image.LANCZOS)
    out = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    out.paste(img.resize((size, size), Image.LANCZOS), (0, 0), m)
    return out


def full_icon(size):
    return g.masked_icon(g.ARTS['M']('full'), size, 'rounded')


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


def rich_lines(head, body, maxw):
    """首行=粗体head+空格+body, 溢出后按 body 续行;返回 [(text, bold, offset_x)] 行集"""
    fh, fb = F(FS, True), F(FS)
    hw = fh.getlength(head + '  ')
    out = [(head, True, 0)]
    room = maxw - hw
    cur, curw = '', 0
    for ch in body:
        w = fb.getlength(ch)
        if curw + w > room:
            out.append((cur, False, hw))
            cur, curw, room = ch, w, maxw
        else:
            cur += ch
            curw += w
    if cur:
        out.append((cur, False, hw))
    return out


def feature_card_h(items):
    h = PAD + 64 + 52          # 编号章 + 标题 + 间距
    for head, body in items:
        n = len(rich_lines(head, body, INNER - 2 * PAD - 96))
        h += n * FS_LH + 30
    return h - 30 + PAD


def measure():
    h = 640                    # 头图
    h += 46 + 350              # 定名卡
    h += 46 + 300              # 数据块
    for _, _, items in FEATURES:
        h += 46 + feature_card_h(items)
    h += 46 + 240 + 80         # 安装卡 + 底边距
    return h


def draw_board():
    H = measure()
    board = Image.new('RGB', (W, H), BG)
    d = ImageDraw.Draw(board)
    # ---------- 头图: 图纸格纹理 + 图标 + 标题 + 徽标 ----------
    hero_h = 640
    for p in range(0, W, 96):
        d.line([(p, 0), (p, hero_h)], fill=GRID_LINE, width=3)
        d.line([(0, p), (W, p)], fill=GRID_LINE, width=3)
    icon = adaptive_circle(330)
    board.paste(icon, (W // 2 - 165, 84), icon)
    d.text((W // 2, 452), '豆田  v0.2.0', font=F(96, True), fill=INK, anchor='ma')
    badge = '大版本更新 · 15 项改进 · 2026-11-09'
    bw = F(42, True).getlength(badge) + 108
    d.rounded_rectangle([W // 2 - bw // 2, 560, W // 2 + bw // 2, 636], radius=38,
                        fill=(255, 255, 255), outline=GREEN_SOFT, width=3)
    d.text((W // 2, 598), badge, font=F(42, True), fill=GREEN, anchor='mm')
    y = hero_h
    # ---------- 定名卡 ----------
    ch = 350
    d.rounded_rectangle([MARGIN, y, W - MARGIN, y + ch], radius=28, fill=CARD,
                        outline=CARD_BD, width=2)
    ic = full_icon(230)
    board.paste(ic, (MARGIN + PAD, y + 60), ic)
    tx = MARGIN + PAD + 230 + 80
    d.text((tx, y + 62), '定名「豆田」，有了自己的图标', font=F(62, True), fill=INK)
    for i, t in enumerate(['「拼豆图案工作室」正式定名「豆田」——豆子的田，名称全部统一。',
                           '全新图标「图纸格豆苗」：绿豆苗从拼豆图纸的完整格线里长出来，',
                           'Android 各种图标槽形都自适应，安装后桌面自动换新。']):
        d.text((tx, y + 170 + i * 58), t, font=F(42), fill=SUB)
    y += ch + 46
    # ---------- 数据块 ----------
    tw = (INNER - 3 * 36) // 4
    for i, (num, cap) in enumerate(STATS):
        x0 = MARGIN + i * (tw + 36)
        d.rounded_rectangle([x0, y, x0 + tw, y + 300], radius=28, fill=CARD,
                            outline=CARD_BD, width=2)
        d.text((x0 + tw // 2, y + 92), num, font=F(88, True),
               fill=RED if i == 0 else GREEN, anchor='ma')
        d.line([(x0 + tw // 2 - 40, y + 158), (x0 + tw // 2 + 40, y + 158)],
               fill=GREEN_SOFT, width=4)
        cap_lines = wrap(cap, F(38), tw - 60)
        for li, ln in enumerate(cap_lines):
            d.text((x0 + tw // 2, y + 198 + li * 54), ln, font=F(38), fill=SUB, anchor='ma')
    y += 300 + 46
    # ---------- 功能卡 ----------
    for no, title, items in FEATURES:
        ch = feature_card_h(items)
        d.rounded_rectangle([MARGIN, y, W - MARGIN, y + ch], radius=28, fill=CARD,
                            outline=CARD_BD, width=2)
        cx0, cy0 = MARGIN + PAD, y + PAD
        d.rounded_rectangle([cx0, cy0, cx0 + 64, cy0 + 64], radius=16, fill=GREEN)
        d.text((cx0 + 32, cy0 + 32), no, font=F(36, True), fill=(255, 255, 255), anchor='mm')
        d.text((cx0 + 96, cy0), title, font=F(60, True), fill=INK)
        ty = cy0 + 64 + 52
        for head, body in items:
            lines = rich_lines(head, body, INNER - 2 * PAD - 96)
            for li, (txt, bold, ox) in enumerate(lines):
                if li == 0:
                    d.rounded_rectangle([cx0 + 6, ty + 26, cx0 + 26, ty + 46], radius=5,
                                        fill=GREEN_SOFT)
                d.text((cx0 + 52 + ox, ty), txt, font=F(FS, bold), fill=INK if bold else SUB)
                ty += FS_LH
            ty += 30
        y += ch + 46
    # ---------- 安装卡 ----------
    ch = 240
    d.rounded_rectangle([MARGIN, y, W - MARGIN, y + ch], radius=28, fill=GREEN_PALE,
                        outline=INSTALL_BD, width=3)
    d.text((MARGIN + PAD, y + 52), '安装说明', font=F(56, True), fill=GREEN)
    for i, ln in enumerate(wrap(INSTALL, F(42), INNER - 2 * PAD)):
        d.text((MARGIN + PAD, y + 140 + i * 60), ln, font=F(42), fill=INK)
    out = os.path.join(ROOT, 'dist', '更新公告_v0.2.0.png')
    board.save(out)
    print('NOTICE ->', out, board.size)


if __name__ == '__main__':
    draw_board()
