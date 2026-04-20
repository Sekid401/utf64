/*!
 * UTF-64 — Universal Transformation Format 64
 * Specification v0.1 — Rust Reference Implementation
 *
 * Note: Rust `char` is a Unicode scalar value (0x0000–0xD7FF, 0xE000–0x10FFFF).
 * Tier 4 (>0xFFFFFFFF) is unreachable from `&str` input; the encoder accepts
 * `u64` code points directly if you need that range.
 */

// ─── Constants ────────────────────────────────────────────────────────────────

const MAGIC: &[u8] = b"&-9EX";

const TIER0_CHARS: [char; 12] = [
    ' ', 'e', 't', 'a', 'o', 'i', 'n', 's', 'h', 'r', 'l', '\n',
];

const ESC_CAP:    u8 = 0xC;
const ESC_TIER1:  u8 = 0xD;
const ESC_TIER23: u8 = 0xE;
const ESC_TIER4:  u8 = 0xF;
const CTRL_CAP:   u8 = 0x0;

// ─── Helpers ──────────────────────────────────────────────────────────────────

fn tier0_index(cp: u64) -> Option<u8> {
    TIER0_CHARS
        .iter()
        .position(|&c| c as u64 == cp)
        .map(|i| i as u8)
}

// ─── Encoder ──────────────────────────────────────────────────────────────────

fn encode_tier3(cp: u64, nib: &mut Vec<u8>) {
    nib.push(ESC_TIER23);
    nib.push(0x8);
    for shift in (0..=24u32).rev().step_by(4) {
        nib.push(((cp >> shift) & 0xF) as u8);
    }
}

fn encode_cp(cp: u64, nib: &mut Vec<u8>) {
    let ch    = char::from_u32(cp as u32);
    let lower = ch.map(|c| c.to_lowercase().next().unwrap_or(c));
    let is_upper = ch.map(|c| c.is_uppercase()).unwrap_or(false);
    let t0l   = lower.and_then(|c| tier0_index(c as u64));

    // Uppercase whose lowercase is Tier0
    if is_upper {
        if let Some(idx) = t0l {
            nib.push(ESC_CAP);
            nib.push(CTRL_CAP);
            nib.push(idx);
            return;
        }
    }

    // Tier 0 direct
    if let Some(idx) = tier0_index(cp) {
        nib.push(idx);
        return;
    }

    // Tier 1: 0x00–0xFF
    if cp <= 0xFF {
        nib.push(ESC_TIER1);
        nib.push(((cp >> 4) & 0xF) as u8);
        nib.push((cp & 0xF) as u8);
        return;
    }

    // Tier 2: 0x100–0xFFFF
    if cp <= 0xFFFF {
        let n3 = ((cp >> 12) & 0xF) as u8;
        if n3 <= 0x7 {
            nib.push(ESC_TIER23);
            nib.push(n3);
            nib.push(((cp >> 8) & 0xF) as u8);
            nib.push(((cp >> 4) & 0xF) as u8);
            nib.push((cp & 0xF) as u8);
        } else {
            encode_tier3(cp, nib);
        }
        return;
    }

    // Tier 3: 0x10000–0xFFFFFFFF
    if cp <= 0xFFFF_FFFF {
        encode_tier3(cp, nib);
        return;
    }

    // Tier 4: > 0xFFFFFFFF (up to 60-bit)
    nib.push(ESC_TIER4);
    for shift in (0..=56u32).rev().step_by(4) {
        nib.push(((cp >> shift) & 0xF) as u8);
    }
}

/// Encode a `&str` to UTF-64 bytes.
pub fn encode(s: &str) -> Vec<u8> {
    let mut nib: Vec<u8> = Vec::new();

    // BOM
    nib.push(ESC_TIER1);
    nib.push(0x0);
    nib.push(0x2);

    for ch in s.chars() {
        encode_cp(ch as u64, &mut nib);
    }

    // Pad to even
    if nib.len() % 2 != 0 {
        nib.push(0x0);
    }

    // Pack nibbles → bytes
    let mut payload: Vec<u8> = nib
        .chunks(2)
        .map(|c| ((c[0] & 0xF) << 4) | (c[1] & 0xF))
        .collect();

    let mut out = MAGIC.to_vec();
    out.append(&mut payload);
    out
}

// ─── Decoder ──────────────────────────────────────────────────────────────────

/// Decode UTF-64 bytes to a `String`.
pub fn decode(buf: &[u8]) -> String {
    // Strip magic
    let byte_offset = if buf.starts_with(MAGIC) { MAGIC.len() } else { 0 };

    // Unpack bytes → nibbles
    let nib: Vec<u8> = buf[byte_offset..]
        .iter()
        .flat_map(|&b| [(b >> 4) & 0xF, b & 0xF])
        .collect();

    let mut result   = String::new();
    let mut i        = 0usize;
    let mut cap_next = false;
    let len          = nib.len();

    // Skip BOM
    if len >= 3 && nib[0] == ESC_TIER1 && nib[1] == 0x0 && nib[2] == 0x2 {
        i = 3;
    }

    while i < len {
        // Trailing pad
        if i == len - 1 && nib[i] == 0x0 {
            break;
        }

        let n = nib[i];

        if n <= 0xB {
            let mut c = TIER0_CHARS[n as usize];
            if cap_next {
                c = c.to_uppercase().next().unwrap_or(c);
                cap_next = false;
            }
            result.push(c);
            i += 1;
            continue;
        }

        if n == ESC_CAP {
            let ctrl = nib[i + 1] & 0x3;
            if ctrl == CTRL_CAP {
                cap_next = true;
            }
            i += 2;
            continue;
        }

        if n == ESC_TIER1 {
            if i + 2 >= len { result.push('\u{FFFD}'); i += 1; continue; }
            let cp = ((nib[i+1] as u32) << 4) | nib[i+2] as u32;
            let mut c = char::from_u32(cp).unwrap_or('\u{FFFD}');
            if cap_next { c = c.to_uppercase().next().unwrap_or(c); cap_next = false; }
            result.push(c);
            i += 3;
            continue;
        }

        if n == ESC_TIER23 {
            if i + 1 >= len { result.push('\u{FFFD}'); i += 1; continue; }
            if nib[i+1] <= 0x7 {
                if i + 4 >= len { result.push('\u{FFFD}'); i += 1; continue; }
                let cp = ((nib[i+1] as u32) << 12) | ((nib[i+2] as u32) << 8)
                       | ((nib[i+3] as u32) << 4)  |  (nib[i+4] as u32);
                let mut c = char::from_u32(cp).unwrap_or('\u{FFFD}');
                if cap_next { c = c.to_uppercase().next().unwrap_or(c); cap_next = false; }
                result.push(c);
                i += 5;
            } else {
                if i + 8 >= len { result.push('\u{FFFD}'); i += 1; continue; }
                let cp = ((nib[i+2] as u32) << 24) | ((nib[i+3] as u32) << 20)
                       | ((nib[i+4] as u32) << 16) | ((nib[i+5] as u32) << 12)
                       | ((nib[i+6] as u32) << 8)  | ((nib[i+7] as u32) << 4)
                       |  (nib[i+8] as u32);
                result.push(char::from_u32(cp).unwrap_or('\u{FFFD}'));
                i += 9;
            }
            continue;
        }

        if n == ESC_TIER4 {
            if i + 15 >= len { result.push('\u{FFFD}'); i += 1; continue; }
            let cp: u64 = (1..=15).fold(0u64, |acc, j| (acc << 4) | nib[i+j] as u64);
            result.push(char::from_u32(cp as u32).unwrap_or('\u{FFFD}'));
            i += 16;
            continue;
        }

        result.push('\u{FFFD}');
        i += 1;
    }

    result
}

// ─── Utilities ────────────────────────────────────────────────────────────────

pub fn encode_to_hex(s: &str) -> String {
    encode(s).iter().map(|b| format!("{:02x}", b)).collect::<Vec<_>>().join(" ")
}

pub fn payload_byte_size(s: &str) -> usize {
    let mut nib: Vec<u8> = Vec::new();
    for ch in s.chars() {
        encode_cp(ch as u64, &mut nib);
    }
    if nib.len() % 2 != 0 { nib.push(0); }
    nib.len() / 2
}

// ─── Test Suite ───────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn case(input: &str, desc: &str) {
        let enc = encode(input);
        let dec = decode(&enc);
        let hex = enc.iter().map(|b| format!("{:02x}", b)).collect::<Vec<_>>().join(" ");
        let pass = dec == input;
        println!("[{}] {}", if pass { "PASS" } else { "FAIL" }, desc);
        if !pass {
            println!("  expected: {:?}", input);
            println!("  got:      {:?}", dec);
        } else {
            println!("  {:?} → {} payload bytes", input, payload_byte_size(input));
        }
        println!("  hex: {}\n", hex);
        assert_eq!(dec, input);
    }

    #[test]
    fn test_all() {
        println!("UTF-64 Rust Test Suite");
        println!("{}", "=".repeat(40));
        case("hello",             "lowercase hello");
        case("Hello",             "capitalized Hello");
        case("",                  "empty string");
        case("the rain in spain", "tier0-heavy sentence");
        case("Hello, World!",     "mixed ascii");
        case("Héllo",             "accented char (Tier2)");
        case("日本語",             "Japanese (Tier2)");
    }
}

fn main() {
    let cases: &[(&str, &str)] = &[
        ("hello",             "lowercase hello"),
        ("Hello",             "capitalized Hello"),
        ("",                  "empty string"),
        ("the rain in spain", "tier0-heavy sentence"),
        ("Hello, World!",     "mixed ascii"),
        ("Héllo",             "accented char (Tier2)"),
        ("日本語",             "Japanese (Tier2)"),
    ];

    println!("UTF-64 Rust Test Suite");
    println!("{}", "=".repeat(40));
    for (input, desc) in cases {
        let enc  = encode(input);
        let dec  = decode(&enc);
        let hex  = enc.iter().map(|b| format!("{:02x}", b)).collect::<Vec<_>>().join(" ");
        let pass = &dec == input;
        println!("[{}] {}", if pass { "PASS" } else { "FAIL" }, desc);
        if !pass {
            println!("  expected: {:?}", input);
            println!("  got:      {:?}", dec);
        } else {
            println!("  {:?} → {} payload bytes", input, payload_byte_size(input));
        }
        println!("  hex: {}\n", hex);
    }
}
