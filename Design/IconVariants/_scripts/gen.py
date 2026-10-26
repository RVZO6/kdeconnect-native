#!/usr/bin/env python3
"""Generate KDE Connect Native icon variants as Icon Composer documents."""
import json, math, os, shutil, sys

OUT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

KDE = "#1D99F3"
DARK = "#2A2C2F"
SLOT = "#141516"
SCREEN = "#E3E8EA"
WHITE = "#FFFFFF"


def srgb(h, a=1.0):
    h = h.lstrip("#")
    r, g, b = (int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))
    return f"srgb:{r:.5f},{g:.5f},{b:.5f},{a:.5f}"


def svg(body, defs=""):
    d = f"<defs>{defs}</defs>" if defs else ""
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" '
            f'viewBox="0 0 1024 1024">{d}\n{body}\n</svg>\n')


def rrect(x, y, w, h, r):
    r = min(r, w / 2, h / 2)
    return (f"M {x+r:.1f} {y:.1f} H {x+w-r:.1f} A {r} {r} 0 0 1 {x+w:.1f} {y+r:.1f} "
            f"V {y+h-r:.1f} A {r} {r} 0 0 1 {x+w-r:.1f} {y+h:.1f} H {x+r:.1f} "
            f"A {r} {r} 0 0 1 {x:.1f} {y+h-r:.1f} V {y+r:.1f} A {r} {r} 0 0 1 {x+r:.1f} {y:.1f} Z")


def rot(inner, a, cx, cy):
    if not a:
        return inner
    return f'<g transform="rotate({a} {cx} {cy})">{inner}</g>'


def pt(cx, cy, r, deg):
    t = math.radians(deg)
    return cx + r * math.cos(t), cy + r * math.sin(t)


def arc(cx, cy, r, a0, a1):
    """Arc path; angles in degrees, 0 = right, positive = clockwise (SVG y-down)."""
    x0, y0 = pt(cx, cy, r, a0)
    x1, y1 = pt(cx, cy, r, a1)
    large = 1 if abs(a1 - a0) > 180 else 0
    sweep = 1 if a1 > a0 else 0
    return f"M {x0:.1f} {y0:.1f} A {r} {r} 0 {large} {sweep} {x1:.1f} {y1:.1f}"


def stroke(d, color, w, extra=""):
    return (f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{w}" '
            f'stroke-linecap="round" stroke-linejoin="round" {extra}/>')


def circle(cx, cy, r, color, extra=""):
    return f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="{color}" {extra}/>'


# ---------- phone parts ----------

class Phone:
    def __init__(self, cx=512, cy=512, w=420, h=724, r=80, a=0,
                 side=34, top=96, bottom=80, sr=22, slot=True):
        self.__dict__.update(locals())
        del self.__dict__["self"]

    @property
    def x(self):
        return self.cx - self.w / 2

    @property
    def y(self):
        return self.cy - self.h / 2

    def body(self, color=DARK, slot_color=SLOT):
        s = f'<path fill="{color}" d="{rrect(self.x, self.y, self.w, self.h, self.r)}"/>'
        if self.slot:
            sw = self.w * 0.29
            sh = max(18, self.top * 0.3)
            sy = self.y + (self.top - sh) / 2
            s += f'<path fill="{slot_color}" d="{rrect(self.cx - sw/2, sy, sw, sh, sh/2)}"/>'
        return rot(s, self.a, self.cx, self.cy)

    def screen_rect(self):
        return (self.x + self.side, self.y + self.top,
                self.w - 2 * self.side, self.h - self.top - self.bottom)

    def screen(self, color=SCREEN, fill=None):
        x, y, w, h = self.screen_rect()
        f = fill or color
        return rot(f'<path fill="{f}" d="{rrect(x, y, w, h, self.sr)}"/>', self.a, self.cx, self.cy)

    def screen_center(self):
        x, y, w, h = self.screen_rect()
        return x + w / 2, y + h / 2

    def on(self, inner):
        """Place inner content in the phone's rotated frame."""
        return rot(inner, self.a, self.cx, self.cy)


# ---------- glyphs (drawn around cx, cy) ----------

def g_dot_arcs(cx, cy, color, s=1.0, sw=30, pairs=2, sides="both"):
    out = circle(cx, cy, 34 * s, color)
    radii = [72 * s, 127 * s, 182 * s][:pairs]
    for r in radii:
        if sides in ("both", "right"):
            out += stroke(arc(cx, cy, r, -45, 45), color, sw * s)
        if sides in ("both", "left"):
            out += stroke(arc(cx, cy, r, 135, 225), color, sw * s)
    return out


def g_bold_arc(cx, cy, color, s=1.0):
    out = circle(cx, cy + 60 * s, 46 * s, color)
    out += stroke(arc(cx, cy + 60 * s, 150 * s, 220, 320), color, 58 * s)
    return out


def g_link(cx, cy, color, s=1.0, sw=40):
    w, h = 210 * s, 110 * s
    o = 62 * s
    links = ""
    for dx in (-o, o):
        links += stroke(rrect(cx + dx - w / 2, cy - h / 2, w, h, h / 2), color, sw * s)
    return f'<g transform="rotate(-45 {cx} {cy})">{links}</g>'


def arrow(x0, y0, x1, y1, color, sw, head=40):
    ang = math.atan2(y1 - y0, x1 - x0)
    hx1 = x1 - head * math.cos(ang - math.radians(40))
    hy1 = y1 - head * math.sin(ang - math.radians(40))
    hx2 = x1 - head * math.cos(ang + math.radians(40))
    hy2 = y1 - head * math.sin(ang + math.radians(40))
    d = f"M {x0:.1f} {y0:.1f} L {x1:.1f} {y1:.1f} M {hx1:.1f} {hy1:.1f} L {x1:.1f} {y1:.1f} L {hx2:.1f} {hy2:.1f}"
    return stroke(d, color, sw)


def g_arrows(cx, cy, color, s=1.0, sw=36):
    o, L = 58 * s, 125 * s
    return (arrow(cx - o, cy + L, cx - o, cy - L, color, sw * s, 62 * s) +
            arrow(cx + o, cy - L, cx + o, cy + L, color, sw * s, 62 * s))


def arc_arrow(cx, cy, r, a0, a1, color, sw, head=44):
    """Arc with an arrowhead at the a1 end."""
    d = arc(cx, cy, r, a0, a1)
    ex, ey = pt(cx, cy, r, a1)
    direction = 1 if a1 > a0 else -1
    tang = math.radians(a1 + 90 * direction)
    hx1 = ex - head * math.cos(tang - math.radians(38))
    hy1 = ey - head * math.sin(tang - math.radians(38))
    hx2 = ex - head * math.cos(tang + math.radians(38))
    hy2 = ey - head * math.sin(tang + math.radians(38))
    d += f" M {hx1:.1f} {hy1:.1f} L {ex:.1f} {ey:.1f} L {hx2:.1f} {hy2:.1f}"
    return stroke(d, color, sw)


def laptop(x, y, w, h, lid, display, base=None, bezel=22, r=34):
    """MacBook: lid (x,y,w,h) and a base bar below that is wider."""
    base = base or lid
    s = f'<path fill="{lid}" d="{rrect(x, y, w, h, r)}"/>'
    s += f'<path fill="{display}" d="{rrect(x+bezel, y+bezel, w-2*bezel, h-2*bezel, r-bezel+6)}"/>'
    bw = w * 1.14
    bx = x - (bw - w) / 2
    s += f'<path fill="{base}" d="M {bx:.1f} {y+h+2:.1f} H {bx+bw:.1f} V {y+h+20:.1f} A 22 22 0 0 1 {bx+bw-22:.1f} {y+h+42:.1f} H {bx+22:.1f} A 22 22 0 0 1 {bx:.1f} {y+h+20:.1f} Z"/>'
    return s


# ---------- icon document ----------

def bg(color, kind="automatic-gradient", dark=None):
    if dark:
        return {"fill-specializations": [
            {"value": {kind: srgb(color)}},
            {"appearance": "dark", "value": {kind: srgb(dark)}}]}
    return {"fill": {kind: srgb(color)}}


def layer(name, content, glass=True, dark_fill=None, opacity=None):
    l = {"name": name, "image-name": f"{name}.svg", "glass": glass, "_svg": content}
    if dark_fill:
        l["fill-specializations"] = [{"value": "automatic"},
                                     {"appearance": "dark", "value": {"solid": srgb(dark_fill)}}]
    if opacity is not None:
        l["opacity"] = opacity
    return l


def group(*layers, shadow="neutral", sop=0.5, trans=0.0, lighting=None, specular=None):
    g = {"layers": list(layers),
         "shadow": {"kind": shadow, "opacity": sop},
         "translucency": {"enabled": trans > 0, "value": trans}}
    if lighting:
        g["lighting"] = lighting
    if specular is not None:
        g["specular"] = specular
    return g


VARIANTS = []


def variant(num, slug, sym, desc):
    def deco(fn):
        VARIANTS.append((num, slug, sym, desc, fn))
        return fn
    return deco


# =====================  SYMMETRIC  =====================

@variant(1, "classic-refined", "symmetric",
         "The current icon refined: rounder dark phone, light screen, bolder dot-and-arcs, KDE blue gradient.")
def v01():
    p = Phone(w=400, h=720, r=96, top=92, bottom=72, side=30, sr=30)
    cx, cy = p.screen_center()
    return bg("#1D99F3"), [
        group(layer("glyph", svg(g_dot_arcs(cx, cy, KDE, s=1.05, sw=32))), sop=0.3),
        group(layer("screen", svg(p.screen()), glass=False, dark_fill="#2D3033"),
              layer("body", svg(p.body()))),
    ]


@variant(2, "navy-blue-screen", "symmetric",
         "Deep navy background, graphite glass phone with a glowing KDE-blue screen and white signal arcs.")
def v02():
    p = Phone(w=410, h=720, r=90, top=88, bottom=70, side=28, sr=34)
    cx, cy = p.screen_center()
    grad = ('<linearGradient id="s" x1="0" y1="0" x2="0" y2="1">'
            '<stop offset="0" stop-color="#4FB6FF"/><stop offset="1" stop-color="#1366C8"/></linearGradient>')
    return bg("#0E2150", dark="#070F26"), [
        group(layer("glyph", svg(g_dot_arcs(cx, cy, WHITE, s=1.05, sw=30))), sop=0.25),
        group(layer("screen", svg(p.screen(fill="url(#s)"), grad), glass=False),
              layer("body", svg(p.body("#3A404C", "#1C2028")))),
    ]


@variant(3, "white-minimal", "symmetric",
         "White background, near-black phone, KDE-blue screen with a white glyph; flips to dark in Dark mode.")
def v03():
    p = Phone(w=380, h=700, r=88, top=86, bottom=70, side=26, sr=30)
    cx, cy = p.screen_center()
    return bg("#F4F6F8", kind="solid", dark="#1B1D20"), [
        group(layer("glyph", svg(g_dot_arcs(cx, cy, WHITE, s=0.95, sw=32))), sop=0.2),
        group(layer("screen", svg(p.screen(KDE)), glass=False),
              layer("body", svg(p.body("#1E2023", "#000000")))),
    ]


@variant(4, "graphite-silver", "symmetric",
         "Graphite background with a silver glass phone, dark screen and a KDE-blue glyph (inverted classic).")
def v04():
    p = Phone(w=410, h=720, r=92)
    cx, cy = p.screen_center()
    return bg("#3A3D42"), [
        group(layer("glyph", svg(g_dot_arcs(cx, cy, KDE, s=1.05, sw=32))), sop=0.3),
        group(layer("screen", svg(p.screen("#1F2226")), glass=False),
              layer("body", svg(p.body("#D5DAE0", "#9AA1AA")))),
    ]


@variant(5, "teal-bold-arc", "symmetric",
         "Teal background; the screen carries one heavy arc over a dot, a simpler and bolder signal mark.")
def v05():
    p = Phone(w=400, h=710, r=92)
    cx, cy = p.screen_center()
    return bg("#14A9A0"), [
        group(layer("glyph", svg(g_bold_arc(cx, cy - 20, "#0E7F79", s=0.95))), sop=0.3),
        group(layer("screen", svg(p.screen("#E9F3F2")), glass=False, dark_fill="#22302F"),
              layer("body", svg(p.body("#263233", "#121919")))),
    ]


@variant(6, "link-glyph", "symmetric",
         "Classic phone silhouette with a two-loop chain-link glyph on the screen instead of signal arcs.")
def v06():
    p = Phone(w=410, h=720, r=90)
    cx, cy = p.screen_center()
    return bg("#1D99F3"), [
        group(layer("glyph", svg(g_link(cx, cy, KDE, s=1.0, sw=40))), sop=0.3),
        group(layer("screen", svg(p.screen()), glass=False, dark_fill="#2D3033"),
              layer("body", svg(p.body()))),
    ]


@variant(7, "arrows-exchange", "symmetric",
         "Royal-blue gradient; two opposing arrows on the screen say 'send and receive'.")
def v07():
    p = Phone(w=410, h=720, r=90)
    cx, cy = p.screen_center()
    return bg("#1559C9"), [
        group(layer("glyph", svg(g_arrows(cx, cy, "#1559C9", s=1.05))), sop=0.3),
        group(layer("screen", svg(p.screen("#EAF0FA")), glass=False, dark_fill="#24282F"),
              layer("body", svg(p.body("#232631")))),
    ]


@variant(8, "chunky-light", "symmetric",
         "Short, chunky toy-like phone with big corner radii on a pale blue-grey background, one arc pair.")
def v08():
    p = Phone(w=500, h=620, r=130, top=100, bottom=80, side=40, sr=56)
    cx, cy = p.screen_center()
    return bg("#DDE8F3", dark="#1C232B"), [
        group(layer("glyph", svg(g_dot_arcs(cx, cy, KDE, s=1.35, sw=30, pairs=2))), sop=0.25),
        group(layer("screen", svg(p.screen("#FFFFFF")), glass=False, dark_fill="#2B3036"),
              layer("body", svg(p.body("#2C3E50", "#18222C")))),
    ]


@variant(9, "clear-glass-phone", "symmetric",
         "The phone is pure clear Liquid Glass with no screen colour; only a white glyph floats inside it.")
def v09():
    p = Phone(w=420, h=730, r=100, slot=False)
    cx, cy = p.screen_center()
    return bg("#1D99F3"), [
        group(layer("glyph", svg(g_dot_arcs(cx, cy - 10, WHITE, s=1.15, sw=34))), sop=0.25),
        group(layer("body", svg(p.body("#FFFFFF"))), sop=0.35, trans=0.6, specular=True),
    ]


# =====================  ASYMMETRIC  =====================

@variant(10, "tilt-arcs-right", "asymmetric",
         "Phone tilted left and placed left of centre; three glass arcs radiate out of its right edge into the open space.")
def v10():
    p = Phone(cx=400, cy=540, w=360, h=640, r=80, a=-10)
    cx, cy = p.screen_center()
    ac = (590, 470)
    arcs = "".join(stroke(arc(*ac, r, -48, 48), WHITE, 42) for r in (90, 180, 270))
    return bg("#1D99F3"), [
        group(layer("glyph", svg(p.on(circle(cx, cy, 52, KDE)))), sop=0.3),
        group(layer("screen", svg(p.screen()), glass=False, dark_fill="#2D3033"),
              layer("body", svg(p.body()))),
        group(layer("arcs", svg(arcs)), sop=0.2, trans=0.3),
    ]


@variant(11, "corner-broadcast", "asymmetric",
         "Phone sits low-left; quarter arcs fan from its top-right corner toward the empty top-right of the tile.")
def v11():
    p = Phone(cx=400, cy=610, w=370, h=620, r=84)
    corner = (p.x + p.w - 30, p.y + 30)
    arcs = "".join(stroke(arc(*corner, r, -84, -6), WHITE, 42) for r in (100, 180, 260))
    sx, sy = p.screen_center()
    return bg("#1A7FD6"), [
        group(layer("glyph", svg(circle(sx, sy, 50, "#1A7FD6")))),
        group(layer("arcs", svg(arcs)), sop=0.25, trans=0.2),
        group(layer("screen", svg(p.screen()), glass=False, dark_fill="#2D3033"),
              layer("body", svg(p.body()))),
    ]


@variant(12, "offset-big-arcs", "asymmetric",
         "Slim upright phone on the left third, balanced by three large white arcs on the right.")
def v12():
    p = Phone(cx=360, cy=512, w=330, h=620, r=74, top=80, bottom=64, side=26)
    sx, sy = p.screen_center()
    arcs = "".join(stroke(arc(sx, sy, r, -38, 38), WHITE, 46) for r in (300, 410, 520))
    return bg("#0F3A7A", dark="#081a38"), [
        group(layer("glyph", svg(g_dot_arcs(sx, sy, KDE, s=0.8, sw=34, pairs=1, sides="right")))),
        group(layer("screen", svg(p.screen("#E6EEF8")), glass=False, dark_fill="#2D3033"),
              layer("body", svg(p.body("#2B3442")))),
        group(layer("arcs", svg(arcs)), sop=0.2, trans=0.25),
    ]


@variant(13, "macbook-behind", "asymmetric",
         "A MacBook sits back-left in translucent glass; the dark phone stands in front at the right, glyph facing the Mac.")
def v13():
    lap = laptop(110, 250, 600, 400, "#E8EDF2", "#9CCBF5", "#D3DAE2")
    p = Phone(cx=710, cy=560, w=300, h=540, r=66, top=70, bottom=56, side=24, sr=20)
    sx, sy = p.screen_center()
    return bg("#1D99F3"), [
        group(layer("glyph", svg(g_dot_arcs(sx, sy, KDE, s=0.75, sw=36, pairs=2, sides="left")))),
        group(layer("screen", svg(p.screen()), glass=False, dark_fill="#2D3033"),
              layer("body", svg(p.body()))),
        group(layer("laptop", svg(lap)), sop=0.3, trans=0.35),
    ]


@variant(14, "display-and-tilted-phone", "asymmetric",
         "Navy tile: a studio display upper-left and a slightly tilted phone lower-right, linked by a chain glyph.")
def v14():
    disp = f'<path fill="#C7D3E3" d="{rrect(110, 170, 560, 380, 36)}"/>'
    disp += f'<path fill="#2A63B8" d="{rrect(132, 192, 516, 336, 18)}"/>'
    disp += f'<path fill="#AFBCCD" d="M 340 550 H 440 L 460 640 H 320 Z"/>'
    disp += f'<path fill="#AFBCCD" d="{rrect(280, 632, 220, 26, 13)}"/>'
    p = Phone(cx=700, cy=600, w=300, h=520, r=66, a=8, top=66, bottom=54, side=24, sr=20)
    sx, sy = p.screen_center()
    return bg("#0F2557"), [
        group(layer("glyph", svg(p.on(g_link(sx, sy, KDE, s=0.6, sw=44))))),
        group(layer("screen", svg(p.screen("#EEF2F7")), glass=False, dark_fill="#2D3033"),
              layer("body", svg(p.body("#1B1E24", "#000")))),
        group(layer("display", svg(disp)), sop=0.3, trans=0.3),
    ]


@variant(15, "two-phones-fanned", "asymmetric",
         "Two phones fanned like cards: a clear glass one tilted behind, the dark one in front tilted the other way.")
def v15():
    back = Phone(cx=420, cy=500, w=360, h=640, r=84, a=-14)
    p = Phone(cx=590, cy=540, w=360, h=640, r=84, a=7)
    sx, sy = p.screen_center()
    return bg("#14A9A0", dark="#0B3F3C"), [
        group(layer("glyph", svg(p.on(g_dot_arcs(sx, sy, "#14A9A0", s=0.85, sw=34))))),
        group(layer("screen", svg(p.screen("#ECF6F5")), glass=False, dark_fill="#22302F"),
              layer("body", svg(p.body("#263233", "#121919")))),
        group(layer("back", svg(back.body("#FFFFFF", "#FFFFFF"))), sop=0.25, trans=0.55),
    ]


@variant(16, "frame-breaker", "asymmetric",
         "An oversized phone tilts in from the lower-right and is cut by the tile edge; big arcs fill its screen.")
def v16():
    p = Phone(cx=620, cy=660, w=600, h=1040, r=120, a=-14, top=120, bottom=90, side=44, sr=40)
    sx, sy = 470, 560
    g = (circle(sx, sy, 48, KDE) +
         "".join(stroke(arc(sx, sy, r, -55, 35), KDE, 40) for r in (100, 175, 250)))
    return bg("#1D99F3"), [
        group(layer("glyph", svg(p.on(g)))),
        group(layer("screen", svg(p.screen()), glass=False, dark_fill="#2D3033"),
              layer("body", svg(p.body()))),
    ]


@variant(17, "laptop-front-phone-side", "asymmetric",
         "Graphite tile: a MacBook in front lower-left with exchange arrows on its display, a phone leaning at the right.")
def v17():
    lap = laptop(100, 380, 560, 360, "#C9CFD7", "#1F2328", "#B5BCC6")
    p = Phone(cx=760, cy=470, w=270, h=480, r=60, a=10, top=62, bottom=50, side=22, sr=18)
    arrows = g_arrows(380, 560, KDE, s=0.85, sw=40)
    return bg("#2E3136"), [
        group(layer("arrows", svg(arrows))),
        group(layer("laptop", svg(lap)), sop=0.45),
        group(layer("pscreen", svg(p.screen(KDE)), glass=False),
              layer("pbody", svg(p.body("#E4E8ED", "#9AA1AA"))), sop=0.4),
    ]


@variant(18, "white-tilt-glyph-out", "asymmetric",
         "White tile, tilted dark phone at left; the blue signal glyph breaks out past the screen edge to the right.")
def v18():
    p = Phone(cx=430, cy=540, w=370, h=660, r=84, a=-12)
    gx, gy = 640, 430
    g = g_dot_arcs(gx, gy, KDE, s=1.2, sw=34, pairs=3, sides="right")
    return bg("#F4F6F8", kind="solid", dark="#1B1D20"), [
        group(layer("glyph", svg(g)), sop=0.3),
        group(layer("screen", svg(p.screen("#E8EDF2")), glass=False, dark_fill="#2D3033"),
              layer("body", svg(p.body("#1E2023", "#000")))),
    ]


@variant(19, "glass-stack", "asymmetric",
         "Three overlapping glass panes (Mac window, phone, notification chip) stepped diagonally for depth.")
def v19():
    win = f'<path fill="#FFFFFF" d="{rrect(110, 150, 520, 380, 40)}"/>'
    win += "".join(circle(150 + i * 34, 190, 11, c) for i, c in enumerate(("#FF5F57", "#FEBC2E", "#28C840")))
    p = Phone(cx=560, cy=560, w=320, h=560, r=72, top=70, bottom=56, side=24)
    chip = f'<path fill="#FFFFFF" d="{rrect(560, 690, 360, 140, 70)}"/>' + circle(630, 760, 38, KDE)
    chip += stroke("M 690 740 H 860 M 690 784 H 800", "#8EA3BA", 24)
    return bg("#122C66", dark="#08142F"), [
        group(layer("chip", svg(chip)), sop=0.4),
        group(layer("screen", svg(p.screen("#1D99F3")), glass=False),
              layer("body", svg(p.body("#262A33", "#0F1115")))),
        group(layer("window", svg(win)), sop=0.25, trans=0.5),
    ]


@variant(20, "notification-pop", "asymmetric",
         "Phone left of centre with a white glass notification bubble popping out over its right edge.")
def v20():
    p = Phone(cx=410, cy=560, w=380, h=660, r=86)
    bub = f'<path fill="#FFFFFF" d="{rrect(470, 230, 440, 170, 85)}"/>'
    bub += f'<path fill="#FFFFFF" d="M 560 390 L 520 450 L 620 395 Z"/>'
    icon = circle(555, 315, 44, KDE) + stroke("M 625 290 H 840 M 625 342 H 770", "#9DB0C4", 26)
    sx, sy = p.screen_center()
    return bg("#1D99F3"), [
        group(layer("bubble-content", svg(icon), glass=False),
              layer("bubble", svg(bub)), sop=0.45),
        group(layer("screen", svg(p.screen()), glass=False, dark_fill="#2D3033"),
              layer("body", svg(p.body()))),
    ]


@variant(21, "handoff-arc", "asymmetric",
         "Teal tile: small phone low-left, Mac window high-right, one dashed arrow arc carrying data between them.")
def v21():
    p = Phone(cx=320, cy=640, w=280, h=480, r=62, a=-6, top=62, bottom=50, side=22, sr=18)
    win = f'<path fill="#F2F7F7" d="{rrect(520, 150, 400, 300, 36)}"/>'
    win += f'<path fill="#0E7F79" d="{rrect(520, 150, 400, 56, 28)}"/>'
    win += f'<path fill="#F2F7F7" d="M 520 190 H 920 V 206 H 520 Z"/>'
    win += stroke("M 570 270 H 860 M 570 330 H 760 M 570 390 H 820", "#B8D3D1", 26)
    a = arc_arrow(560, 650, 230, 170, 285, WHITE, 40, head=54)
    a = a.replace("/>", 'stroke-dasharray="1 0"/>')
    return bg("#14A9A0", dark="#0B3F3C"), [
        group(layer("arc", svg(a)), sop=0.3),
        group(layer("screen", svg(p.screen("#E9F3F2")), glass=False, dark_fill="#22302F"),
              layer("body", svg(p.body("#263233", "#121919")))),
        group(layer("window", svg(win)), sop=0.3, trans=0.2),
    ]


@variant(22, "graphite-ripples", "asymmetric",
         "Dark graphite tile; blue ripple rings spread from the lower-left corner behind a tilted silver phone.")
def v22():
    p = Phone(cx=600, cy=500, w=360, h=640, r=84, a=9)
    rings = "".join(stroke(arc(230, 800, r, 0, 359.9), KDE, 36, f'opacity="{o}"')
                    for r, o in ((150, 1), (270, 0.75), (390, 0.5)))
    sx, sy = p.screen_center()
    return bg("#1E2024"), [
        group(layer("glyph", svg(p.on(circle(sx, sy, 50, KDE))))),
        group(layer("screen", svg(p.screen("#16181B")), glass=False),
              layer("body", svg(p.body("#D5DAE0", "#9AA1AA")))),
        group(layer("rings", svg(rings)), sop=0.2),
    ]


@variant(23, "sweep-arc", "asymmetric",
         "One huge glass swoosh arcs from lower-left to upper-right behind a phone set slightly left.")
def v23():
    p = Phone(cx=460, cy=530, w=380, h=680, r=88)
    sw = stroke(arc(820, 880, 650, 186, 272), WHITE, 80)
    sx, sy = p.screen_center()
    return bg("#1366C8"), [
        group(layer("glyph", svg(g_dot_arcs(sx, sy, "#1366C8", s=0.9, sw=34)))),
        group(layer("screen", svg(p.screen("#EAF2FC")), glass=False, dark_fill="#2D3033"),
              layer("body", svg(p.body("#1C2333")))),
        group(layer("swoosh", svg(sw)), sop=0.2, trans=0.3),
    ]


@variant(24, "phone-and-orb", "asymmetric",
         "Indigo tile: tilted phone low-left, a glass orb (the Mac) high-right, joined by an arc bridge.")
def v24():
    p = Phone(cx=400, cy=580, w=350, h=620, r=80, a=-8)
    orb = circle(760, 280, 120, "#FFFFFF")
    bridge = stroke(arc(760, 640, 330, 182, 262), WHITE, 40, 'stroke-dasharray="0.1 70"')
    sx, sy = p.screen_center()
    return bg("#4B4FD8", dark="#1A1B4A"), [
        group(layer("orb", svg(orb)), sop=0.35, trans=0.3),
        group(layer("glyph", svg(p.on(circle(sx, sy, 52, "#4B4FD8"))))),
        group(layer("screen", svg(p.screen("#ECEDFB")), glass=False, dark_fill="#25263A"),
              layer("body", svg(p.body("#22233A", "#0D0E1A")))),
        group(layer("bridge", svg(bridge)), sop=0.0, shadow="none"),
    ]


@variant(25, "peek-from-bottom", "asymmetric",
         "Phone rises from the bottom edge off-centre, cropped by the tile; signal arcs bloom above it to the right.")
def v25():
    p = Phone(cx=420, cy=800, w=440, h=760, r=100, top=104, bottom=80, side=36, sr=34)
    ax, ay = 570, 390
    arcs = circle(ax, ay, 46, WHITE) + "".join(
        stroke(arc(ax, ay, r, -120, 0), WHITE, 42) for r in (100, 180, 260))
    sx = p.cx
    return bg("#38B2FF"), [
        group(layer("arcs", svg(arcs)), sop=0.3),
        group(layer("screen", svg(p.screen()), glass=False, dark_fill="#2D3033"),
              layer("body", svg(p.body()))),
    ]


@variant(26, "macbook-front-phone-back", "asymmetric",
         "Reverse depth: a dark phone stands behind upper-right, a silver glass MacBook overlaps it from the lower-left.")
def v26():
    p = Phone(cx=660, cy=420, w=320, h=580, r=72, a=6, top=70, bottom=56, side=26)
    sx, sy = p.screen_center()
    lap = laptop(110, 470, 520, 330, "#E9EDF1", "#BFD9F2", "#D2D8DF")
    lglyph = g_dot_arcs(370, 635, KDE, s=0.6, sw=40, pairs=2)
    return bg("#0F3A7A", dark="#081a38"), [
        group(layer("lglyph", svg(lglyph))),
        group(layer("laptop", svg(lap)), sop=0.4, trans=0.25),
        group(layer("screen", svg(p.screen(KDE)), glass=False),
              layer("body", svg(p.body("#20242C", "#0B0D10")))),
    ]


@variant(27, "orbit-arrows", "asymmetric",
         "Tilted phone with two curved arrows orbiting it top-right and bottom-left (rotational, not mirror, balance).")
def v27():
    p = Phone(cx=512, cy=512, w=340, h=600, r=78, a=-16)
    a1 = arc_arrow(512, 512, 390, -80, -10, WHITE, 44, 56)
    a2 = arc_arrow(512, 512, 390, 100, 170, WHITE, 44, 56)
    sx, sy = p.screen_center()
    return bg("#1D99F3"), [
        group(layer("glyph", svg(p.on(circle(sx, sy, 50, KDE))))),
        group(layer("screen", svg(p.screen()), glass=False, dark_fill="#2D3033"),
              layer("body", svg(p.body()))),
        group(layer("arrows", svg(a1 + a2)), sop=0.25, trans=0.2),
    ]


@variant(28, "side-arcs-dark-screen", "asymmetric",
         "Navy-to-blue tile; phone offset right with a dark screen; blue-white arcs leave from its left edge only.")
def v28():
    p = Phone(cx=610, cy=512, w=370, h=660, r=86, a=0)
    sx, sy = p.screen_center()
    arcs = "".join(stroke(arc(p.x + 20, sy, r, 140, 220), c, 44)
                   for r, c in ((110, "#FFFFFF"), (215, "#BFE3FF"), (320, "#7CC4FA")))
    return bg("#0B4DA2"), [
        group(layer("glyph", svg(circle(sx, sy, 56, KDE)))),
        group(layer("screen", svg(p.screen("#111418")), glass=False),
              layer("body", svg(p.body("#3B4250", "#20242C")))),
        group(layer("arcs", svg(arcs)), sop=0.2, trans=0.15),
    ]


@variant(29, "stacked-phones-offset", "asymmetric",
         "Two upright phones offset diagonally (Mac-side and phone-side), the back one KDE-blue glass, signal dot between.")
def v29():
    back = Phone(cx=420, cy=440, w=340, h=600, r=78)
    p = Phone(cx=610, cy=590, w=340, h=600, r=78)
    sx, sy = p.screen_center()
    return bg("#E8EEF5", kind="solid", dark="#15181C"), [
        group(layer("glyph", svg(g_dot_arcs(sx, sy, KDE, s=0.8, sw=36, pairs=2, sides="left")))),
        group(layer("screen", svg(p.screen("#F7F9FB")), glass=False, dark_fill="#2D3033"),
              layer("body", svg(p.body("#1E2023", "#000")))),
        group(layer("back", svg(back.body(KDE, "#0E6FB8"))), sop=0.3, trans=0.2),
    ]


@variant(30, "landscape-tilt", "asymmetric",
         "Phone turned almost landscape and tilted, low in the tile, with a single bold arc above it to the right.")
def v30():
    p = Phone(cx=470, cy=610, w=360, h=640, r=84, a=-72)
    sx, sy = p.screen_center()
    g = circle(690, 300, 48, WHITE) + stroke(arc(690, 300, 150, 150, 300), WHITE, 56)
    return bg("#1D99F3"), [
        group(layer("arc", svg(g)), sop=0.3),
        group(layer("screen", svg(p.screen()), glass=False, dark_fill="#2D3033"),
              layer("body", svg(p.body()))),
    ]


# =====================  build  =====================

def build():
    readme = ["# KDE Connect Native icon variants", "",
              "Each `vNN-name.icon` is an Icon Composer document. Renders: `renders/`. Contact sheets: `contact-*.png`.", ""]
    for num, slug, sym, desc, fn in VARIANTS:
        fill, groups = fn()
        name = f"v{num:02d}-{slug}"
        d = os.path.join(OUT, f"{name}.icon")
        if os.path.exists(d):
            shutil.rmtree(d)
        os.makedirs(os.path.join(d, "Assets"))
        for g in groups:
            for l in g["layers"]:
                with open(os.path.join(d, "Assets", l["image-name"]), "w") as f:
                    f.write(l.pop("_svg"))
        doc = dict(fill)
        doc["groups"] = groups
        doc["supported-platforms"] = {"squares": ["macOS"]}
        with open(os.path.join(d, "icon.json"), "w") as f:
            json.dump(doc, f, indent=2)
        readme.append(f"- **{num:02d} {slug}** ({sym}): {desc}")
    with open(os.path.join(OUT, "README.md"), "w") as f:
        f.write("\n".join(readme) + "\n")
    print(len(VARIANTS), "variants")


if __name__ == "__main__":
    build()
