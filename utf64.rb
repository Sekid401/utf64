# frozen_string_literal: true
#
# UTF-64 — Universal Transformation Format 64
# Specification v0.2 — Ruby Reference Implementation
#
# Changes from v0.1:
#   - Magic bytes removed from encoder output.
#     Decoder still accepts (and strips) legacy magic-prefixed streams.

# ─── Constants ────────────────────────────────────────────────────────────────

LEGACY_MAGIC = "&-9EX".b.bytes.freeze

TIER0_CHARS = [' ', 'e', 't', 'a', 'o', 'i', 'n', 's', 'h', 'r', 'l', "\n"].freeze
TIER0_MAP   = TIER0_CHARS.each_with_index.to_h.freeze

ESC_CAP    = 0xC
ESC_TIER1  = 0xD
ESC_TIER23 = 0xE
ESC_TIER4  = 0xF
CTRL_CAP   = 0x0

# ─── Encoder ──────────────────────────────────────────────────────────────────

def encode_tier3(cp, nib)
  nib << ESC_TIER23 << 0x8
  24.step(0, -4) { |shift| nib << ((cp >> shift) & 0xF) }
end

def encode_cp(cp, nib)
  char  = cp.chr(Encoding::UTF_8)
  lower = char.downcase
  is_upper = char != lower
  t0l = TIER0_MAP[lower]

  if is_upper && t0l
    nib << ESC_CAP << CTRL_CAP << t0l
    return
  end

  if (t0 = TIER0_MAP[char])
    nib << t0
    return
  end

  if cp <= 0xFF
    nib << ESC_TIER1 << ((cp >> 4) & 0xF) << (cp & 0xF)
    return
  end

  if cp <= 0xFFFF
    n3 = (cp >> 12) & 0xF
    if n3 <= 0x7
      nib << ESC_TIER23 << n3 << ((cp >> 8) & 0xF) << ((cp >> 4) & 0xF) << (cp & 0xF)
    else
      encode_tier3(cp, nib)
    end
    return
  end

  if cp <= 0xFFFFFFFF
    encode_tier3(cp, nib)
    return
  end

  # Tier 4
  nib << ESC_TIER4
  56.step(0, -4) { |shift| nib << ((cp >> shift) & 0xF) }
end

def utf64_encode(s)
  nib = []

  # BOM
  nib << ESC_TIER1 << 0x0 << 0x2

  s.each_codepoint { |cp| encode_cp(cp, nib) }

  nib << 0x0 if nib.length.odd?

  # Pack nibbles → bytes
  nib.each_slice(2).map { |hi, lo| ((hi & 0xF) << 4) | (lo & 0xF) }.pack('C*')
end

# ─── Decoder ──────────────────────────────────────────────────────────────────

def utf64_decode(buf)
  bytes = buf.bytes

  # Strip legacy magic if present
  byte_offset = bytes.first(LEGACY_MAGIC.length) == LEGACY_MAGIC ? LEGACY_MAGIC.length : 0

  # Unpack bytes → nibbles
  nib = bytes[byte_offset..].flat_map { |b| [(b >> 4) & 0xF, b & 0xF] }

  result   = ''.encode(Encoding::UTF_8)
  i        = 0
  cap_next = false
  len      = nib.length

  # Skip BOM
  i = 3 if len >= 3 && nib[0] == ESC_TIER1 && nib[1] == 0x0 && nib[2] == 0x2

  while i < len
    break if i == len - 1 && nib[i] == 0x0

    n = nib[i]

    if n <= 0xB
      c = TIER0_CHARS[n].dup
      if cap_next
        c = c.upcase
        cap_next = false
      end
      result << c
      i += 1
      next
    end

    if n == ESC_CAP
      ctrl = nib[i + 1] & 0x3
      cap_next = true if ctrl == CTRL_CAP
      i += 2
      next
    end

    if n == ESC_TIER1
      if i + 2 >= len
        result << "\uFFFD"
        i += 1
        next
      end
      cp = (nib[i+1] << 4) | nib[i+2]
      c  = cp.chr(Encoding::UTF_8)
      if cap_next
        c = c.upcase
        cap_next = false
      end
      result << c
      i += 3
      next
    end

    if n == ESC_TIER23
      if i + 1 >= len
        result << "\uFFFD"
        i += 1
        next
      end
      if nib[i+1] <= 0x7
        if i + 4 >= len
          result << "\uFFFD"
          i += 1
          next
        end
        cp = (nib[i+1] << 12) | (nib[i+2] << 8) | (nib[i+3] << 4) | nib[i+4]
        c  = cp.chr(Encoding::UTF_8)
        if cap_next
          c = c.upcase
          cap_next = false
        end
        result << c
        i += 5
      else
        if i + 8 >= len
          result << "\uFFFD"
          i += 1
          next
        end
        cp = (nib[i+2] << 24) | (nib[i+3] << 20) | (nib[i+4] << 16) |
             (nib[i+5] << 12) | (nib[i+6] << 8)  | (nib[i+7] << 4)  | nib[i+8]
        result << cp.chr(Encoding::UTF_8)
        i += 9
      end
      next
    end

    if n == ESC_TIER4
      if i + 15 >= len
        result << "\uFFFD"
        i += 1
        next
      end
      cp = (1..15).reduce(0) { |acc, j| (acc << 4) | nib[i + j] }
      result << cp.chr(Encoding::UTF_8)
      i += 16
      next
    end

    result << "\uFFFD"
    i += 1
  end

  result
end

# ─── Utilities ────────────────────────────────────────────────────────────────

def utf64_encode_to_hex(s)
  utf64_encode(s).bytes.map { |b| b.to_s(16).rjust(2, '0') }.join(' ')
end

def utf64_payload_byte_size(s)
  nib = []
  s.each_codepoint { |cp| encode_cp(cp, nib) }
  nib << 0 if nib.length.odd?
  nib.length / 2
end

# ─── Test Suite ───────────────────────────────────────────────────────────────

def run_tests
  tests = [
    ['hello',             'lowercase hello'],
    ['Hello',             'capitalized Hello'],
    ['',                  'empty string'],
    ['the rain in spain', 'tier0-heavy sentence'],
    ['Hello, World!',     'mixed ascii'],
    ['Héllo',             'accented char (Tier2)'],
    ['日本語',             'Japanese (Tier2)'],
  ]

  puts "UTF-64 Ruby Test Suite"
  puts '=' * 40
  tests.each do |input, desc|
    enc  = utf64_encode(input)
    dec  = utf64_decode(enc)
    ok   = dec == input
    hex  = enc.bytes.map { |b| b.to_s(16).rjust(2, '0') }.join(' ')
    puts "[#{ok ? 'PASS' : 'FAIL'}] #{desc}"
    if !ok
      puts "  expected: #{input.inspect}"
      puts "  got:      #{dec.inspect}"
    else
      puts "  #{input.inspect} → #{utf64_payload_byte_size(input)} bytes"
    end
    puts "  hex: #{hex}\n\n"
  end
end

run_tests
