# Final icon candidates

**Selected application icon: final-a.** `Resources/AppIcon.icon` is a copy of `v25b3-final-a.icon`. These are editable Icon Composer documents and verified comparison renders.

**Recommendation: final-e.** It retains the strong two-arc design, with more clearance around the tilted phone than final-d. Final-d is the heavier alternative. Final-f is the clearest conventional Wi-Fi symbol. Among a–c, final-b has the softest outer arc; final-a is stronger, and final-c leaves more space above the phone.

## Verification

All six candidates were rendered successfully with Icon Composer `ictool` (Default and Dark) and Xcode `actool` (macOS, deployment target 27.0). All four SVG layers in each candidate use the tile clip path.

The 80px (d) and 88px (e) gaps below refer to the vertical gap at the arc centre, in the 1024px source. The minimum geometric clearance to the tilted phone is approximately 8px for d and 17px for e. These are not uniform gaps along the full curve.

- `contact-final.png`: source references and a–c, Default and actool.
- `contact-final-2.png`: original 25b3-11 and d–f, Default and actool.
- `renders/`: individual Default, Dark, and actool images.

To regenerate a–f: `python3 Design/IconVariants/_scripts/gen5.py`.
To verify and regenerate the contact sheets: `bash Design/IconVariants/_scripts/render5.sh`.
Requires macOS and Xcode with Icon Composer. Earlier generator modules are retained as shared geometry dependencies; use only the final entry points above.

## Final

All layers are clipped to the macOS tile outline (traced from an ictool render), so frame-breaking arcs stay inside the rounded corners in actool output too.

- **25b3-final-a final-a** (asymmetric): Straight combination: 25b3-13's gap and frame-breaking outer arc with 25b3-12's fade (thinner and fainter outward), clipped to the tile.
- **25b3-final-b final-b** (asymmetric): As final-a with a stronger fade, so the outer frame-breaking arc is very soft.
- **25b3-final-c final-c** (asymmetric): As final-a with the arcs moved up for a larger gap above the phone.
- **25b3-final-d final-d** (asymmetric): 25b3-11 (two bold arcs) with arcs 22% thinner and moved up: the gap from phone top to inner arc equals the gap between the arcs (80px).
- **25b3-final-e final-e** (asymmetric): As final-d, arcs 30% thinner than 25b3-11 and a touch higher, with even 88px gaps.
- **25b3-final-f final-f** (asymmetric): Another way: a full two-arc Wi-Fi mark with a dot floating above the phone, with equal spacing dot to arc to arc and from the dot to the phone.
