--[[
UTF-64 — Universal Transformation Format 64
Specification v0.2 — Lua Implementation

Changes from v0.1:
  - Magic bytes removed from encoder output.
    Decoder still accepts (and strips) legacy magic-prefixed streams.
]]

-- ─── Constants ────────────────────────────────────────────────────────────────

local LEGACY_MAGIC = "&-9EX"

local TIER0_CHARS = {' ', 'e', 't', 'a', 'o', 'i', 'n', 's', 'h', 'r', 'l', '\n'}
local TIER0_MAP   = {}
for i, c in ipairs(TIER0_CHARS) do
    TIER0_MAP[c] = i - 1  -- 0-indexed
end

local ESC_CAP    = 0xC
local ESC_TIER1  = 0xD
local ESC_TIER23 = 0xE
local ESC_TIER4  = 0xF
local CTRL_CAP   = 0x0
local BOM_CP     = 0x0002

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function utf8_codepoints(s)
    local codepoints = {}
    local i = 1
    while i <= #s do
        local b = s:byte(i)
        local cp, len
        if b < 0x80 then
            cp, len = b, 1
        elseif b < 0xE0 then
            cp = ((b & 0x1F) << 6) | (s:byte(i+1) & 0x3F)
            len = 2
        elseif b < 0xF0 then
            cp = ((b & 0x0F) << 12) | ((s:byte(i+1) & 0x3F) << 6) | (s:byte(i+2) & 0x3F)
            len = 3
        else
            cp = ((b & 0x07) << 18) | ((s:byte(i+1) & 0x3F) << 12) | ((s:byte(i+2) & 0x3F) << 6) | (s:byte(i+3) & 0x3F)
            len = 4
        end
        codepoints[#codepoints+1] = cp
        i = i + len
    end
    return codepoints
end

local function cp_to_utf8(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 | (cp >> 6), 0x80 | (cp & 0x3F))
    elseif cp < 0x10000 then
        return string.char(0xE0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F))
    else
        return string.char(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3F), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F))
    end
end

local function cp_to_lower_upper(cp)
    local s = cp_to_utf8(cp)
    local lo = s:lower()
    local up = s:upper()
    return lo, up, (s ~= lo)
end

-- ─── Encoder ──────────────────────────────────────────────────────────────────

local function encode_tier3(cp, nib)
    nib[#nib+1] = ESC_TIER23
    nib[#nib+1] = 0x8
    for shift = 24, 0, -4 do
        nib[#nib+1] = (cp >> shift) & 0xF
    end
end

local function encode_cp(cp, nib)
    local char   = cp_to_utf8(cp)
    local lower  = char:lower()
    local is_upper = (char ~= lower) and (char == char:upper())
    local t0l = TIER0_MAP[lower]

    -- Uppercase whose lowercase is Tier0
    if is_upper and t0l then
        nib[#nib+1] = ESC_CAP
        nib[#nib+1] = CTRL_CAP
        nib[#nib+1] = t0l
        return
    end

    -- Tier 0 direct
    local t0 = TIER0_MAP[char]
    if t0 then
        nib[#nib+1] = t0
        return
    end

    -- Tier 1: 0x00–0xFF
    if cp <= 0xFF then
        nib[#nib+1] = ESC_TIER1
        nib[#nib+1] = (cp >> 4) & 0xF
        nib[#nib+1] = cp & 0xF
        return
    end

    -- Tier 2: 0x100–0xFFFF
    if cp <= 0xFFFF then
        local n3 = (cp >> 12) & 0xF
        if n3 <= 0x7 then
            nib[#nib+1] = ESC_TIER23
            nib[#nib+1] = n3
            nib[#nib+1] = (cp >> 8) & 0xF
            nib[#nib+1] = (cp >> 4) & 0xF
            nib[#nib+1] = cp & 0xF
        else
            encode_tier3(cp, nib)
        end
        return
    end

    -- Tier 3: 0x10000–0xFFFFFFFF
    if cp <= 0xFFFFFFFF then
        encode_tier3(cp, nib)
        return
    end

    -- Tier 4: > 0xFFFFFFFF (up to 60-bit)
    nib[#nib+1] = ESC_TIER4
    for shift = 56, 0, -4 do
        nib[#nib+1] = (cp >> shift) & 0xF
    end
end

local function encode(s)
    local nib = {}

    -- BOM
    nib[#nib+1] = ESC_TIER1
    nib[#nib+1] = 0x0
    nib[#nib+1] = 0x2

    local codepoints = utf8_codepoints(s)
    for _, cp in ipairs(codepoints) do
        encode_cp(cp, nib)
    end

    -- Pad to even
    if #nib % 2 == 1 then
        nib[#nib+1] = 0x0
    end

    -- Pack nibbles → bytes
    local bytes = {}
    for i = 1, #nib, 2 do
        bytes[#bytes+1] = string.char(((nib[i] & 0xF) << 4) | (nib[i+1] & 0xF))
    end
    return table.concat(bytes)
end

-- ─── Decoder ──────────────────────────────────────────────────────────────────

local function decode(buf)
    -- Strip legacy magic if present
    local offset = 0
    if buf:sub(1, #LEGACY_MAGIC) == LEGACY_MAGIC then
        offset = #LEGACY_MAGIC
    end

    -- Unpack bytes → nibbles
    local nib = {}
    for i = offset + 1, #buf do
        local b = buf:byte(i)
        nib[#nib+1] = (b >> 4) & 0xF
        nib[#nib+1] = b & 0xF
    end

    local result   = {}
    local i        = 1
    local cap_next = false

    -- Skip BOM
    if #nib >= 3 and nib[1] == ESC_TIER1 and nib[2] == 0x0 and nib[3] == 0x2 then
        i = 4
    end

    while i <= #nib do
        -- Trailing pad
        if i == #nib and nib[i] == 0x0 then
            break
        end

        local n = nib[i]

        if n <= 0xB then
            local c = TIER0_CHARS[n + 1]
            if cap_next then
                c = c:upper()
                cap_next = false
            end
            result[#result+1] = c
            i = i + 1

        elseif n == ESC_CAP then
            local ctrl = nib[i+1] & 0x3
            if ctrl == CTRL_CAP then
                cap_next = true
            end
            i = i + 2

        elseif n == ESC_TIER1 then
            if i + 2 > #nib then
                result[#result+1] = '\xEF\xBF\xBD'; i = i + 1
            else
                local cp = (nib[i+1] << 4) | nib[i+2]
                local c  = cp_to_utf8(cp)
                if cap_next then
                    c = c:upper()
                    cap_next = false
                end
                result[#result+1] = c
                i = i + 3
            end

        elseif n == ESC_TIER23 then
            if i + 1 > #nib then
                result[#result+1] = '\xEF\xBF\xBD'; i = i + 1
            elseif nib[i+1] <= 0x7 then
                if i + 4 > #nib then
                    result[#result+1] = '\xEF\xBF\xBD'; i = i + 1
                else
                    local cp = (nib[i+1] << 12) | (nib[i+2] << 8) | (nib[i+3] << 4) | nib[i+4]
                    local c  = cp_to_utf8(cp)
                    if cap_next then
                        c = c:upper()
                        cap_next = false
                    end
                    result[#result+1] = c
                    i = i + 5
                end
            else
                if i + 8 > #nib then
                    result[#result+1] = '\xEF\xBF\xBD'; i = i + 1
                else
                    local cp = (nib[i+2] << 24) | (nib[i+3] << 20) | (nib[i+4] << 16) |
                               (nib[i+5] << 12) | (nib[i+6] << 8)  | (nib[i+7] << 4)  | nib[i+8]
                    result[#result+1] = cp_to_utf8(cp)
                    i = i + 9
                end
            end

        elseif n == ESC_TIER4 then
            if i + 15 > #nib then
                result[#result+1] = '\xEF\xBF\xBD'; i = i + 1
            else
                local cp = 0
                for j = 1, 15 do
                    cp = (cp << 4) | nib[i+j]
                end
                result[#result+1] = cp_to_utf8(cp)
                i = i + 16
            end

        else
            result[#result+1] = '\xEF\xBF\xBD'
            i = i + 1
        end
    end

    return table.concat(result)
end

-- ─── Utilities ────────────────────────────────────────────────────────────────

local function encode_to_hex(s)
    local parts = {}
    for b in encode(s):gmatch('.') do
        parts[#parts+1] = string.format('%02x', b:byte())
    end
    return table.concat(parts, ' ')
end

local function payload_byte_size(s)
    local nib = {}
    for _, cp in ipairs(utf8_codepoints(s)) do
        encode_cp(cp, nib)
    end
    if #nib % 2 == 1 then nib[#nib+1] = 0 end
    return #nib // 2
end

-- ─── Test Suite ───────────────────────────────────────────────────────────────

local function run_tests()
    local tests = {
        {'hello',             'lowercase hello'},
        {'Hello',             'capitalized Hello'},
        {'',                  'empty string'},
        {'the rain in spain', 'tier0-heavy sentence'},
        {'Hello, World!',     'mixed ascii'},
        {'Héllo',             'accented char (Tier2)'},
        {'日本語',             'Japanese (Tier2)'},
    }

    print('UTF-64 Lua Test Suite')
    print(string.rep('=', 40))
    for _, t in ipairs(tests) do
        local inp, desc = t[1], t[2]
        local enc = encode(inp)
        local dec = decode(enc)
        local ok  = (dec == inp)
        local hex = encode_to_hex(inp)
        print(string.format('[%s] %s', ok and 'PASS' or 'FAIL', desc))
        if not ok then
            print(string.format('  expected: %q', inp))
            print(string.format('  got:      %q', dec))
        else
            print(string.format('  %q → %d bytes', inp, payload_byte_size(inp)))
        end
        print(string.format('  hex: %s', hex))
        print()
    end
end

-- ─── Module export ────────────────────────────────────────────────────────────

local utf64 = {
    encode          = encode,
    decode          = decode,
    encode_to_hex   = encode_to_hex,
    payload_byte_size = payload_byte_size,
}

if arg and arg[0] and arg[0]:match('utf64%.lua$') then
    run_tests()
end

return utf64
