"""Generate CutMaster's addon icon: a faceted brilliant-cut gem, 64x64 32-bit TGA."""
import math, struct, sys

SIZE = 64
SS = 4                      # supersample factor
N = SIZE * SS
CX = CY = N / 2.0

def hexagon(radius, rot=math.pi / 2):
    """Pointy-top hexagon vertices."""
    return [
        (CX + radius * math.cos(rot + i * math.pi / 3),
         CY - radius * math.sin(rot + i * math.pi / 3))
        for i in range(6)
    ]

def inside(poly, x, y):
    hit = False
    j = len(poly) - 1
    for i in range(len(poly)):
        xi, yi = poly[i]
        xj, yj = poly[j]
        if (yi > y) != (yj > y):
            if x < (xj - xi) * (y - yi) / (yj - yi) + xi:
                hit = not hit
        j = i
    return hit

R_OUT = N * 0.46            # gem silhouette
R_RIM = N * 0.43            # inside the dark rim
R_TAB = N * 0.20            # flat top facet (table)

outer = hexagon(R_OUT)
rim = hexagon(R_RIM)
table = hexagon(R_TAB)

# Crown facets: quads from each rim edge in to the matching table edge.
facets = []
for i in range(6):
    a, b = rim[i], rim[(i + 1) % 6]
    c, d = table[(i + 1) % 6], table[i]
    facets.append([a, b, c, d])

# Ruby palette, lit from the upper left. Index 0 is the upper-left facet.
FACET_COLORS = [
    (238, 108, 132),
    (206, 58,  86),
    (150, 26,  50),
    (110, 16,  36),
    (168, 32,  58),
    (214, 74, 102),
]
TABLE_COLOR = (246, 150, 168)
TABLE_EDGE  = (196,  52,  82)
RIM_COLOR   = ( 58,  10,  22)

SEAM_COLOR = (86, 14, 32)
SEAM_W = N * 0.012

def near_segment(x, y, a, b, w):
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    L2 = dx * dx + dy * dy
    if L2 == 0:
        return False
    t = max(0.0, min(1.0, ((x - ax) * dx + (y - ay) * dy) / L2))
    px, py = ax + t * dx, ay + t * dy
    return math.hypot(x - px, y - py) <= w

# Seams: six spokes from the table corners out to the rim corners, plus the
# table outline itself. These are what make it read as cut rather than domed.
seams = [(table[i], rim[i]) for i in range(6)]
seams += [(table[i], table[(i + 1) % 6]) for i in range(6)]

SPARK = (CX - R_OUT * 0.42, CY - R_OUT * 0.46)
SPARK_R = N * 0.085

def facet_color(i):
    return FACET_COLORS[i % 6]

# Accumulate supersampled RGBA.
acc = [[0, 0, 0, 0] for _ in range(SIZE * SIZE)]

for py in range(N):
    y = py + 0.5
    for px in range(N):
        x = px + 0.5
        r = g = b = a = 0
        if inside(outer, x, y):
            if not inside(rim, x, y):
                r, g, b = RIM_COLOR
                a = 255
            elif inside(table, x, y):
                # Flat table with a gentle top-to-bottom fall-off, hard edged.
                t = min(1.0, max(0.0, (y - (CY - R_TAB)) / (2 * R_TAB)))
                r = int(TABLE_COLOR[0] * (1 - t) + TABLE_EDGE[0] * t)
                g = int(TABLE_COLOR[1] * (1 - t) + TABLE_EDGE[1] * t)
                b = int(TABLE_COLOR[2] * (1 - t) + TABLE_EDGE[2] * t)
                a = 255
            else:
                for i, quad in enumerate(facets):
                    if inside(quad, x, y):
                        r, g, b = facet_color(i)
                        a = 255
                        break
                else:
                    r, g, b = FACET_COLORS[1]
                    a = 255

            if a and inside(rim, x, y):
                for s in seams:
                    if near_segment(x, y, s[0], s[1], SEAM_W):
                        r, g, b = SEAM_COLOR
                        break
                # Soft specular glint, blended rather than stamped on.
                sd = math.hypot(x - SPARK[0], y - SPARK[1]) / SPARK_R
                if sd < 1.0:
                    k = (1.0 - sd) ** 1.6 * 0.85
                    r = int(r + (255 - r) * k)
                    g = int(g + (255 - g) * k)
                    b = int(b + (255 - b) * k)

        cell = acc[(py // SS) * SIZE + (px // SS)]
        cell[0] += r; cell[1] += g; cell[2] += b; cell[3] += a

# Downsample and pack as BGRA.
samples = SS * SS
pixels = bytearray()
for cell in acc:
    a = cell[3] // samples
    if a == 0:
        pixels += b"\x00\x00\x00\x00"
        continue
    # Un-weight colour by coverage so edges do not darken toward black.
    cov = cell[3] / 255.0
    r = min(255, int(cell[0] / cov))
    g = min(255, int(cell[1] / cov))
    b = min(255, int(cell[2] / cov))
    pixels += bytes((b, g, r, a))

# Uncompressed 32-bit true-colour TGA, top-left origin.
header = struct.pack(
    "<BBBHHBHHHHBB",
    0,      # id length
    0,      # no colour map
    2,      # uncompressed true colour
    0, 0, 0,
    0, 0,   # x, y origin
    SIZE, SIZE,
    32,     # bits per pixel
    0x28,   # 8-bit alpha, top-down row order
)

out = sys.argv[1]
with open(out, "wb") as f:
    f.write(header)
    f.write(pixels)

print(f"wrote {out}: {SIZE}x{SIZE}, {len(header) + len(pixels)} bytes")
