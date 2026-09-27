#!/usr/bin/env python3
"""Kodhane PWA ikonlarını bağımlılıksız üretir (icon.svg ile aynı tasarım).

Çıktılar: icon-192.png, icon-512.png, apple-touch-icon.png (180x180).
Kullanım: python3 tools/make_icons.py [hedef_klasör]
"""
import math
import os
import struct
import sys
import zlib

C1 = (0x7C, 0x5C, 0xFF)
C2 = (0x22, 0xD3, 0xA6)
SEGS = [((.36, .34), (.22, .5)), ((.22, .5), (.36, .66)),
        ((.64, .34), (.78, .5)), ((.78, .5), (.64, .66)),
        ((.56, .30), (.44, .70))]
HALF_W = .065 / 2


def seg_dist(px, py, a, b):
    ax, ay = a
    dx, dy = b[0] - ax, b[1] - ay
    t = ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)
    t = 0.0 if t < 0 else (1.0 if t > 1 else t)
    return math.hypot(px - ax - t * dx, py - ay - t * dy)


def render(n):
    rows = []
    for y in range(n):
        v = (y + .5) / n
        row = bytearray(b'\x00')
        for x in range(n):
            u = (x + .5) / n
            t = (u + v) / 2
            r, g, b = (C1[i] + (C2[i] - C1[i]) * t for i in range(3))
            if .15 < u < .85 and .25 < v < .75:
                d = min(seg_dist(u, v, s[0], s[1]) for s in SEGS)
                cov = (HALF_W - d) * n + .5
                cov = 0.0 if cov < 0 else (1.0 if cov > 1 else cov)
                r, g, b = r + (255 - r) * cov, g + (255 - g) * cov, b + (255 - b) * cov
            row += bytes((int(r + .5), int(g + .5), int(b + .5)))
        rows.append(bytes(row))

    def chunk(tag, data):
        return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag + data) & 0xFFFFFFFF)

    return (b'\x89PNG\r\n\x1a\n'
            + chunk(b'IHDR', struct.pack('>IIBBBBB', n, n, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(b''.join(rows), 9))
            + chunk(b'IEND', b''))


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
    for name, size in (('icon-192.png', 192), ('icon-512.png', 512), ('apple-touch-icon.png', 180)):
        path = os.path.join(out, name)
        with open(path, 'wb') as f:
            f.write(render(size))
        print('yazıldı:', path, size)


if __name__ == '__main__':
    main()
