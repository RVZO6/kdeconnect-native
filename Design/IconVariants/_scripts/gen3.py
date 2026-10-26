#!/usr/bin/env python3
"""Round 3: variations of 25a / 25b / 20b. Does not touch earlier documents."""
import json, os, shutil, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen import (OUT, KDE, DARK, SLOT, SCREEN, WHITE, svg, rrect, rot, arc,
                 stroke, circle, Phone, bg, layer, group)
from gen2 import g_wifi

R3 = []
INCOMING = "#B7C3CF"
INCOMING_LINE = "#8A99A8"


def variant(vid, fname, sym, desc):
    def deco(fn):
        R3.append((vid, fname, sym, desc, fn))
        return fn
    return deco


class Modern(Phone):
    """Newer iPhone: thin uniform bezel, large radius, Dynamic Island inside the screen."""

    def __init__(self, cx=512, cy=512, w=420, h=860, a=0):
        b = round(w * 0.045)
        r = round(w * 0.2)
        super().__init__(cx=cx, cy=cy, w=w, h=h, r=r, a=a, side=b, top=b, bottom=b,
                         sr=r - b, slot=False)

    def island(self, color="#000000"):
        iw, ih = self.w * 0.31, self.w * 0.09
        iy = self.y + self.top + self.w * 0.035
        return self.on(f'<path fill="{color}" d="{rrect(self.cx - iw/2, iy, iw, ih, ih/2)}"/>')

    def content_top(self):
        return self.y + self.top + self.w * 0.17


def chat(x, y, w, rows=3, style="pill", out=KDE, inc=INCOMING, inc_line=INCOMING_LINE,
         h=None, gap=None, widths=(0.66, 0.52, 0.72, 0.46)):
    """Minimal texting UI inside a screen-local box starting at (x, y), width w.
    style 'pill': filled bubbles; style 'dotline': avatar dot + rounded text lines."""
    h = h or w * 0.17
    gap = gap or h * 0.42
    pad = w * 0.07
    s = ""
    for i in range(rows):
        left = i % 2 == 0
        by = y + i * (h + gap)
        bw = (w - 2 * pad) * widths[i % len(widths)]
        bx = x + pad if left else x + w - pad - bw
        if style == "pill":
            col = inc if left else out
            s += f'<path fill="{col}" d="{rrect(bx, by, bw, h, h/2)}"/>'
            lc = inc_line if left else "#FFFFFF"
            lx0, lx1 = bx + h * 0.5, bx + bw - h * 0.5 - bw * 0.25 * (i % 2)
            s += stroke(f"M {lx0:.1f} {by + h/2:.1f} H {lx1:.1f}", lc, h * 0.2, 'opacity="0.75"')
        else:
            dr = h * 0.46
            col = inc if left else out
            dcx = x + pad + dr if left else x + w - pad - dr
            s += circle(round(dcx, 1), round(by + h / 2, 1), round(dr, 1), col)
            lw = h * 0.36
            l0 = dcx + dr + h * 0.4 if left else dcx - dr - h * 0.4
            L = bw - 2 * dr - h * 0.4
            for j, f in enumerate((1.0, 0.6)):
                ly = by + h / 2 - h * 0.26 + j * h * 0.52
                end = l0 + L * f if left else l0 - L * f
                s += stroke(f"M {l0:.1f} {ly:.1f} H {end:.1f}", col, lw)
    return s


def quarter_arcs(ax, ay, radii=(105, 185, 265), a0=-125, a1=-5, color=WHITE, sw=46, dot=52):
    return circle(ax, ay, dot, color) + "".join(stroke(arc(ax, ay, r, a0, a1), color, sw) for r in radii)


def camera_back(p, plate="#FFFFFF", lens="#15171B", ring="#5E6670", flash="#F4E9C8"):
    """Camera plateau at the top-left of the back, in the phone's frame."""
    s0 = p.w * 0.44
    x0 = p.x + p.w * 0.065
    y0 = p.y + p.w * 0.065
    plate_svg = f'<path fill="{plate}" d="{rrect(x0, y0, s0, s0, s0 * 0.3)}"/>'
    lenses = ""
    for fx, fy in ((0.29, 0.29), (0.29, 0.71), (0.71, 0.5)):
        cx, cy = x0 + fx * s0, y0 + fy * s0
        lenses += circle(round(cx, 1), round(cy, 1), round(s0 * 0.2, 1), ring)
        lenses += circle(round(cx, 1), round(cy, 1), round(s0 * 0.15, 1), lens)
        lenses += circle(round(cx + s0 * 0.04, 1), round(cy - s0 * 0.04, 1), round(s0 * 0.035, 1), "#4A6A9A")
    lenses += circle(round(x0 + 0.72 * s0, 1), round(y0 + 0.2 * s0, 1), round(s0 * 0.06, 1), flash)
    lenses += circle(round(x0 + 0.72 * s0, 1), round(y0 + 0.8 * s0, 1), round(s0 * 0.03, 1), "#2A2E35")
    return p.on(plate_svg), p.on(lenses)


# ============ 1. 25a + messaging UI ============

def p25a():
    return Phone(cx=410, cy=850, w=520, h=860, r=116, top=116, bottom=90, side=40, sr=38)


@variant("25a-1", "v25a-r3-chat-bubbles", "asymmetric",
         "25a with a minimal texting screen: three filled bubbles alternating grey left and KDE-blue right.")
def r25a1():
    p = p25a()
    x, y, w, h = p.screen_rect()
    return bg("#38B2FF"), [
        group(layer("arcs", svg(quarter_arcs(645, 375))), sop=0.3),
        group(layer("chat", svg(chat(x, y + 48, w, rows=3))), sop=0.15),
        group(layer("screen", svg(p.screen()), glass=False, dark_fill="#2D3033"),
              layer("body", svg(p.body()))),
    ]


@variant("25a-2", "v25a-r3-chat-dark-screen", "asymmetric",
         "25a with a dark screen and dot-plus-line messages (white incoming, KDE-blue outgoing).")
def r25a2():
    p = p25a()
    x, y, w, h = p.screen_rect()
    return bg("#38B2FF"), [
        group(layer("arcs", svg(quarter_arcs(645, 375))), sop=0.3),
        group(layer("chat", svg(chat(x, y + 50, w, rows=4, style="dotline", inc="#E8EDF2",
                                      h=w * 0.15, gap=w * 0.07)))),
        group(layer("screen", svg(p.screen("#16191D")), glass=False),
              layer("body", svg(p.body("#2A2C2F", "#000")))),
    ]


@variant("25a-3", "v25a-r3-island-chat", "asymmetric",
         "25a as a newer iPhone (thin bezel, big radius, Dynamic Island) with three chat bubbles.")
def r25a3():
    p = Modern(cx=410, cy=860, w=520, h=900)
    x, y, w, h = p.screen_rect()
    return bg("#38B2FF"), [
        group(layer("arcs", svg(quarter_arcs(650, 360))), sop=0.3),
        group(layer("chat", svg(chat(x, p.content_top(), w, rows=3, widths=(0.62, 0.5, 0.7)))), sop=0.15),
        group(layer("island", svg(p.island()), glass=False),
              layer("screen", svg(p.screen("#EEF2F5")), glass=False, dark_fill="#2D3033"),
              layer("body", svg(p.body("#2A2C2F")))),
    ]


@variant("25a-4", "v25a-r3-chat-wifi-upright", "asymmetric",
         "25a composition, but the signal above-right is an upright Wi-Fi mark; teal and blue chat pills on screen.")
def r25a4():
    p = p25a()
    x, y, w, h = p.screen_rect()
    return bg("#2AA7F5"), [
        group(layer("wifi", svg(g_wifi(735, 255, WHITE, s=0.92, sw=44))), sop=0.3),
        group(layer("chat", svg(chat(x, y + 48, w, rows=3, out="#14A9A0", inc="#BFD0DD")))),
        group(layer("screen", svg(p.screen()), glass=False, dark_fill="#2D3033"),
              layer("body", svg(p.body()))),
    ]


@variant("25a-5", "v25a-r3-back-camera", "asymmetric",
         "The BACK of a newer iPhone (graphite glass, camera plateau top-left) rises from the bottom; quarter arcs above-right.")
def r25a5():
    p = Modern(cx=420, cy=860, w=520, h=900)
    plate, lenses = camera_back(p)
    return bg("#38B2FF"), [
        group(layer("arcs", svg(quarter_arcs(660, 360))), sop=0.3),
        group(layer("lenses", svg(lenses), glass=False), layer("plate", svg(plate)), sop=0.4),
        group(layer("back", svg(p.body("#3E4450"))), sop=0.5),
    ]


# ============ 2. 25b with Wi-Fi outside ============

@variant("25b-1", "v25b-r3-wifi-above-left-chat", "asymmetric",
         "25b's large tilted phone sits lower; an upright Wi-Fi mark floats above-left and the screen shows chat bubbles.")
def r25b1():
    p = Phone(cx=600, cy=930, w=620, h=1000, r=136, a=-6, top=126, bottom=96, side=46, sr=44)
    x, y, w, h = p.screen_rect()
    return bg("#38B2FF"), [
        group(layer("wifi", svg(g_wifi(300, 250, WHITE, s=1.0, sw=46))), sop=0.3),
        group(layer("chat", svg(p.on(chat(x, y + 46, w, rows=3)))), sop=0.15),
        group(layer("screen", svg(p.screen()), glass=False, dark_fill="#2D3033"),
              layer("body", svg(p.body()))),
    ]


@variant("25b-2", "v25b-r3-wifi-right-chat", "asymmetric",
         "Phone leans the other way at the left; an upright Wi-Fi mark sits top-right; dot-and-line messages on screen.")
def r25b2():
    p = Phone(cx=400, cy=900, w=600, h=1000, r=132, a=5, top=122, bottom=92, side=44, sr=42)
    x, y, w, h = p.screen_rect()
    return bg("#38B2FF"), [
        group(layer("wifi", svg(g_wifi(775, 240, WHITE, s=0.95, sw=46))), sop=0.3),
        group(layer("chat", svg(p.on(chat(x, y + 46, w, rows=3, style="dotline", h=w * 0.17, gap=w * 0.09))))),
        group(layer("screen", svg(p.screen()), glass=False, dark_fill="#2D3033"),
              layer("body", svg(p.body()))),
    ]


@variant("25b-3", "v25b-r3-glass-wifi-behind", "asymmetric",
         "Big glass Wi-Fi arcs radiate from behind the top of the tilted phone and fill the upper tile; chat bubbles on screen.")
def r25b3():
    p = Phone(cx=540, cy=900, w=600, h=1000, r=132, a=-6, top=124, bottom=94, side=44, sr=42)
    x, y, w, h = p.screen_rect()
    arcs = "".join(stroke(arc(530, 560, r, -138, -42), WHITE, 60) for r in (290, 420))
    return bg("#2A9DF0"), [
        group(layer("chat", svg(p.on(chat(x, y + 46, w, rows=3)))), sop=0.15),
        group(layer("screen", svg(p.screen()), glass=False, dark_fill="#2D3033"),
              layer("body", svg(p.body()))),
        group(layer("arcs", svg(arcs)), sop=0.25, trans=0.35),
    ]


@variant("25b-4", "v25b-r3-messages-rising", "asymmetric",
         "Two glass chat bubbles float up out of the big phone into the upper tile; a small Wi-Fi mark sits low on the screen.")
def r25b4():
    p = Phone(cx=560, cy=900, w=620, h=1000, r=136, a=-6, top=126, bottom=96, side=46, sr=44)
    x, y, w, h = p.screen_rect()
    b1 = f'<path fill="#FFFFFF" d="{rrect(110, 140, 470, 150, 75)}"/>'
    c1 = circle(185, 215, 42, KDE) + stroke("M 255 190 H 520 M 255 240 H 440", "#9DB0C4", 26)
    b2 = f'<path fill="#FFFFFF" d="{rrect(450, 300, 470, 150, 75)}"/>'
    c2 = stroke("M 510 350 H 770 M 590 400 H 770", "#9DB0C4", 26) + circle(845, 375, 42, "#14A9A0")
    sx, sy = p.screen_center()
    return bg("#38B2FF"), [
        group(layer("c1", svg(c1), glass=False), layer("b1", svg(b1)), sop=0.4),
        group(layer("c2", svg(c2), glass=False), layer("b2", svg(b2)), sop=0.35, trans=0.2),
        group(layer("glyph", svg(p.on(g_wifi(sx, y + 300, KDE, s=0.9, sw=40))))),
        group(layer("screen", svg(p.screen()), glass=False, dark_fill="#2D3033"),
              layer("body", svg(p.body()))),
    ]


@variant("25b-5", "v25b-r3-island-glass-wifi", "asymmetric",
         "25b-3 as a newer iPhone (Dynamic Island, thin bezel): glass Wi-Fi arcs behind the top, chat bubbles on screen.")
def r25b5():
    p = Modern(cx=540, cy=900, w=600, h=1000, a=-6)
    x, y, w, h = p.screen_rect()
    arcs = "".join(stroke(arc(530, 560, r, -138, -42), WHITE, 60) for r in (290, 420))
    return bg("#1D8FE6"), [
        group(layer("chat", svg(p.on(chat(x, p.content_top(), w, rows=3, out="#1D99F3")))), sop=0.15),
        group(layer("island", svg(p.island()), glass=False),
              layer("screen", svg(p.screen("#EEF2F5")), glass=False, dark_fill="#2D3033"),
              layer("body", svg(p.body("#2A2C2F")))),
        group(layer("arcs", svg(arcs)), sop=0.25, trans=0.35),
    ]


# ============ 3. 25b with the Wi-Fi mark lower ============

@variant("25b-6", "v25b-r3-wifi-lower", "asymmetric",
         "25b unchanged except the Wi-Fi mark sits lower on the screen, leaving more clear screen above it.")
def r25b6():
    p = Phone(cx=560, cy=820, w=640, h=1000, r=140, a=-6, top=130, bottom=100, side=48, sr=46)
    return bg("#38B2FF"), [
        group(layer("glyph", svg(p.on(g_wifi(560, 770, KDE, s=1.2, sw=40)))), sop=0.3),
        group(layer("screen", svg(p.screen()), glass=False, dark_fill="#2D3033"),
              layer("body", svg(p.body()))),
    ]


# ============ 4. modern iPhone + camera back ============

@variant("25b-7", "v25b-r3-back-camera-tilted", "asymmetric",
         "The silver back of a newer iPhone, tilted and cut by the bottom edge, camera plateau top-left; upright Wi-Fi top-right on navy.")
def r25b7():
    p = Modern(cx=460, cy=920, w=540, h=1000, a=8)
    plate, lenses = camera_back(p, plate="#FFFFFF", ring="#8C949E")
    return bg("#0F3A7A", dark="#081a38"), [
        group(layer("wifi", svg(g_wifi(770, 255, "#7CC4FA", s=0.82, sw=46))), sop=0.3),
        group(layer("lenses", svg(lenses), glass=False), layer("plate", svg(plate)), sop=0.4),
        group(layer("back", svg(p.body("#D3D9E0"))), sop=0.5),
    ]


@variant("20b-1", "v20b-r3-island", "asymmetric",
         "20b as a newer iPhone: thin bezel, large radius, Dynamic Island; two glass notifications cascade out to the right.")
def r20b1():
    p = Modern(cx=370, cy=585, w=420, h=780, a=-8)
    sx, sy = p.screen_center()
    b1 = f'<path fill="#FFFFFF" d="{rrect(440, 170, 500, 180, 90)}"/>'
    c1 = circle(530, 260, 50, KDE) + stroke("M 610 230 H 870 M 610 290 H 790", "#9DB0C4", 30)
    b2 = f'<path fill="#FFFFFF" d="{rrect(540, 420, 400, 150, 75)}"/>'
    c2 = circle(615, 495, 40, "#F67400") + stroke("M 680 470 H 880 M 680 520 H 820", "#9DB0C4", 26)
    return bg("#1D99F3"), [
        group(layer("c1", svg(c1), glass=False), layer("b1", svg(b1)), sop=0.45),
        group(layer("c2", svg(c2), glass=False), layer("b2", svg(b2)), sop=0.35, trans=0.25),
        group(layer("glyph", svg(p.on(g_wifi(sx, sy + 140, KDE, s=0.7, sw=40))))),
        group(layer("island", svg(p.island()), glass=False),
              layer("screen", svg(p.screen("#EEF2F5")), glass=False, dark_fill="#2D3033"),
              layer("body", svg(p.body("#2A2C2F")))),
    ]


@variant("20b-2", "v20b-r3-island-dark", "asymmetric",
         "20b-1 on a graphite tile with a dark screen and blue Wi-Fi; notifications stay white glass.")
def r20b2():
    p = Modern(cx=370, cy=585, w=420, h=780, a=-8)
    sx, sy = p.screen_center()
    b1 = f'<path fill="#FFFFFF" d="{rrect(440, 170, 500, 180, 90)}"/>'
    c1 = circle(530, 260, 50, KDE) + stroke("M 610 230 H 870 M 610 290 H 790", "#9DB0C4", 30)
    b2 = f'<path fill="#FFFFFF" d="{rrect(540, 420, 400, 150, 75)}"/>'
    c2 = circle(615, 495, 40, "#14A9A0") + stroke("M 680 470 H 880 M 680 520 H 820", "#9DB0C4", 26)
    return bg("#2E3136"), [
        group(layer("c1", svg(c1), glass=False), layer("b1", svg(b1)), sop=0.45),
        group(layer("c2", svg(c2), glass=False), layer("b2", svg(b2)), sop=0.35, trans=0.25),
        group(layer("glyph", svg(p.on(g_wifi(sx, sy + 140, KDE, s=0.7, sw=40))))),
        group(layer("island", svg(p.island()), glass=False),
              layer("screen", svg(p.screen("#15171A")), glass=False),
              layer("body", svg(p.body("#4A505A")))),
    ]


# ---------------- build ----------------

HEADER = "## Round 3"


def build():
    lines = []
    for vid, fname, sym, desc, fn in R3:
        fill, groups = fn()
        d = os.path.join(OUT, f"{fname}.icon")
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
        lines.append(f"- **{vid} {fname[4:]}** ({sym}): {desc}")
    rp = os.path.join(OUT, "README.md")
    text = open(rp).read()
    if HEADER in text:
        text = text[:text.index(HEADER)].rstrip() + "\n"
    text += "\n" + HEADER + "\n\n" + "\n".join(lines) + "\n"
    open(rp, "w").write(text)
    print(len(R3), "round-3 variants")


if __name__ == "__main__":
    build()
