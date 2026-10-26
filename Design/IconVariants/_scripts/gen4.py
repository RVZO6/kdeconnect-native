#!/usr/bin/env python3
"""Round 4: arc variations of 25b-3 (v25b-r3-glass-wifi-behind). Phone, chat, colours unchanged."""
import json, os, shutil, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen import OUT, WHITE, svg, arc, stroke, circle, Phone, bg, layer, group
from gen3 import chat

# (id, slug, desc, arc parameters)
# keys: c=(x,y) centre, radii, a=(a0,a1) degrees (-90 = straight up), sw (int or list),
#       rot = rotation of the whole mark around its centre, op = per-arc opacity, dot = dot radius
R4 = [
    ("25b3-1", "frame-break-large",
     "Three wide arcs at a large scale; the outer one runs out of the top and both sides of the tile.",
     dict(c=(530, 560), radii=(300, 460, 620), a=(-138, -42), sw=62)),
    ("25b3-2", "frame-break-medium",
     "Two arcs as in 25b-3 but scaled up so the outer arc just breaks the top edge.",
     dict(c=(530, 560), radii=(360, 560), a=(-138, -42), sw=64)),
    ("25b3-3", "wide-sweep-out",
     "Arcs sweep wider (40 degrees more) so their ends run out of the left and right edges.",
     dict(c=(530, 620), radii=(330, 520), a=(-165, -15), sw=60)),
    ("25b3-4", "gap-above",
     "Arc centre moved up so there is a clear gap between the phone top and the first arc; both arcs fully above the phone.",
     dict(c=(530, 470), radii=(220, 340), a=(-135, -45), sw=58)),
    ("25b3-5", "floating-wifi-dot",
     "A complete upright Wi-Fi mark (dot plus three arcs) floats above the phone with a clear gap.",
     dict(c=(510, 320), radii=(90, 160, 230), a=(-135, -45), sw=44, dot=40)),
    ("25b3-6", "wrap-behind",
     "Arc centre set low, inside the phone, so the arcs wrap around behind it and the phone hides their lower ends.",
     dict(c=(530, 720), radii=(390, 540), a=(-145, -35), sw=62)),
    ("25b3-7", "wrap-behind-out",
     "Low centre like 25b3-6 with three arcs; the outer one also runs out of the top and sides.",
     dict(c=(530, 720), radii=(380, 520, 660), a=(-145, -35), sw=60)),
    ("25b3-8", "tilt-follow",
     "25b-3 arcs rotated 6 degrees to follow the phone's tilt.",
     dict(c=(530, 560), radii=(290, 420), a=(-138, -42), sw=60, rot=-6)),
    ("25b3-9", "tilt-follow-out",
     "Tilted with the phone, three arcs scaled up; the outer arc leaves the tile at the top.",
     dict(c=(540, 620), radii=(330, 470, 610), a=(-140, -40), sw=60, rot=-6)),
    ("25b3-10", "three-thin",
     "Three thinner arcs at 25b-3's position, a lighter and more technical feel.",
     dict(c=(530, 560), radii=(270, 370, 470), a=(-136, -44), sw=40)),
    ("25b3-11", "two-bold",
     "Two very thick arcs, the outer one touching the top edge; the heaviest, most graphic take.",
     dict(c=(530, 580), radii=(300, 455), a=(-138, -42), sw=92)),
    ("25b3-12", "graded-out",
     "Three arcs that fade and thin outward; the faint outer arc runs out of the tile.",
     dict(c=(530, 580), radii=(300, 440, 580), a=(-140, -40), sw=[66, 54, 42], op=[1.0, 0.75, 0.5])),
    ("25b3-13", "gap-out",
     "Combination: a gap above the phone, and a large outer arc that breaks the top and sides.",
     dict(c=(530, 470), radii=(230, 380, 530), a=(-138, -42), sw=56)),
]


def arcs_svg(c, radii, a, sw, rot=0, op=None, dot=None):
    sws = sw if isinstance(sw, list) else [sw] * len(radii)
    ops = op or [1.0] * len(radii)
    s = ""
    for r, w, o in zip(radii, sws, ops):
        extra = f'opacity="{o}"' if o < 1 else ""
        s += stroke(arc(c[0], c[1], r, *a), WHITE, w, extra)
    if dot:
        s += circle(c[0], c[1], dot, WHITE)
    if rot:
        s = f'<g transform="rotate({rot} {c[0]} {c[1]})">{s}</g>'
    return s


def make(params):
    p = Phone(cx=540, cy=900, w=600, h=1000, r=132, a=-6, top=124, bottom=94, side=44, sr=42)
    x, y, w, h = p.screen_rect()
    return bg("#2A9DF0"), [
        group(layer("chat", svg(p.on(chat(x, y + 46, w, rows=3)))), sop=0.15),
        group(layer("screen", svg(p.screen()), glass=False, dark_fill="#2D3033"),
              layer("body", svg(p.body()))),
        group(layer("arcs", svg(arcs_svg(**params))), sop=0.25, trans=0.35),
    ]


HEADER = "## Round 4"


def build():
    lines, order = [], []
    for vid, slug, desc, params in R4:
        name = f"v25b3-r4-{slug}"
        fill, groups = make(params)
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
        lines.append(f"- **{vid} r4-{slug}** (asymmetric): {desc}")
        order.append(name)
    rp = os.path.join(OUT, "README.md")
    text = open(rp).read()
    if HEADER in text:
        text = text[:text.index(HEADER)].rstrip() + "\n"
    text += ("\n" + HEADER + "\n\nVariations of 25b-3 (v25b-r3-glass-wifi-behind); only the glass Wi-Fi arcs change.\n\n"
             + "\n".join(lines) + "\n")
    open(rp, "w").write(text)
    with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "r4-order.txt"), "w") as f:
        f.write("\n".join(order) + "\n")
    print(len(R4), "round-4 variants")


if __name__ == "__main__":
    build()
