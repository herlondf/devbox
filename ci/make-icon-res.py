"""Gera src/Devbox.Icon.res (MAINICON) a partir de assets/devbox.ico.

O brcc32 não aceita a entrada PNG de 256 px do .ico. Rodar de novo só quando o ícone mudar:
    python ci/make-icon-res.py
"""
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RT_ICON, RT_GROUP_ICON = 3, 14
LANG = 0x0409
FLAGS = 0x1030  # MOVEABLE | PURE | DISCARDABLE


def name_or_id(v):
    if isinstance(v, int):
        return struct.pack('<HH', 0xFFFF, v)
    return (v + '\0').encode('utf-16-le')


def entry(rtype, name, data):
    hdr = name_or_id(rtype) + name_or_id(name)
    hdr += b'\0' * ((4 - (8 + len(hdr)) % 4) % 4)
    hdr += struct.pack('<IHHII', 0, FLAGS, LANG, 0, 0)
    head = struct.pack('<II', len(data), 8 + len(hdr)) + hdr
    return head + data + b'\0' * ((4 - len(data) % 4) % 4)


ico = (ROOT / 'assets' / 'devbox.ico').read_bytes()
_, _, count = struct.unpack_from('<HHH', ico, 0)
out = struct.pack('<II', 0, 32) + name_or_id(0) + name_or_id(0) + bytes(16)  # marca de .res 32 bits
group = struct.pack('<HHH', 0, 1, count)
for i in range(count):
    w, h, colors, _, planes, bpp, size, offset = struct.unpack_from('<BBBBHHII', ico, 6 + 16 * i)
    out += entry(RT_ICON, i + 1, ico[offset:offset + size])
    group += struct.pack('<BBBBHHIH', w, h, colors, 0, planes, bpp, size, i + 1)
out += entry(RT_GROUP_ICON, 'MAINICON', group)
(ROOT / 'src' / 'Devbox.Icon.res').write_bytes(out)
print('ok', count, 'tamanhos')
