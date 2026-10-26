#!/usr/bin/env python3
"""Final: layout of 25b3-13 (gap-out) + fade of 25b3-12 (graded-out), clipped to the macOS tile."""
import json, os, shutil, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from gen import OUT, svg, Phone, bg, layer, group
from gen3 import chat
from gen4 import arcs_svg

# Tile outline traced from a 1024px ictool render (alpha 0.5 edge, inset 1.5px), see trace.swift.
TILE = open(os.path.join(HERE, "tile-clip.txt")).read().strip()
CLIP_DEF = f'<clipPath id="tile"><path d="{TILE}"/></clipPath>'


def clipped(content):
    return svg(f'<g clip-path="url(#tile)">{content}</g>', CLIP_DEF)


FINALS = [
    ("25b3-final-a", "final-a",
     "Straight combination: 25b3-13's gap and frame-breaking outer arc with 25b3-12's fade (thinner and fainter outward), clipped to the tile.",
     dict(c=(530, 470), radii=(230, 380, 530), a=(-138, -42), sw=[62, 52, 42], op=[1.0, 0.75, 0.5])),
    ("25b3-final-b", "final-b",
     "As final-a with a stronger fade, so the outer frame-breaking arc is very soft.",
     dict(c=(530, 470), radii=(230, 380, 530), a=(-138, -42), sw=[62, 48, 36], op=[1.0, 0.6, 0.3])),
    ("25b3-final-c", "final-c",
     "As final-a with the arcs moved up for a larger gap above the phone.",
     dict(c=(530, 435), radii=(220, 370, 520), a=(-138, -42), sw=[62, 52, 42], op=[1.0, 0.75, 0.5])),
    ("25b3-final-d", "final-d",
     "25b3-11 (two bold arcs) with arcs 22% thinner and moved up: the gap from phone top to inner arc equals the gap between the arcs (80px).",
     dict(c=(530, 542), radii=(260, 412), a=(-130, -50), sw=72)),
    ("25b3-final-e", "final-e",
     "As final-d, arcs 30% thinner than 25b3-11 and a touch higher, with even 88px gaps.",
     dict(c=(530, 528), radii=(250, 402), a=(-130, -50), sw=64)),
    ("25b3-final-f", "final-f",
     "Another way: a full two-arc Wi-Fi mark with a dot floating above the phone, with equal spacing dot to arc to arc and from the dot to the phone.",
     dict(c=(530, 318), radii=(110, 208), a=(-135, -45), sw=56, dot=40)),
]


def make(params):
    p = Phone(cx=540, cy=900, w=600, h=1000, r=132, a=-6, top=124, bottom=94, side=44, sr=42)
    x, y, w, h = p.screen_rect()
    return bg("#2A9DF0"), [
        group(layer("chat", clipped(p.on(chat(x, y + 46, w, rows=3)))), sop=0.15),
        group(layer("screen", clipped(p.screen()), glass=False, dark_fill="#2D3033"),
              layer("body", clipped(p.body()))),
        group(layer("arcs", clipped(arcs_svg(**params))), sop=0.25, trans=0.35),
    ]


HEADER = "## Final"


def build():
    lines = []
    for vid, slug, desc, params in FINALS:
        name = f"v{vid}"
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
        lines.append(f"- **{vid} {slug}** (asymmetric): {desc}")
    rp = os.path.join(OUT, "README.md")
    text = open(rp).read()
    if HEADER in text:
        text = text[:text.index(HEADER)].rstrip() + "\n"
    text += ("\n" + HEADER + "\n\nAll layers are clipped to the macOS tile outline (traced from an ictool render), "
             "so frame-breaking arcs stay inside the rounded corners in actool output too.\n\n"
             + "\n".join(lines) + "\n")
    open(rp, "w").write(text)
    print(len(FINALS), "final variants")


if __name__ == "__main__":
    build()
