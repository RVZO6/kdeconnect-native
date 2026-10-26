#!/usr/bin/env python3
"""Refined takes (a/b) of the six picked variants. Does not touch the original 30."""
import json, os, shutil, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen import (OUT, KDE, DARK, SLOT, SCREEN, WHITE, srgb, svg, rrect, rot, pt, arc,
                 stroke, circle, Phone, bg, layer, group)

REFINED = []


def variant(num, slug, sym, desc):
    def deco(fn):
        REFINED.append((num, slug, sym, desc, fn))
        return fn
    return deco


def g_wifi(cx, cy, color, s=1.0, sw=32, n=3):
    """Upright Wi-Fi mark centred on (cx, cy): dot at the bottom, arcs opening upward."""
    radii = [80 * s, 150 * s, 220 * s][:n]
    top = radii[-1] + sw * s / 2
    bottom = 36 * s
    dy = cy + (top - bottom) / 2
    out = circle(cx, dy, 36 * s, color)
    for r in radii:
        out += stroke(arc(cx, dy, r, -135, -45), color, sw * s)
    return out


def laptop(x, y, w, h, lid, display, base, bezel=24, r=36, bf=1.1, disp_fill=None):
    s = f'<path fill="{lid}" d="{rrect(x, y, w, h, r)}"/>'
    s += f'<path fill="{disp_fill or display}" d="{rrect(x+bezel, y+bezel, w-2*bezel, h-2*bezel, r-bezel+8)}"/>'
    bw = w * bf
    bx = x - (bw - w) / 2
    s += (f'<path fill="{base}" d="M {bx:.1f} {y+h+2:.1f} H {bx+bw:.1f} V {y+h+22:.1f} '
          f'A 24 24 0 0 1 {bx+bw-24:.1f} {y+h+46:.1f} H {bx+24:.1f} A 24 24 0 0 1 {bx:.1f} {y+h+22:.1f} Z"/>')
    return s


# ---------------- v10 ----------------

@variant("10a", "tilt-arcs-right-fit", "asymmetric",
         "v10 scaled up: larger tilted phone with an upright Wi-Fi mark on the screen, glass arcs still leaving its right edge.")
def v10a():
    p = Phone(cx=400, cy=530, w=430, h=760, r=94, a=-10, top=104, bottom=84, side=36, sr=30)
    sx, sy = p.screen_center()
    ac = (640, 450)
    arcs = "".join(stroke(arc(*ac, r, -48, 48), WHITE, 46) for r in (95, 180, 265))
    return bg("#1D99F3"), [
        group(layer("glyph", svg(p.on(g_wifi(sx, sy, KDE, s=0.95, sw=34)))), sop=0.3),
        group(layer("screen", svg(p.screen()), glass=False, dark_fill="#2D3033"),
              layer("body", svg(p.body()))),
        group(layer("arcs", svg(arcs)), sop=0.2, trans=0.3),
    ]


@variant("10b", "tilt-arcs-bold", "asymmetric",
         "Bolder v10: a big phone tilted further, with thick glass arcs behind it that bloom up and to the right and overlap its edge.")
def v10b():
    p = Phone(cx=420, cy=560, w=470, h=820, r=104, a=-14, top=112, bottom=90, side=38, sr=34)
    sx, sy = p.screen_center()
    ac = (560, 470)
    arcs = "".join(stroke(arc(*ac, r, -78, 18), WHITE, 60) for r in (250, 350))
    return bg("#1D99F3"), [
        group(layer("glyph", svg(p.on(g_wifi(sx, sy, KDE, s=1.05, sw=36)))), sop=0.3),
        group(layer("screen", svg(p.screen()), glass=False, dark_fill="#2D3033"),
              layer("body", svg(p.body()))),
        group(layer("arcs", svg(arcs)), sop=0.25, trans=0.4),
    ]


# ---------------- v13 ----------------

@variant("13a", "macbook-behind-fit", "asymmetric",
         "v13 scaled up: bigger translucent MacBook behind, larger phone in front at the right with an upright Wi-Fi mark.")
def v13a():
    lap = laptop(90, 250, 640, 430, "#E8EDF2", "#9CCBF5", "#D3DAE2", bf=1.08)
    p = Phone(cx=735, cy=580, w=330, h=620, r=74, top=80, bottom=64, side=26, sr=22)
    sx, sy = p.screen_center()
    return bg("#1D99F3"), [
        group(layer("glyph", svg(g_wifi(sx, sy, KDE, s=0.78, sw=38)))),
        group(layer("screen", svg(p.screen()), glass=False, dark_fill="#2D3033"),
              layer("body", svg(p.body()))),
        group(layer("laptop", svg(lap)), sop=0.3, trans=0.35),
    ]


@variant("13b", "macbook-frame-break", "asymmetric",
         "Bolder v13: a large MacBook runs off the left edge, a big slightly tilted phone overlaps it; Wi-Fi mark on the phone.")
def v13b():
    grad = ('<linearGradient id="d" x1="0" y1="0" x2="1" y2="1">'
            '<stop offset="0" stop-color="#BFE2FF"/><stop offset="1" stop-color="#5DB3F5"/></linearGradient>')
    lap = laptop(-90, 250, 740, 470, "#EEF2F6", None, "#D3DAE2", bf=1.06, disp_fill="url(#d)")
    p = Phone(cx=700, cy=560, w=380, h=700, r=84, a=6, top=90, bottom=70, side=30, sr=26)
    sx, sy = p.screen_center()
    return bg("#1A86E0"), [
        group(layer("glyph", svg(p.on(g_wifi(sx, sy, KDE, s=0.9, sw=36))))),
        group(layer("screen", svg(p.screen()), glass=False, dark_fill="#2D3033"),
              layer("body", svg(p.body())), sop=0.55),
        group(layer("laptop", svg(lap, grad)), sop=0.3, trans=0.3),
    ]


# ---------------- v15 ----------------

@variant("15a", "two-phones-fanned-fit", "asymmetric",
         "v15 scaled up: two larger phones fanned like cards on teal, upright Wi-Fi mark on the front screen.")
def v15a():
    back = Phone(cx=405, cy=500, w=410, h=730, r=94, a=-14)
    p = Phone(cx=605, cy=540, w=410, h=730, r=94, a=7, top=100, bottom=80, side=34, sr=28)
    sx, sy = p.screen_center()
    return bg("#14A9A0", dark="#0B3F3C"), [
        group(layer("glyph", svg(p.on(g_wifi(sx, sy, "#14A9A0", s=0.92, sw=36))))),
        group(layer("screen", svg(p.screen("#ECF6F5")), glass=False, dark_fill="#22302F"),
              layer("body", svg(p.body("#263233", "#121919")))),
        group(layer("back", svg(back.body("#FFFFFF", "#FFFFFF"))), sop=0.25, trans=0.55),
    ]


@variant("15b", "fanned-teal-screen", "asymmetric",
         "Bolder v15: wider fan, the back phone frosted glass, the front phone with a teal screen and a big white Wi-Fi mark, on a teal-to-deep-green tile.")
def v15b():
    back = Phone(cx=380, cy=490, w=420, h=740, r=96, a=-20)
    p = Phone(cx=615, cy=545, w=430, h=760, r=98, a=9, top=104, bottom=82, side=34, sr=30)
    sx, sy = p.screen_center()
    grad = ('<linearGradient id="s" x1="0" y1="0" x2="0" y2="1">'
            '<stop offset="0" stop-color="#3FD3C6"/><stop offset="1" stop-color="#0E8C84"/></linearGradient>')
    return bg("#0F8F88", dark="#0A3532"), [
        group(layer("glyph", svg(p.on(g_wifi(sx, sy, WHITE, s=1.0, sw=38)))), sop=0.25),
        group(layer("screen", svg(p.screen(fill="url(#s)"), grad), glass=False),
              layer("body", svg(p.body("#1F2A2B", "#0B1111")))),
        group(layer("back", svg(back.body("#FFFFFF", "#FFFFFF"))), sop=0.3, trans=0.5),
    ]


# ---------------- v20 ----------------

@variant("20a", "notification-pop-fit", "asymmetric",
         "v20 scaled up: larger phone with a white glass notification bubble over its right edge; small upright Wi-Fi mark low on the screen.")
def v20a():
    p = Phone(cx=395, cy=575, w=430, h=740, r=96, top=104, bottom=84, side=36, sr=30)
    bub = f'<path fill="#FFFFFF" d="{rrect(455, 190, 480, 190, 95)}"/>'
    bub += '<path fill="#FFFFFF" d="M 560 372 L 515 440 L 625 376 Z"/>'
    icon = circle(550, 285, 50, KDE) + stroke("M 630 255 H 860 M 630 315 H 780", "#9DB0C4", 30)
    sx, sy = p.screen_center()
    return bg("#1D99F3"), [
        group(layer("bubble-content", svg(icon), glass=False),
              layer("bubble", svg(bub)), sop=0.45),
        group(layer("glyph", svg(g_wifi(sx, sy + 120, KDE, s=0.7, sw=40)))),
        group(layer("screen", svg(p.screen()), glass=False, dark_fill="#2D3033"),
              layer("body", svg(p.body()))),
    ]


@variant("20b", "notification-cascade", "asymmetric",
         "Bolder v20: a tilted phone with two glass notification bubbles cascading out to the right at different depths.")
def v20b():
    p = Phone(cx=370, cy=580, w=420, h=740, r=94, a=-8, top=102, bottom=82, side=34, sr=30)
    sx, sy = p.screen_center()
    b1 = f'<path fill="#FFFFFF" d="{rrect(440, 170, 500, 180, 90)}"/>'
    c1 = circle(530, 260, 50, KDE) + stroke("M 610 230 H 870 M 610 290 H 790", "#9DB0C4", 30)
    b2 = f'<path fill="#FFFFFF" d="{rrect(540, 420, 400, 150, 75)}"/>'
    c2 = circle(615, 495, 40, "#F67400") + stroke("M 680 470 H 880 M 680 520 H 820", "#9DB0C4", 26)
    return bg("#1D99F3"), [
        group(layer("c1", svg(c1), glass=False), layer("b1", svg(b1)), sop=0.45),
        group(layer("c2", svg(c2), glass=False), layer("b2", svg(b2)), sop=0.35, trans=0.25),
        group(layer("glyph", svg(p.on(g_wifi(sx, sy + 130, KDE, s=0.7, sw=40))))),
        group(layer("screen", svg(p.screen()), glass=False, dark_fill="#2D3033"),
              layer("body", svg(p.body()))),
    ]


# ---------------- v25 ----------------

@variant("25a", "peek-from-bottom-fit", "asymmetric",
         "v25 scaled up: a wider phone rises from the bottom edge off-centre, larger signal arcs bloom above it to the right.")
def v25a():
    p = Phone(cx=410, cy=850, w=520, h=860, r=116, top=116, bottom=90, side=40, sr=38)
    ax, ay = 645, 375
    arcs = circle(ax, ay, 52, WHITE) + "".join(
        stroke(arc(ax, ay, r, -125, -5), WHITE, 46) for r in (105, 185, 265))
    return bg("#38B2FF"), [
        group(layer("arcs", svg(arcs)), sop=0.3),
        group(layer("screen", svg(p.screen()), glass=False, dark_fill="#2D3033"),
              layer("body", svg(p.body()))),
    ]


@variant("25b", "peek-big-wifi", "asymmetric",
         "Bolder v25: a very large phone rises from the bottom-right and is cut by the frame; a big upright Wi-Fi mark fills its screen.")
def v25b():
    p = Phone(cx=560, cy=820, w=640, h=1000, r=140, a=-6, top=130, bottom=100, side=48, sr=46)
    gx, gy = 560, 655
    return bg("#38B2FF"), [
        group(layer("glyph", svg(p.on(g_wifi(gx, gy, KDE, s=1.2, sw=40)))), sop=0.3),
        group(layer("screen", svg(p.screen()), glass=False, dark_fill="#2D3033"),
              layer("body", svg(p.body()))),
    ]


# ---------------- v29 ----------------

@variant("29a", "stacked-phones-fit", "asymmetric",
         "v29 scaled up: two larger upright phones offset diagonally on white, KDE-blue glass behind, upright Wi-Fi on the front screen.")
def v29a():
    back = Phone(cx=400, cy=420, w=400, h=680, r=90)
    p = Phone(cx=620, cy=600, w=400, h=680, r=90, top=96, bottom=76, side=32, sr=26)
    sx, sy = p.screen_center()
    return bg("#E8EEF5", kind="solid", dark="#15181C"), [
        group(layer("glyph", svg(g_wifi(sx, sy, KDE, s=0.88, sw=36)))),
        group(layer("screen", svg(p.screen("#F7F9FB")), glass=False, dark_fill="#2D3033"),
              layer("body", svg(p.body("#1E2023", "#000")))),
        group(layer("back", svg(back.body(KDE, "#0E6FB8"))), sop=0.3, trans=0.2),
    ]


@variant("29b", "stacked-phones-tilted", "asymmetric",
         "Bolder v29: the blue glass phone tilts left behind, the dark phone tilts right in front, both larger; white Wi-Fi mark on a KDE-blue screen.")
def v29b():
    back = Phone(cx=390, cy=450, w=420, h=720, r=96, a=-10)
    p = Phone(cx=630, cy=590, w=410, h=700, r=92, a=6, top=98, bottom=78, side=32, sr=26)
    sx, sy = p.screen_center()
    return bg("#E8EEF5", kind="solid", dark="#15181C"), [
        group(layer("glyph", svg(p.on(g_wifi(sx, sy, WHITE, s=0.9, sw=36)))), sop=0.2),
        group(layer("screen", svg(p.screen(KDE)), glass=False),
              layer("body", svg(p.body("#1E2023", "#000")))),
        group(layer("back", svg(back.body("#7CC4FA", "#4FA9EC"))), sop=0.3, trans=0.35),
    ]


# ---------------- build ----------------

HEADER = "## Refined takes of the picks (a = closest with fixes, b = bolder)"


def build():
    lines = []
    for num, slug, sym, desc, fn in REFINED:
        fill, groups = fn()
        d = os.path.join(OUT, f"v{num}-{slug}.icon")
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
        lines.append(f"- **{num} {slug}** ({sym}): {desc}")
    rp = os.path.join(OUT, "README.md")
    text = open(rp).read()
    if HEADER in text:
        text = text[:text.index(HEADER)].rstrip() + "\n"
    text += "\n" + HEADER + "\n\n" + "\n".join(lines) + "\n"
    open(rp, "w").write(text)
    print(len(REFINED), "refined variants")


if __name__ == "__main__":
    build()
