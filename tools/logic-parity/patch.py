# patch.py <ProjectData> <channel> <idx=value> ...   — rewrite native-plug-in parameter floats in place
import struct, sys
path, ch = sys.argv[1], int(sys.argv[2]); d = bytearray(open(path, 'rb').read()); pos = 24; hit = False
while pos + 36 <= len(d):
    n = struct.unpack_from('<Q', d, pos + 28)[0]; p = pos + 36
    if d[pos:pos+4] == b'UCuA' and n >= 177 and struct.unpack_from('<I', d, p)[0] == 0x1a8 and struct.unpack_from('<I', d, pos + 14)[0] == ch:
        b = p + 172; assert d[b+12:b+20] == b'GAMETSPP'; cnt = struct.unpack_from('<I', d, b + 8)[0]
        for kv in sys.argv[3:]:
            i, v = kv.split('='); i = int(i); assert i < cnt
            old = struct.unpack_from('<f', d, b + 28 + 4*i)[0]; struct.pack_into('<f', d, b + 28 + 4*i, float(v)); print(f'ch{ch}[{i}] {old} -> {v}')
        hit = True
    pos = p + n
assert hit, 'no native plug-in on that channel'
open(path, 'wb').write(d)
