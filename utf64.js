/**
 * UTF-64 — Universal Transformation Format 64
 * Specification v0.1
 * JavaScript Reference Implementation
 */

// ─── Constants ───────────────────────────────────────────────────────────────

const MAGIC = "&-9EX";
const BOM_CP = 0x0002;

// Tier 0: direct single-nibble assignments (0x0–0xB)
const TIER0_CHARS = [
  ' ',  // 0x0
  'e',  // 0x1
  't',  // 0x2
  'a',  // 0x3
  'o',  // 0x4
  'i',  // 0x5
  'n',  // 0x6
  's',  // 0x7
  'h',  // 0x8
  'r',  // 0x9
  'l',  // 0xA
  '\n', // 0xB
];

const TIER0_MAP = new Map(TIER0_CHARS.map((c, i) => [c, i]));

const ESC_CAP    = 0xC;
const ESC_TIER1  = 0xD;
const ESC_TIER23 = 0xE;
const ESC_TIER4  = 0xF;
const CTRL_CAP   = 0x0; // 2-bit payload after 0xC

// ─── Encoder ─────────────────────────────────────────────────────────────────

function encode(str) {
  const nibbles = [];

  // BOM: Tier1 encoding of 0x0002 → [0xD, 0x0, 0x2]
  nibbles.push(ESC_TIER1, 0x0, 0x2);

  for (let i = 0; i < str.length; ) {
    const cp = str.codePointAt(i);
    i += cp > 0xFFFF ? 2 : 1;
    _encodeCP(cp, nibbles);
  }

  // Pad to even nibble count
  if (nibbles.length % 2 !== 0) nibbles.push(0x0);

  // Pack nibbles → bytes (high nibble first)
  const bytes = new Uint8Array(nibbles.length / 2);
  for (let i = 0; i < nibbles.length; i += 2) {
    bytes[i / 2] = ((nibbles[i] & 0xF) << 4) | (nibbles[i + 1] & 0xF);
  }

  // Prepend magic as raw ASCII
  const magicBytes = new TextEncoder().encode(MAGIC);
  const out = new Uint8Array(magicBytes.length + bytes.length);
  out.set(magicBytes);
  out.set(bytes, magicBytes.length);
  return out;
}

function _encodeCP(cp, nib) {
  const char = String.fromCodePoint(cp);
  const lower = char.toLowerCase();
  const isUpper = char !== lower;

  // Uppercase whose lowercase is Tier0 → CAP + Tier0 nibble
  if (isUpper && TIER0_MAP.has(lower)) {
    nib.push(ESC_CAP, CTRL_CAP, TIER0_MAP.get(lower));
    return;
  }

  // Tier 0 direct
  if (TIER0_MAP.has(char)) {
    nib.push(TIER0_MAP.get(char));
    return;
  }

  // Tier 1: cp 0x00–0xFF (3 nibbles: [0xD][hi][lo])
  if (cp <= 0xFF) {
    if (isUpper) {
      const lcp = lower.codePointAt(0);
      if (TIER0_MAP.has(lower)) {
        nib.push(ESC_CAP, CTRL_CAP, TIER0_MAP.get(lower));
      } else {
        nib.push(ESC_CAP, CTRL_CAP, ESC_TIER1, (lcp >> 4) & 0xF, lcp & 0xF);
      }
      return;
    }
    nib.push(ESC_TIER1, (cp >> 4) & 0xF, cp & 0xF);
    return;
  }

  // Tier 2: cp 0x100–0xFFFF → [0xE][n3][n2][n1][n0] (5 nibbles, n3 ≤ 0x7)
  if (cp <= 0xFFFF) {
    const n3 = (cp >> 12) & 0xF;
    const n2 = (cp >> 8) & 0xF;
    const n1 = (cp >> 4) & 0xF;
    const n0 = cp & 0xF;
    if (n3 <= 0x7) {
      nib.push(ESC_TIER23, n3, n2, n1, n0);
    } else {
      // n3 > 0x7 would collide with Tier3 marker; use Tier3 encoding
      _encodeTier3(cp, nib);
    }
    return;
  }

  // Tier 3: cp 0x10000–0xFFFFFFFF → [0xE][0x8][7 data nibbles]
  if (cp <= 0xFFFFFFFF) {
    _encodeTier3(cp, nib);
    return;
  }

  // Tier 4: cp > 0xFFFFFFFF → [0xF][15 data nibbles]
  nib.push(ESC_TIER4);
  for (let shift = 56; shift >= 0; shift -= 4) {
    nib.push(Number((BigInt(cp) >> BigInt(shift)) & 0xFn));
  }
}

function _encodeTier3(cp, nib) {
  // [0xE][0x8][n6][n5][n4][n3][n2][n1][n0] — 9 nibbles
  nib.push(ESC_TIER23, 0x8);
  for (let shift = 24; shift >= 0; shift -= 4) {
    nib.push((cp >> shift) & 0xF);
  }
}

// ─── Decoder ─────────────────────────────────────────────────────────────────

function decode(buf) {
  // Strip magic
  const magicBytes = new TextEncoder().encode(MAGIC);
  let byteOffset = 0;
  let hasMagic = buf.length >= magicBytes.length;
  for (let i = 0; i < magicBytes.length && hasMagic; i++) {
    if (buf[i] !== magicBytes[i]) hasMagic = false;
  }
  if (hasMagic) byteOffset = magicBytes.length;

  // Unpack bytes → nibbles
  const nib = [];
  for (let i = byteOffset; i < buf.length; i++) {
    nib.push((buf[i] >> 4) & 0xF, buf[i] & 0xF);
  }

  let result = '';
  let i = 0;
  let capNext = false;

  // Skip BOM [0xD][0x0][0x2]
  if (nib[i] === ESC_TIER1 && nib[i+1] === 0x0 && nib[i+2] === 0x2) i += 3;

  while (i < nib.length) {
    // Skip trailing padding
    if (i === nib.length - 1 && nib[i] === 0x0) break;

    const n = nib[i];

    if (n <= 0xB) {
      // Tier 0 direct
      let c = TIER0_CHARS[n];
      if (capNext) { c = c.toUpperCase(); capNext = false; }
      result += c;
      i++;
      continue;
    }

    if (n === ESC_CAP) {
      // [0xC][ctrl nibble] — low 2 bits are payload
      const ctrl = nib[i+1] & 0x3;
      if (ctrl === CTRL_CAP) capNext = true;
      i += 2;
      continue;
    }

    if (n === ESC_TIER1) {
      // [0xD][hi][lo]
      if (i + 2 >= nib.length) { result += _inv(); i++; continue; }
      const cp = (nib[i+1] << 4) | nib[i+2];
      let c = String.fromCodePoint(cp);
      if (capNext) { c = c.toUpperCase(); capNext = false; }
      result += c;
      i += 3;
      continue;
    }

    if (n === ESC_TIER23) {
      const lenNib = nib[i+1];
      if (lenNib <= 0x7) {
        // Tier 2: [0xE][n3][n2][n1][n0]
        if (i + 4 >= nib.length) { result += _inv(); i++; continue; }
        const cp = (nib[i+1] << 12) | (nib[i+2] << 8) | (nib[i+3] << 4) | nib[i+4];
        let c = String.fromCodePoint(cp);
        if (capNext) { c = c.toUpperCase(); capNext = false; }
        result += c;
        i += 5;
      } else {
        // Tier 3: [0xE][0x8][n6..n0]
        if (i + 8 >= nib.length) { result += _inv(); i++; continue; }
        const cp = (nib[i+2] << 24) | (nib[i+3] << 20) | (nib[i+4] << 16) |
                   (nib[i+5] << 12) | (nib[i+6] << 8)  | (nib[i+7] << 4)  | nib[i+8];
        let c = String.fromCodePoint(cp);
        if (capNext) { c = c.toUpperCase(); capNext = false; }
        result += c;
        i += 9;
      }
      continue;
    }

    if (n === ESC_TIER4) {
      // [0xF] + 15 data nibbles
      if (i + 15 >= nib.length) { result += _inv(); i++; continue; }
      let cp = 0n;
      for (let j = 1; j <= 15; j++) cp = (cp << 4n) | BigInt(nib[i+j]);
      result += String.fromCodePoint(Number(cp));
      i += 16;
      continue;
    }

    result += _inv();
    i++;
  }

  return result;
}

function _inv() {
  return '\x00\x00\x00\x00\x00\x00\x00\x00';
}

// ─── Utilities ───────────────────────────────────────────────────────────────

function encodeToHex(str) {
  return Array.from(encode(str)).map(b => b.toString(16).padStart(2, '0')).join(' ');
}

function payloadByteSize(str) {
  const nib = [];
  for (let i = 0; i < str.length; ) {
    const cp = str.codePointAt(i);
    i += cp > 0xFFFF ? 2 : 1;
    _encodeCP(cp, nib);
  }
  if (nib.length % 2 !== 0) nib.push(0x0);
  return nib.length / 2;
}

// ─── Test Suite ──────────────────────────────────────────────────────────────

function runTests() {
  const tests = [
    { input: 'hello',              desc: 'lowercase hello' },
    { input: 'Hello',              desc: 'capitalized Hello' },
    { input: '',                   desc: 'empty string' },
    { input: 'the rain in spain',  desc: 'tier0-heavy sentence' },
    { input: 'Hello, World!',      desc: 'mixed ascii' },
    { input: 'Héllo',              desc: 'accented char (Tier2)' },
    { input: '日本語',              desc: 'Japanese (Tier2)' },
  ];

  console.log('UTF-64 Test Suite\n' + '='.repeat(40));
  for (const t of tests) {
    const encoded = encode(t.input);
    const decoded = decode(encoded);
    const hex = Array.from(encoded).map(b => b.toString(16).padStart(2,'0')).join(' ');
    const pass = decoded === t.input;
    console.log(`[${pass ? 'PASS' : 'FAIL'}] ${t.desc}`);
    if (!pass) {
      console.log(`  expected: "${t.input}"`);
      console.log(`  got:      "${decoded}"`);
    } else {
      console.log(`  "${t.input}" → ${payloadByteSize(t.input)} payload bytes`);
    }
    console.log(`  hex: ${hex}`);
    console.log();
  }
}

// ─── Exports ─────────────────────────────────────────────────────────────────

if (typeof module !== 'undefined') {
  module.exports = { encode, decode, encodeToHex, payloadByteSize, runTests, MAGIC, BOM_CP, TIER0_CHARS };
}

if (typeof require !== 'undefined' && require.main === module) runTests();
