"""
UTF-64 — Universal Transformation Format 64
Specification v0.1 — Python Reference Implementation
"""

# ─── Constants ────────────────────────────────────────────────────────────────

MAGIC    = b"&-9EX"
BOM_CP   = 0x0002

TIER0_CHARS = [' ', 'e', 't', 'a', 'o', 'i', 'n', 's', 'h', 'r', 'l', '\n']
TIER0_MAP   = {c: i for i, c in enumerate(TIER0_CHARS)}

ESC_CAP    = 0xC
ESC_TIER1  = 0xD
ESC_TIER23 = 0xE
ESC_TIER4  = 0xF
CTRL_CAP   = 0x0

# ─── Encoder ──────────────────────────────────────────────────────────────────

def _encode_tier3(cp: int, nib: list) -> None:
    nib += [ESC_TIER23, 0x8]
    for shift in range(24, -1, -4):
        nib.append((cp >> shift) & 0xF)

def _encode_cp(cp: int, nib: list) -> None:
    char  = chr(cp)
    lower = char.lower()
    is_upper = char != lower
    t0l = TIER0_MAP.get(lower, -1)

    # Uppercase whose lowercase is Tier0
    if is_upper and t0l >= 0:
        nib += [ESC_CAP, CTRL_CAP, t0l]
        return

    # Tier 0 direct
    t0 = TIER0_MAP.get(char, -1)
    if t0 >= 0:
        nib.append(t0)
        return

    # Tier 1: 0x00–0xFF
    if cp <= 0xFF:
        nib += [ESC_TIER1, (cp >> 4) & 0xF, cp & 0xF]
        return

    # Tier 2: 0x100–0xFFFF (n3 <= 7)
    if cp <= 0xFFFF:
        n3 = (cp >> 12) & 0xF
        if n3 <= 0x7:
            nib += [ESC_TIER23, n3, (cp >> 8) & 0xF, (cp >> 4) & 0xF, cp & 0xF]
        else:
            _encode_tier3(cp, nib)
        return

    # Tier 3: 0x10000–0xFFFFFFFF
    if cp <= 0xFFFFFFFF:
        _encode_tier3(cp, nib)
        return

    # Tier 4: > 0xFFFFFFFF (up to 60-bit)
    nib.append(ESC_TIER4)
    for shift in range(56, -1, -4):
        nib.append((cp >> shift) & 0xF)

def encode(s: str) -> bytes:
    nib = []

    # BOM
    nib += [ESC_TIER1, 0x0, 0x2]

    for cp in (ord(c) for c in s):
        _encode_cp(cp, nib)

    # Pad to even
    if len(nib) % 2:
        nib.append(0x0)

    # Pack nibbles → bytes
    payload = bytes(
        ((nib[i] & 0xF) << 4) | (nib[i+1] & 0xF)
        for i in range(0, len(nib), 2)
    )

    return MAGIC + payload

# ─── Decoder ──────────────────────────────────────────────────────────────────

def decode(buf: bytes) -> str:
    # Strip magic
    byte_offset = len(MAGIC) if buf[:len(MAGIC)] == MAGIC else 0

    # Unpack bytes → nibbles
    nib = []
    for b in buf[byte_offset:]:
        nib.append((b >> 4) & 0xF)
        nib.append(b & 0xF)

    result   = []
    i        = 0
    cap_next = False

    # Skip BOM
    if len(nib) >= 3 and nib[0] == ESC_TIER1 and nib[1] == 0x0 and nib[2] == 0x2:
        i = 3

    while i < len(nib):
        # Trailing pad
        if i == len(nib) - 1 and nib[i] == 0x0:
            break

        n = nib[i]

        if n <= 0xB:
            c = TIER0_CHARS[n]
            if cap_next:
                c = c.upper()
                cap_next = False
            result.append(c)
            i += 1
            continue

        if n == ESC_CAP:
            ctrl = nib[i+1] & 0x3
            if ctrl == CTRL_CAP:
                cap_next = True
            i += 2
            continue

        if n == ESC_TIER1:
            if i + 2 >= len(nib):
                result.append('\uFFFD'); i += 1; continue
            cp = (nib[i+1] << 4) | nib[i+2]
            c  = chr(cp)
            if cap_next:
                c = c.upper()
                cap_next = False
            result.append(c)
            i += 3
            continue

        if n == ESC_TIER23:
            if i + 1 >= len(nib):
                result.append('\uFFFD'); i += 1; continue
            if nib[i+1] <= 0x7:
                if i + 4 >= len(nib):
                    result.append('\uFFFD'); i += 1; continue
                cp = (nib[i+1] << 12) | (nib[i+2] << 8) | (nib[i+3] << 4) | nib[i+4]
                c  = chr(cp)
                if cap_next:
                    c = c.upper()
                    cap_next = False
                result.append(c)
                i += 5
            else:
                if i + 8 >= len(nib):
                    result.append('\uFFFD'); i += 1; continue
                cp = (nib[i+2] << 24) | (nib[i+3] << 20) | (nib[i+4] << 16) | \
                     (nib[i+5] << 12) | (nib[i+6] << 8)  | (nib[i+7] << 4)  | nib[i+8]
                result.append(chr(cp))
                i += 9
            continue

        if n == ESC_TIER4:
            if i + 15 >= len(nib):
                result.append('\uFFFD'); i += 1; continue
            cp = 0
            for j in range(1, 16):
                cp = (cp << 4) | nib[i+j]
            result.append(chr(cp))
            i += 16
            continue

        result.append('\uFFFD')
        i += 1

    return ''.join(result)

# ─── Utilities ────────────────────────────────────────────────────────────────

def encode_to_hex(s: str) -> str:
    return ' '.join(f'{b:02x}' for b in encode(s))

def payload_byte_size(s: str) -> int:
    nib = []
    for cp in (ord(c) for c in s):
        _encode_cp(cp, nib)
    if len(nib) % 2:
        nib.append(0)
    return len(nib) // 2

# ─── Test Suite ───────────────────────────────────────────────────────────────

def run_tests():
    tests = [
        ('hello',             'lowercase hello'),
        ('Hello',             'capitalized Hello'),
        ('',                  'empty string'),
        ('the rain in spain', 'tier0-heavy sentence'),
        ('Hello, World!',     'mixed ascii'),
        ('Héllo',             'accented char (Tier2)'),
        ('日本語',             'Japanese (Tier2)'),
    ]

    print('UTF-64 Python Test Suite')
    print('=' * 40)
    for inp, desc in tests:
        enc  = encode(inp)
        dec  = decode(enc)
        ok   = dec == inp
        hex_ = ' '.join(f'{b:02x}' for b in enc)
        print(f'[{"PASS" if ok else "FAIL"}] {desc}')
        if not ok:
            print(f'  expected: {inp!r}')
            print(f'  got:      {dec!r}')
        else:
            print(f'  {inp!r} → {payload_byte_size(inp)} payload bytes')
        print(f'  hex: {hex_}')
        print()

if __name__ == '__main__':
    run_tests()
