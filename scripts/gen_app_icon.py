# -*- coding: utf-8 -*-
"""豆田 App 图标生成器(纯程序化绘制,无外部素材,可随时重新生成)

用法:
  python scripts/gen_app_icon.py preview [DEF|ABC]  # 预览图 -> .test/icon_preview.png
  python scripts/gen_app_icon.py apply D|E|F|A|B|C  # 写入 android/web 全部图标位并改 manifest.json
  python scripts/gen_app_icon.py selfcheck          # 关键坐标像素抽样自检

第二稿(方格 + 渐变过渡色,无圆元素):
  D 渐变方格 —— 近白底 + 3x3 圆角方格,格色沿对角线从暖黄平滑过渡到田绿(量化色阶即拼豆图纸)
  E 渐变田   —— 整面绿青蓝渐变 + 半透明白「田」字,最简洁现代
  F 方格豆阶 —— 大绿方 + 橙/蓝小方沿对角线阶跃上升(田里长豆的抽象)
第一稿(圆豆方案,已被否,留档):
  A 九宫豆田 / B 田字四豆 / C 彩虹豆田
"""
import sys, os, math, json
import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
S = 1024  # 母版边长(所有坐标按 S 的比例)


def hexc(s):
    return np.array([int(s[i:i + 2], 16) for i in (1, 3, 5)], float) / 255.0


WHITE = hexc('#FFFFFF')
XXF, YYF = np.mgrid[0:S, 0:S].astype(float) + 0.5
TDIAG = (XXF / S + YYF / S) / 2.0  # 对角 0..1(左上->右下)


def lighten(c, k):
    return c + (1 - c) * k


def darken(c, k):
    return c * (1 - k)


def grad_stops(stops, t):
    """多段渐变采样,t 为 0..1 数组"""
    t = np.clip(np.asarray(t, float), 0, 1)
    n = len(stops) - 1
    x = t * n
    i = np.clip(x.astype(int), 0, n - 1)
    f = x - i
    out = np.zeros(t.shape + (3,))
    for k in range(n):
        m = i == k
        out[m] = stops[k] * (1 - f[m][:, None]) + stops[k + 1] * f[m][:, None]
    return out


# ---------- 基础绘制 ----------

def mask_pil(draw_fn):
    m = Image.new('L', (S, S), 0)
    draw_fn(ImageDraw.Draw(m))
    return np.asarray(m, float)[..., None] / 255.0


def rounded_mask(rad_frac=0.22):
    r = S * rad_frac
    return mask_pil(lambda d: d.rounded_rectangle([0, 0, S - 1, S - 1], radius=r, fill=255))


def circle_mask():
    return mask_pil(lambda d: d.ellipse([0, 0, S - 1, S - 1], fill=255))


def grid_mask(n, a0=0.10, a1=0.90, th=0.030):
    """n x n 网格内部线掩膜(不含外框)"""
    m = np.zeros((S, S), float)
    t = int(th * S)
    for i in range(1, n):
        p = int((a0 + (a1 - a0) * i / n) * S)
        m[int(a0 * S):int(a1 * S), p - t // 2:p + t // 2] = 1.0
        m[p - t // 2:p + t // 2, int(a0 * S):int(a1 * S)] = 1.0
    return m[..., None]


def comp(canvas, mask, rgb):
    """把 rgb 按 mask 混合进画布;RGBA 画布同步抬高 alpha"""
    if canvas.shape[2] == 4:
        rgb4 = np.dstack([np.broadcast_to(rgb, (S, S, 3)).copy(), mask])
        return rgb4 * mask + canvas * (1 - mask)
    return rgb * mask + canvas * (1 - mask)


def paste(canvas, cx, cy, tile, mono_color=None):
    n = tile.shape[0]
    x, y = int(cx - n / 2), int(cy - n / 2)
    x0, y0 = max(x, 0), max(y, 0)
    x1, y1 = min(x + n, S), min(y + n, S)
    if x1 <= x0 or y1 <= y0:
        return
    t = tile[y0 - y:y1 - y, x0 - x:x1 - x]
    a = t[..., 3:]
    rgb = t[..., :3]
    if mono_color is not None:
        rgb = np.broadcast_to(mono_color, rgb.shape)
    src = rgb * a
    if canvas.shape[2] == 4:
        src = np.concatenate([src, a], axis=2)
    canvas[y0:y1, x0:x1] = src + canvas[y0:y1, x0:x1] * (1 - a)


def bead_tile(d, color):
    """(第一稿留档)顶视拼豆:中孔+高光+暗边"""
    n = max(int(d), 8)
    c = n / 2.0
    yy, xx = np.mgrid[0:n, 0:n] + 0.5
    dx = (xx - c) / c
    dy = (yy - c) / c
    dist = np.sqrt(dx * dx + dy * dy)
    ld = np.sqrt((dx + 0.38) ** 2 + (dy + 0.42) ** 2)
    glow = np.exp(-(ld / 0.62) ** 2) * 0.34
    sphere = 0.74 + 0.26 * np.clip(1.0 - dist * 0.5, 0, 1)
    rgb = color * sphere[..., None] + glow[..., None]
    rim = np.clip((dist - 0.80) / 0.20, 0, 1) ** 1.4
    rgb = rgb * (1 - rim[..., None] * 0.75) + color * 0.45 * rim[..., None] * 0.75
    hole = dist <= 0.24
    ring = (dist > 0.22) & (dist <= 0.31)
    rgb = np.where(hole[..., None], color * 0.34, rgb)
    rgb = np.where(ring[..., None], color * 0.52, rgb)
    a = np.clip((1.0 - dist) / (2.0 / n), 0, 1)
    out = np.zeros((n, n, 4))
    out[..., :3] = np.clip(rgb, 0, 1)
    out[..., 3] = a
    return out


def bead_shadow(canvas, cx, cy, d, k=0.15):
    n = int(d * 1.06)
    yy, xx = np.mgrid[0:n, 0:n] + 0.5
    dist = np.sqrt((xx - n / 2) ** 2 + (yy - n / 2) ** 2) / (n / 2)
    a = np.clip((1.0 - dist) * n / 2, 0, 1) * k
    paste(canvas, cx + d * 0.02, cy + d * 0.05,
          np.dstack([np.zeros((n, n, 3)), a[..., None]]))


def sq_tile(canvas, x0, y0, sz, rad, c_light, c_dark, mono=False):
    """圆角方格,格内自带左上->右下微渐变(过度色的最小单元)"""
    m = mask_pil(lambda d: d.rounded_rectangle([x0 * S, y0 * S, (x0 + sz) * S, (y0 + sz) * S],
                                               radius=rad * S, fill=255))
    if mono:
        return comp(canvas, m, WHITE)
    tt = np.clip(((XXF - x0 * S) + (YYF - y0 * S)) / (2 * sz * S), 0, 1)
    rgb = c_light * (1 - tt[..., None]) + c_dark * tt[..., None]
    return comp(canvas, m, rgb)


def soft_shadow(canvas, x0, y0, sz, rad, dy=0.014, k=0.10):
    """方格下的柔影(高斯模糊)"""
    m = Image.new('L', (S, S), 0)
    ImageDraw.Draw(m).rounded_rectangle(
        [x0 * S, (y0 + dy) * S, (x0 + sz) * S, (y0 + sz + dy) * S], radius=rad * S, fill=255)
    m = m.filter(ImageFilter.GaussianBlur(int(0.012 * S)))
    a = np.asarray(m, float)[..., None] / 255.0
    canvas[..., :3] = canvas[..., :3] * (1 - k * a)
    return canvas


def capsule_pair_mask(th, a0, a1):
    """横竖两条胶囊(田字骨架)"""
    th_ = th * S

    def draw(d):
        d.rounded_rectangle([a0 * S, 0.5 * S - th_ / 2, a1 * S, 0.5 * S + th_ / 2],
                            radius=th_ / 2, fill=255)
        d.rounded_rectangle([0.5 * S - th_ / 2, a0 * S, 0.5 * S + th_ / 2, a1 * S],
                            radius=th_ / 2, fill=255)
    return mask_pil(draw)


# ---------- 方案实现:mode = 'full' | 'bg' | 'shapes' | 'mono' ----------

def _canvas(bg):
    return np.dstack([bg, np.ones((S, S, 1))])


def _transparent():
    return np.zeros((S, S, 4))


DSTOPS = [hexc(c) for c in ('#F2CE4E', '#A9D95B', '#5FC46B', '#2FA96B')]  # 暖黄->田绿


def art_D(mode='full'):
    bg = grad_stops([hexc('#FBFBF6'), hexc('#EFF2E7')], YYF / S)
    canvas = _transparent() if mode in ('shapes', 'mono') else _canvas(bg)
    if mode == 'bg':
        return canvas
    a0, a1 = 0.145, 0.855
    c3 = (a1 - a0) / 3
    g = 0.014
    for r in range(3):
        for c in range(3):
            x0 = a0 + c * c3 + g
            y0 = a0 + r * c3 + g
            sz = c3 - 2 * g
            base = grad_stops(DSTOPS, np.array([(r + c) / 4.0]))[0]
            if mode != 'mono':
                canvas = soft_shadow(canvas, x0, y0, sz, sz * 0.24)
            canvas = sq_tile(canvas, x0, y0, sz, sz * 0.24,
                             lighten(base, 0.14), darken(base, 0.08), mono=(mode == 'mono'))
    return canvas


ESTOPS = [hexc(c) for c in ('#3EC98F', '#1FA3A8', '#2F7CC4')]  # 绿->青->蓝


def art_E(mode='full'):
    bg = grad_stops(ESTOPS, TDIAG)
    canvas = _transparent() if mode in ('shapes', 'mono') else _canvas(bg)
    if mode == 'bg':
        return canvas
    cap = capsule_pair_mask(0.024, 0.16, 0.84)
    a = 1.0 if mode in ('shapes', 'mono') else 0.32
    return comp(canvas, cap * a, WHITE)


FTILES = [
    # (x0, y0, size, radius, [light, dark])
    (0.10, 0.40, 0.50, 0.12, ('#46C283', '#1F8F5F')),
    (0.66, 0.52, 0.20, 0.05, ('#F7B733', '#E58A1F')),
    (0.70, 0.22, 0.16, 0.04, ('#4FA8E8', '#2F7CC4')),
]


def art_F(mode='full'):
    bg = grad_stops([hexc('#F8F7F2'), hexc('#EBE9DC')], TDIAG)
    canvas = _transparent() if mode in ('shapes', 'mono') else _canvas(bg)
    if mode == 'bg':
        return canvas
    for x0, y0, sz, rad, (cl, cd) in FTILES:
        if mode != 'mono':
            canvas = soft_shadow(canvas, x0, y0, sz, rad, k=0.12)
        canvas = sq_tile(canvas, x0, y0, sz, rad, hexc(cl), hexc(cd), mono=(mode == 'mono'))
    return canvas


RAINBOW9 = ['#E5433C', '#F58C2C', '#F5C83B', '#63BE50', '#38A1DD',
            '#3E6FD0', '#7A4FD1', '#D9509F', '#EE6FA6']


def art_A(mode='full'):
    bg = grad_stops([hexc('#A6DC6E'), hexc('#2E8F3C')], TDIAG)
    canvas = _transparent() if mode in ('shapes', 'mono') else _canvas(bg)
    if mode == 'bg':
        return canvas
    if mode != 'mono':
        canvas = comp(canvas, grid_mask(3) * 0.92, WHITE)
    else:
        canvas = comp(canvas, grid_mask(3), WHITE)
    d = 0.195 * S
    for r in range(3):
        for c in range(3):
            cx = (0.2333 + 0.2667 * c) * S
            cy = (0.2333 + 0.2667 * r) * S
            col = hexc(RAINBOW9[r * 3 + c])
            if mode != 'mono':
                bead_shadow(canvas, cx, cy, d)
            paste(canvas, cx, cy, bead_tile(d, col), mono_color=(WHITE if mode == 'mono' else None))
    return canvas


def art_B(mode='full'):
    bg = grad_stops([hexc('#FFFDF6'), hexc('#F3E6C6')], TDIAG)
    canvas = _transparent() if mode in ('shapes', 'mono') else _canvas(bg)
    if mode == 'bg':
        return canvas
    cap = capsule_pair_mask(0.086, 0.115, 0.885)
    bar_rgb = grad_stops([hexc('#45A24A'), hexc('#2F7E38')], TDIAG)
    canvas = comp(canvas, cap, WHITE if mode == 'mono' else bar_rgb)
    d = 0.21 * S
    for (cx, cy), col in zip([(0.286, 0.286), (0.714, 0.286), (0.286, 0.714), (0.714, 0.714)],
                             ['#E5433C', '#F5C51E', '#3E6FD0', '#8A4FC8']):
        if mode != 'mono':
            bead_shadow(canvas, cx * S, cy * S, d)
        paste(canvas, cx * S, cy * S, bead_tile(d, hexc(col)),
              mono_color=(WHITE if mode == 'mono' else None))
    return canvas


def art_C(mode='full'):
    bg = grad_stops([hexc('#FFFDF0'), hexc('#F6EBD0')], TDIAG)
    canvas = _transparent() if mode in ('shapes', 'mono') else _canvas(bg)
    if mode == 'bg':
        return canvas
    field = mask_pil(lambda d: d.ellipse([int(-0.12 * S), int(0.52 * S),
                                          int(1.12 * S), int(1.62 * S)], fill=255))
    field_rgb = grad_stops([hexc('#5FB653'), hexc('#3E9440')], TDIAG)
    canvas = comp(canvas, field, WHITE if mode == 'mono' else field_rgb)
    for bbox in [(0.08, 1.10, 0.50, 0.60), (0.16, 1.18, 0.62, 0.72)]:
        w = int(0.016 * S)
        arc = mask_pil(lambda d, b=bbox: d.arc([int(b[0] * S), int(b[1] * S),
                                                int((b[0] + b[2]) * S), int((b[1] + b[3]) * S)],
                                               start=210, end=330, fill=255, width=w))
        canvas = comp(canvas, arc, WHITE if mode == 'mono' else hexc('#2F8F3F'))
    R, ccx, ccy = 0.335 * S, 0.5 * S, 0.855 * S
    for i, col in enumerate(['#E5433C', '#F58C2C', '#F5C83B', '#63BE50',
                             '#38A1DD', '#3E6FD0', '#7A4FD1']):
        a = math.radians(20 + i * (140 / 6.0))
        cx = ccx + R * math.cos(a)
        cy = ccy - R * math.sin(a)
        if mode != 'mono':
            bead_shadow(canvas, cx, cy, 0.105 * S, k=0.10)
        paste(canvas, cx, cy, bead_tile(0.105 * S, hexc(col)),
              mono_color=(WHITE if mode == 'mono' else None))
    return canvas


# ---------- 第三稿:拼豆成品风(豆在格板上拼图案) ----------

def grid_art(mode, rows, colmap, bead='round', a0=0.09, a1=0.91):
    """rows: N 行字符串,每字符一格;'.' 空(露格板销点),其余按 colmap 上色画豆"""
    n = len(rows)
    cell = (a1 - a0) / n
    bg = grad_stops([hexc('#EAF4E1'), hexc('#D5E8C9')], TDIAG)
    canvas = _transparent() if mode in ('shapes', 'mono') else _canvas(bg)
    # 格板销点(空格中央的小凸点)
    if mode in ('full', 'bg'):
        peg = np.zeros((S, S, 4))
        pm = Image.new('L', (S, S), 0)
        dp = ImageDraw.Draw(pm)
        for r in range(n):
            for c in range(n):
                cx, cy = (a0 + (c + 0.5) * cell) * S, (a0 + (r + 0.5) * cell) * S
                d = cell * 0.22 * S
                dp.ellipse([cx - d / 2, cy - d / 2, cx + d / 2, cy + d / 2], fill=255)
        pm = pm.filter(ImageFilter.GaussianBlur(2))
        canvas = comp(canvas, np.asarray(pm, float)[..., None] / 255.0 * 0.45, hexc('#A9C79C'))
    if mode == 'bg':
        return canvas
    for r, row in enumerate(rows):
        for c, ch in enumerate(row):
            if ch == '.':
                continue
            jit = 1.0 + (((r * 7 + c * 13) % 5) - 2) * 0.02  # 逐豆微色差(拼豆实感)
            color = hexc(colmap[ch]) * jit
            cx, cy = (a0 + (c + 0.5) * cell) * S, (a0 + (r + 0.5) * cell) * S
            if bead == 'round':
                paste(canvas, cx, cy, bead_tile(cell * 0.94 * S, color),
                      mono_color=(WHITE if mode == 'mono' else None))
            else:
                x0, y0 = a0 + c * cell + cell * 0.03, a0 + r * cell + cell * 0.03
                sz = cell * 0.94
                sq_tile(canvas, x0, y0, sz, sz * 0.15,
                        lighten(color, 0.12), darken(color, 0.12), mono=(mode == 'mono'))
                if mode != 'mono':  # 方形中孔
                    h = sz * 0.26
                    hm = mask_pil(lambda d, X=x0 + (sz - h) / 2, Y=y0 + (sz - h) / 2:
                                  d.rectangle([X * S, Y * S, (X + h) * S, (Y + h) * S], fill=255))
                    canvas = comp(canvas, hm * 0.9, color * 0.38)
    return canvas


G_ROWS = [
    "...HH..HH...",
    "..HLL..LLH..",
    ".HLLL..LLLH.",
    ".DLLL..LLLD.",
    "..DLL..LLD..",
    "...DD..DD...",
    ".....SS.....",
    ".....SS.....",
    ".....SS.....",
    ".....SS.....",
    ".BNBBNBBBNB.",
    "NNNNNNNNNNNN",
]
G_COLORS = {'H': '#7FCB6B', 'L': '#55B245', 'D': '#3D9430',
            'S': '#2F7E38', 'B': '#A06C3E', 'N': '#7C5130'}


def art_G(mode='full'):
    return grid_art(mode, G_ROWS, G_COLORS, bead='round')


def _tian_rows():
    """12x12 拼「田」:笔画宽 2 格,四个 3x3 田块中央各一颗金豆"""
    st = {0, 1, 5, 6, 10, 11}
    golds = {(3, 3), (3, 8), (8, 3), (8, 8)}
    rows = []
    for r in range(12):
        row = ''
        for c in range(12):
            if (r, c) in golds:
                row += 'G'
            elif r in st or c in st:
                if r == 0 or c == 0:
                    row += 'H'      # 左上受光
                elif r == 11 or c == 11:
                    row += 'D'      # 右下沉影
                else:
                    row += 'M'
            else:
                row += '.'
        rows.append(row)
    return rows


T_COLORS = {'H': '#58AC52', 'M': '#3E8E3E', 'D': '#2F7030', 'G': '#F2C94C'}


def art_H(mode='full'):
    return grid_art(mode, _tian_rows(), T_COLORS, bead='round')


def art_I(mode='full'):
    return grid_art(mode, G_ROWS, G_COLORS, bead='square')


# ---------- 第四稿:方豆豆苗(方豆 + 方孔,无任何圆) ----------

J_ROWS = G_ROWS  # 原比例豆苗(瘦叶长茎) + 土壤
K_ROWS = [
    "..HH....HH..",
    ".HLLH..HLLH.",
    "HLLLL..LLLLH",
    "HLLLL..LLLLH",
    "HLLLL..LLLLH",
    ".DLLL..LLLD.",
    "..DDD..DDD..",
    ".....SS.....",
    ".....SS.....",
    ".....SS.....",
    ".BNBBNBBBNB.",
    "NNNNNNNNNNNN",
]
L_ROWS = [
    "............",
    "..HH....HH..",
    ".HLLH..HLLH.",
    "HLLLL..LLLLH",
    "HLLLL..LLLLH",
    "HLLLL..LLLLH",
    ".DLLL..LLLD.",
    "..DDD..DDD..",
    ".....SS.....",
    ".....SS.....",
    ".....SS.....",
    "............",
]
J_COLORS = {'H': '#8AD374', 'L': '#5EB950', 'D': '#429C36',
            'S': '#2F8038', 'B': '#A97145', 'N': '#7E5230'}


def art_J(mode='full'):
    return grid_art(mode, J_ROWS, J_COLORS, bead='square')


def art_K(mode='full'):
    return grid_art(mode, K_ROWS, J_COLORS, bead='square')


def art_L(mode='full'):
    return grid_art(mode, L_ROWS, J_COLORS, bead='square')


# ---------- 第五稿:拼豆图纸格样式(J 排布 + 图纸格线) ----------

def _lattice_mask(a0, a1, n, lw):
    """n x n 完整格线(含边界,共 n+1 条/向)"""
    m = np.zeros((S, S), float)
    t = lw / 2
    for i in range(n + 1):
        p = (a0 + (a1 - a0) * i / n) * S
        m[int((a0 - t) * S):int((a1 + t) * S), int(p - t * S):int(p + t * S)] = 1.0
        m[int(p - t * S):int(p + t * S), int((a0 - t) * S):int((a1 + t) * S)] = 1.0
    return m[..., None]


def _bleed_lattice_mask(off, pitch, lw, offy=None):
    """从 off(竖线)/offy(横线,默认=off)起、按 pitch 等距的格线铺满全画布(无限延伸,无外框)
    注意:横竖判断用轴标签,不能用 `base is off`——ax0/ay0 同值时 CPython 合并常量为同一对象会误判"""
    m = np.zeros((S, S))
    t = lw / 2
    if offy is None:
        offy = off
    for axis, base in (('v', off), ('h', offy)):
        k = -20
        while True:
            p = base + k * pitch
            if p > 1 - t:
                break
            if p >= t:
                if axis == 'v':   # 竖线:x=p
                    m[int(t * S):int((1 - t) * S), int((p - t) * S):int((p + t) * S)] = 1.0
                else:             # 横线:y=p
                    m[int((p - t) * S):int((p + t) * S), int(t * S):int((1 - t) * S)] = 1.0
            k += 1
    return m[..., None]


def art_M(mode='full'):
    """图纸纸底 + 填色格(紧贴格线) + 覆盖式格线,正常拼豆图纸的样子。
    full = 带圆角外框的整幅卡片(legacy / web 独立方图);
    bg / shapes / mono / maskable = 自适应体系:格线满铺全画布、无限延伸、无外框,
    圆形遮罩自然裁切格线;豆苗 12 格居中放大约 58%(0.21..0.79,遮罩出血)与背景格线同坐标对齐。"""
    mono_flag = (mode == 'mono')
    # ---------- 自适应体系(圆形遮罩:格线无限延伸) ----------
    if mode in ('bg', 'shapes', 'mono', 'maskable'):
        # 用户定方向:不按遮罩几何配平,直接放大豆苗本身(居中 58%),遮罩裁掉的
        # 土角/叶冠角当作出血效果;格线调浅(0.30 -> 0.16)弱化豆苗周围的网格环。
        ax0, ax1 = 0.21, 0.79
        ay0, ay1 = 0.21, 0.79
        n = 12
        cell = (ax1 - ax0) / n
        paper = grad_stops([hexc('#FBFAF2'), hexc('#E9EEDC')], TDIAG)
        canvas = _transparent() if mode in ('shapes', 'mono') else _canvas(paper)
        if mode in ('shapes', 'mono', 'maskable'):
            for r, row in enumerate(J_ROWS):
                for c, ch in enumerate(row):
                    if ch == '.':
                        continue
                    jit = 1.0 + (((r * 7 + c * 13) % 5) - 2) * 0.015
                    color = hexc(J_COLORS[ch]) * jit
                    x0, y0 = ax0 + c * cell, ay0 + r * cell
                    if mono_flag:
                        cm = mask_pil(lambda d, X=x0, Y=y0:
                                      d.rectangle([X * S, Y * S, (X + cell) * S, (Y + cell) * S], fill=255))
                        canvas = comp(canvas, cm, WHITE)
                    else:
                        canvas = sq_tile(canvas, x0, y0, cell, cell * 0.06,
                                         lighten(color, 0.07), darken(color, 0.05))
        if mode in ('bg', 'mono', 'maskable'):
            lat = _bleed_lattice_mask(ax0, cell, cell * 0.16, offy=ay0)
            canvas = comp(canvas, lat * (1.0 if mono_flag else 0.16),
                          WHITE if mono_flag else hexc('#47523F'))
        return canvas
    # ---------- full:带外框卡片(独立方图) ----------
    n = 12
    a0, a1 = 0.10, 0.90
    cell = (a1 - a0) / n
    paper = grad_stops([hexc('#FBFAF2'), hexc('#E9EEDC')], TDIAG)
    canvas = _canvas(paper)
    for r, row in enumerate(J_ROWS):
        for c, ch in enumerate(row):
            if ch == '.':
                continue
            jit = 1.0 + (((r * 7 + c * 13) % 5) - 2) * 0.015
            color = hexc(J_COLORS[ch]) * jit
            x0, y0 = a0 + c * cell, a0 + r * cell
            canvas = sq_tile(canvas, x0, y0, cell, cell * 0.06,
                             lighten(color, 0.07), darken(color, 0.05))
    lat = _lattice_mask(a0, a1, n, cell * 0.16)
    canvas = comp(canvas, lat * 0.16, hexc('#47523F'))
    bw = 0.022
    frame = mask_pil(lambda d: d.rounded_rectangle(
        [(a0 - bw) * S, (a0 - bw) * S, (a1 + bw) * S, (a1 + bw) * S],
        radius=0.05 * S, outline=255, width=int(bw * S)))
    canvas = comp(canvas, frame * 0.55, hexc('#47523F'))
    return canvas


ARTS = {'A': art_A, 'B': art_B, 'C': art_C, 'D': art_D, 'E': art_E, 'F': art_F,
        'G': art_G, 'H': art_H, 'I': art_I, 'J': art_J, 'K': art_K, 'L': art_L,
        'M': art_M}
LABELS = {'A': 'A. 九宫豆田(圆)', 'B': 'B. 田字四豆(圆)', 'C': 'C. 彩虹豆田(圆)',
          'D': 'D. 渐变方格', 'E': 'E. 渐变田', 'F': 'F. 方格豆阶',
          'G': 'G. 拼豆豆苗', 'H': 'H. 拼豆田字·四金豆', 'I': 'I. 方豆豆苗',
          'J': 'J. 方豆豆苗·原比例', 'K': 'K. 方豆豆苗·大叶版', 'L': 'L. 方豆豆苗·大叶无土版',
          'M': 'M. 图纸格豆苗(拼豆图纸样式)'}


# ---------- 导出 ----------

def to_pil(canvas_rgba):
    return Image.fromarray((np.clip(canvas_rgba, 0, 1) * 255).astype('uint8'), 'RGBA')


def shrink(im, size):
    while im.width > size * 2:
        im = im.resize((max(im.width // 2, size),) * 2, Image.LANCZOS)
    return im.resize((size, size), Image.LANCZOS)


def masked_alpha(canvas_rgba, shape):
    a = canvas_rgba[..., 3:]
    if shape == 'rounded':
        return a * rounded_mask()
    if shape == 'circle':
        return a * circle_mask()
    return a


def masked_icon(canvas_rgba, size, shape):
    im = to_pil(canvas_rgba)
    m = Image.fromarray((np.clip(masked_alpha(canvas_rgba, shape), 0, 1).squeeze() * 255).astype('uint8'), 'L')
    im.putalpha(m)
    return shrink(im, size)


def shapes_on(shapes_rgba, size, frac):
    small = shrink(to_pil(shapes_rgba), max(int(size * frac), 1))
    out = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    out.paste(small, ((size - small.width) // 2, (size - small.height) // 2), small)
    return out


LEGACY = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}
ADAPTIVE = {'mdpi': 108, 'hdpi': 162, 'xhdpi': 216, 'xxhdpi': 324, 'xxxhdpi': 432}
# 前景层占画布比例:M 的自适应前景层网格坐标已按全画布设计(与背景格线对齐),1:1 放置;
# 其余方案 shapes 只是图案主体,62% 即可
FRAC = {'M': 1.0}


def apply(variant):
    art = ARTS[variant]('full')
    bg = ARTS[variant]('bg')
    shapes = ARTS[variant]('shapes')
    mono = ARTS[variant]('mono')
    frac = FRAC.get(variant, 0.62)
    res = os.path.join(ROOT, 'android', 'app', 'src', 'main', 'res')
    web = os.path.join(ROOT, 'web')
    written = []
    for dpi, sz in LEGACY.items():
        masked_icon(art, sz, 'rounded').save(os.path.join(res, 'mipmap-%s' % dpi, 'ic_launcher.png'))
        written.append('mipmap-%s/ic_launcher.png' % dpi)
    anydpi = os.path.join(res, 'mipmap-anydpi-v26')
    os.makedirs(anydpi, exist_ok=True)
    for dpi, sz in ADAPTIVE.items():
        shrink(to_pil(bg), sz).save(os.path.join(res, 'mipmap-%s' % dpi, 'ic_launcher_background.png'))
        shapes_on(shapes, sz, frac).save(os.path.join(res, 'mipmap-%s' % dpi, 'ic_launcher_foreground.png'))
        shapes_on(mono, sz, frac).save(os.path.join(res, 'mipmap-%s' % dpi, 'ic_launcher_monochrome.png'))
        written.append('mipmap-%s/ x3 adaptive' % dpi)
    with open(os.path.join(anydpi, 'ic_launcher.xml'), 'w', encoding='utf-8') as f:
        f.write('<?xml version="1.0" encoding="utf-8"?>\n'
                '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
                '    <background android:drawable="@mipmap/ic_launcher_background"/>\n'
                '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
                '    <monochrome android:drawable="@mipmap/ic_launcher_monochrome"/>\n'
                '</adaptive-icon>\n')
    written.append('mipmap-anydpi-v26/ic_launcher.xml')
    masked_icon(art, 192, 'rounded').save(os.path.join(web, 'icons', 'Icon-192.png'))
    masked_icon(art, 512, 'rounded').save(os.path.join(web, 'icons', 'Icon-512.png'))
    masked_icon(art, 32, 'rounded').save(os.path.join(web, 'favicon.png'))
    for sz in (192, 512):
        full = shrink(to_pil(bg), sz)
        fg = shrink(to_pil(shapes), int(sz * (frac if frac >= 1.0 else 0.78)))
        full.paste(fg, ((sz - fg.width) // 2, (sz - fg.height) // 2), fg)
        full.save(os.path.join(web, 'icons', 'Icon-maskable-%d.png' % sz))
    written.append('web/ icons x4 + favicon')
    mp = os.path.join(web, 'manifest.json')
    with open(mp, encoding='utf-8') as f:
        m = json.load(f)
    m['name'] = '豆田'
    m['short_name'] = '豆田'
    m['description'] = '豆田 - 图片导入/像素化/调色板量化/画布编辑/用料统计'
    m['theme_color'] = '#3E8E3E'
    m['background_color'] = '#F6F1E2'
    with open(mp, 'w', encoding='utf-8') as f:
        json.dump(m, f, ensure_ascii=False, indent=4)
        f.write('\n')
    written.append('web/manifest.json')
    print('APPLIED %s -> %d targets' % (variant, len(written)))


def preview(keys='DEF'):
    gap, pad = 24, 28
    out_w = 512 + 192 + 96 + 96 + 48 + 48 + 5 * gap + 2 * pad
    row_h = 512 + 76
    font = ImageFont.truetype(os.path.join(ROOT, 'assets', 'fonts', 'NotoSansSC-Bold.otf'), 34)
    board = Image.new('RGB', (out_w, row_h * len(keys) + pad * 2 + gap * (len(keys) - 1)), (245, 245, 248))
    for i, k in enumerate(keys):
        art = ARTS[k]()
        y0 = pad + i * (row_h + gap)
        ImageDraw.Draw(board).text((pad, y0 + 8), LABELS[k], font=font, fill=(40, 40, 40))
        x = pad
        for sz, shape in [(512, 'rounded'), (192, 'rounded'), (96, 'rounded'),
                          (96, 'circle'), (48, 'rounded'), (48, 'circle')]:
            ic = masked_icon(art, sz, shape)
            board.paste(ic, (x, y0 + 60 + (512 - sz)), ic)
            x += sz + gap
    p = os.path.join(ROOT, '.test', 'icon_preview.png')
    os.makedirs(os.path.dirname(p), exist_ok=True)
    board.save(p)
    print('PREVIEW', keys, '->', p)


def selfcheck():
    cell = 0.82 / 12.0
    cx = lambda i: 0.09 + (i + 0.5) * cell
    for k in 'GHI':
        a = ARTS[k]()

        def px(fx, fy, arr=a):
            return tuple(int(v) for v in np.clip(arr[int(fy * S), int(fx * S)] * 255))
        if k == 'H':
            print('H stroke', px(cx(5), cx(0)), 'gold', px(cx(3), cx(3)), 'field', px(cx(2), cx(2)))
        else:
            print(k, 'leaf', px(cx(2), cx(2)), 'stem', px(cx(5), cx(7)),
                  'soil', px(cx(5), cx(11)), 'board', px(cx(2), cx(9)))


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'preview'
    if cmd == 'preview':
        preview(sys.argv[2] if len(sys.argv) > 2 else 'M')
    elif cmd == 'apply':
        apply(sys.argv[2].upper())
    elif cmd == 'selfcheck':
        selfcheck()
    else:
        print(__doc__)
