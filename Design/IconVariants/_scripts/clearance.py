import math, sys
# phone outline (25b-3 phone), rotated -6 deg about (540, 900)
cx, cy, w, h, r, a = 540, 900, 600, 1000, 132, -6
def rotp(x, y):
    t = math.radians(a); dx, dy = x - cx, y - cy
    return cx + dx*math.cos(t) - dy*math.sin(t), cy + dx*math.sin(t) + dy*math.cos(t)
pts = []
x0, y0 = cx - w/2, cy - h/2
for i in range(0, 201):  # top straight edge
    pts.append(rotp(x0 + r + (w - 2*r)*i/200, y0))
for (ccx, a0, a1) in ((x0 + r, 180, 270), (x0 + w - r, 270, 360)):
    for i in range(0, 91):
        t = math.radians(a0 + (a1 - a0)*i/90)
        pts.append(rotp(ccx + r*math.cos(t), y0 + r + r*math.sin(t)))
for i in range(0, 300):  # sides
    pts.append(rotp(x0, y0 + r + i*2)); pts.append(rotp(x0 + w, y0 + r + i*2))
def clearance(c, rad, a0, a1, sw):
    best = 1e9
    for k in range(0, 201):
        t = math.radians(a0 + (a1 - a0)*k/200)
        px, py = c[0] + rad*math.cos(t), c[1] + rad*math.sin(t)
        for qx, qy in pts:
            best = min(best, math.hypot(px - qx, py - qy))
    return best - sw/2
def top_mid(c):  # phone top y at x = c[0]
    return min(qy for qx, qy in pts if abs(qx - c[0]) < 3)
if __name__ == "__main__":
    c = (float(sys.argv[1]), float(sys.argv[2])); rad = float(sys.argv[3]); a0, a1 = float(sys.argv[4]), float(sys.argv[5]); sw = float(sys.argv[6])
    print("clearance", round(clearance(c, rad, a0, a1, sw), 1), "mid gap", round(top_mid(c) - (c[1] - rad + sw/2), 1), "phone top at x", round(top_mid(c), 1))
