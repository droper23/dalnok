import struct, sys
d = open(sys.argv[1], 'rb').read(); pos = 24
while pos + 36 <= len(d):
    n = struct.unpack_from('<Q', d, pos + 28)[0]; p = pos + 36
    if d[pos:pos+4] == b'UCuA' and n >= 177 and struct.unpack_from('<I', d, p)[0] == 0x1a8:
        ch, order = struct.unpack_from('<I', d, pos + 14)[0], struct.unpack_from('<I', d, pos + 18)[0]
        name = d[p+120:p+132].split(b'\0')[0].decode(); b = d[p+172:p+n]
        if b[12:20] == b'GAMETSPP':
            cnt = struct.unpack_from('<I', b, 8)[0]
            ps = [round(struct.unpack_from('<f', b, 28 + 4*i)[0], 4) for i in range(cnt) if 28 + 4*i + 4 <= len(b)]
            print(f'ch{ch} slot{order} {name} @{p+172+28} n={cnt}', ps)
        else: print(f'ch{ch} slot{order} {name} (no GAMETSPP, {len(b)} bytes)')
    pos = p + n
