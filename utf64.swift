/**
 * UTF-64 — Universal Transformation Format 64
 * Specification v0.2 — Swift Reference Implementation
 *
 * Changes from v0.1:
 *   - Magic bytes removed from encoder output.
 *     Decoder still accepts (and strips) legacy magic-prefixed streams.
 */

import Foundation

// ─── Constants ────────────────────────────────────────────────────────────────

let LEGACY_MAGIC: [UInt8] = Array("&-9EX".utf8)

let TIER0_CHARS: [Character] = [" ", "e", "t", "a", "o", "i", "n", "s", "h", "r", "l", "\n"]
let TIER0_MAP: [Character: Int] = {
    var m: [Character: Int] = [:]
    for (i, c) in TIER0_CHARS.enumerated() { m[c] = i }
    return m
}()

let ESC_CAP:    UInt8 = 0xC
let ESC_TIER1:  UInt8 = 0xD
let ESC_TIER23: UInt8 = 0xE
let ESC_TIER4:  UInt8 = 0xF
let CTRL_CAP:   UInt8 = 0x0

// ─── Encoder ──────────────────────────────────────────────────────────────────

private func encodeTier3(_ cp: UInt32, _ nib: inout [UInt8]) {
    nib.append(ESC_TIER23)
    nib.append(0x8)
    var shift = 24
    while shift >= 0 {
        nib.append(UInt8((cp >> shift) & 0xF))
        shift -= 4
    }
}

private func encodeCP(_ cp: UInt32, _ nib: inout [UInt8]) {
    guard let scalar = Unicode.Scalar(cp) else { return }
    let char    = Character(scalar)
    let lower   = Character(scalar.properties.lowercaseMapping ?? String(scalar))
    let isUpper = char != lower
    let t0l     = TIER0_MAP[lower] ?? -1

    if isUpper && t0l >= 0 {
        nib.append(contentsOf: [ESC_CAP, CTRL_CAP, UInt8(t0l)])
        return
    }

    if let t0 = TIER0_MAP[char] {
        nib.append(UInt8(t0))
        return
    }

    if cp <= 0xFF {
        nib.append(contentsOf: [ESC_TIER1, UInt8((cp >> 4) & 0xF), UInt8(cp & 0xF)])
        return
    }

    if cp <= 0xFFFF {
        let n3 = UInt8((cp >> 12) & 0xF)
        if n3 <= 0x7 {
            nib.append(contentsOf: [
                ESC_TIER23, n3,
                UInt8((cp >> 8) & 0xF),
                UInt8((cp >> 4) & 0xF),
                UInt8(cp & 0xF)
            ])
        } else {
            encodeTier3(cp, &nib)
        }
        return
    }

    if cp <= 0xFFFFFFFF {
        encodeTier3(cp, &nib)
        return
    }

    // Tier 4
    nib.append(ESC_TIER4)
    let cp64 = UInt64(cp)
    var shift = 56
    while shift >= 0 {
        nib.append(UInt8((cp64 >> shift) & 0xF))
        shift -= 4
    }
}

public func utf64Encode(_ s: String) -> [UInt8] {
    var nib: [UInt8] = []

    // BOM
    nib.append(contentsOf: [ESC_TIER1, 0x0, 0x2])

    for scalar in s.unicodeScalars {
        encodeCP(scalar.value, &nib)
    }

    if nib.count % 2 != 0 { nib.append(0x0) }

    // Pack nibbles → bytes
    return stride(from: 0, to: nib.count, by: 2).map {
        ((nib[$0] & 0xF) << 4) | (nib[$0 + 1] & 0xF)
    }
}

// ─── Decoder ──────────────────────────────────────────────────────────────────

public func utf64Decode(_ buf: [UInt8]) -> String {
    // Strip legacy magic if present
    var byteOffset = 0
    if buf.count >= LEGACY_MAGIC.count && Array(buf.prefix(LEGACY_MAGIC.count)) == LEGACY_MAGIC {
        byteOffset = LEGACY_MAGIC.count
    }

    // Unpack bytes → nibbles
    var nib: [UInt8] = []
    for b in buf[byteOffset...] {
        nib.append((b >> 4) & 0xF)
        nib.append(b & 0xF)
    }

    var result  = ""
    var i       = 0
    var capNext = false
    let len     = nib.count

    // Skip BOM
    if len >= 3 && nib[0] == ESC_TIER1 && nib[1] == 0x0 && nib[2] == 0x2 { i = 3 }

    func appendCP(_ cp: UInt32, cap: inout Bool) {
        guard let scalar = Unicode.Scalar(cp) else { result += "\u{FFFD}"; return }
        var ch = Character(scalar)
        if cap {
            let up = ch.uppercased()
            ch = up.first ?? ch
            cap = false
        }
        result.append(ch)
    }

    while i < len {
        if i == len - 1 && nib[i] == 0x0 { break }
        let n = nib[i]

        if n <= 0xB {
            var c = TIER0_CHARS[Int(n)]
            if capNext { c = c.uppercased().first ?? c; capNext = false }
            result.append(c)
            i += 1; continue
        }

        if n == ESC_CAP {
            let ctrl = nib[i + 1] & 0x3
            if ctrl == CTRL_CAP { capNext = true }
            i += 2; continue
        }

        if n == ESC_TIER1 {
            guard i + 2 < len else { result += "\u{FFFD}"; i += 1; continue }
            let cp = (UInt32(nib[i+1]) << 4) | UInt32(nib[i+2])
            appendCP(cp, cap: &capNext)
            i += 3; continue
        }

        if n == ESC_TIER23 {
            guard i + 1 < len else { result += "\u{FFFD}"; i += 1; continue }
            if nib[i+1] <= 0x7 {
                guard i + 4 < len else { result += "\u{FFFD}"; i += 1; continue }
                let cp = (UInt32(nib[i+1]) << 12) | (UInt32(nib[i+2]) << 8)
                       | (UInt32(nib[i+3]) << 4)  |  UInt32(nib[i+4])
                appendCP(cp, cap: &capNext)
                i += 5
            } else {
                guard i + 8 < len else { result += "\u{FFFD}"; i += 1; continue }
                let cp = (UInt32(nib[i+2]) << 24) | (UInt32(nib[i+3]) << 20)
                       | (UInt32(nib[i+4]) << 16) | (UInt32(nib[i+5]) << 12)
                       | (UInt32(nib[i+6]) << 8)  | (UInt32(nib[i+7]) << 4)
                       |  UInt32(nib[i+8])
                appendCP(cp, cap: &capNext)
                i += 9
            }
            continue
        }

        if n == ESC_TIER4 {
            guard i + 15 < len else { result += "\u{FFFD}"; i += 1; continue }
            var cp: UInt64 = 0
            for j in 1...15 { cp = (cp << 4) | UInt64(nib[i + j]) }
            appendCP(UInt32(cp), cap: &capNext)
            i += 16; continue
        }

        result += "\u{FFFD}"
        i += 1
    }

    return result
}

// ─── Utilities ────────────────────────────────────────────────────────────────

public func utf64EncodeToHex(_ s: String) -> String {
    utf64Encode(s).map { String(format: "%02x", $0) }.joined(separator: " ")
}

public func utf64PayloadByteSize(_ s: String) -> Int {
    var nib: [UInt8] = []
    for scalar in s.unicodeScalars { encodeCP(scalar.value, &nib) }
    if nib.count % 2 != 0 { nib.append(0) }
    return nib.count / 2
}

// ─── Test Suite ───────────────────────────────────────────────────────────────

func runTests() {
    let tests: [(String, String)] = [
        ("hello",             "lowercase hello"),
        ("Hello",             "capitalized Hello"),
        ("",                  "empty string"),
        ("the rain in spain", "tier0-heavy sentence"),
        ("Hello, World!",     "mixed ascii"),
        ("Héllo",             "accented char (Tier2)"),
        ("日本語",             "Japanese (Tier2)"),
    ]

    print("UTF-64 Swift Test Suite")
    print(String(repeating: "=", count: 40))
    for (input, desc) in tests {
        let enc  = utf64Encode(input)
        let dec  = utf64Decode(enc)
        let ok   = dec == input
        let hex  = enc.map { String(format: "%02x", $0) }.joined(separator: " ")
        print("[\(ok ? "PASS" : "FAIL")] \(desc)")
        if !ok {
            print("  expected: \(input.debugDescription)")
            print("  got:      \(dec.debugDescription)")
        } else {
            print("  \(input.debugDescription) → \(utf64PayloadByteSize(input)) bytes")
        }
        print("  hex: \(hex)\n")
    }
}

runTests()
