/**
 * UTF-64 — Universal Transformation Format 64
 * Specification v0.1 — C Reference Implementation
 */

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

// ─── Constants ───────────────────────────────────────────────────────────────

static const char MAGIC[] = "&-9EX";
#define MAGIC_LEN 5

static const char TIER0_CHARS[] = {
  ' ', 'e', 't', 'a', 'o', 'i', 'n', 's', 'h', 'r', 'l', '\n'
};
#define TIER0_COUNT 12

#define ESC_CAP    0xC
#define ESC_TIER1  0xD
#define ESC_TIER23 0xE
#define ESC_TIER4  0xF
#define CTRL_CAP   0x0

// ─── Nibble buffer ────────────────────────────────────────────────────────────

typedef struct {
  uint8_t *data;
  size_t   len;
  size_t   cap;
} NibBuf;

static void nib_push(NibBuf *b, uint8_t v) {
  if (b->len >= b->cap) {
    b->cap = b->cap ? b->cap * 2 : 64;
    b->data = realloc(b->data, b->cap);
  }
  b->data[b->len++] = v & 0xF;
}

// ─── Tier0 lookup ─────────────────────────────────────────────────────────────

static int tier0_index(uint32_t cp) {
  for (int i = 0; i < TIER0_COUNT; i++)
    if ((uint32_t)(unsigned char)TIER0_CHARS[i] == cp) return i;
  return -1;
}

// Simple lowercase for ASCII only (sufficient for Tier0 CAP handling)
static uint32_t cp_tolower(uint32_t cp) {
  if (cp >= 'A' && cp <= 'Z') return cp + 32;
  return cp;
}

static int cp_isupper(uint32_t cp) {
  return cp >= 'A' && cp <= 'Z';
}

// ─── Encoder ─────────────────────────────────────────────────────────────────

static void encode_tier3(uint32_t cp, NibBuf *nib) {
  nib_push(nib, ESC_TIER23);
  nib_push(nib, 0x8);
  for (int shift = 24; shift >= 0; shift -= 4)
    nib_push(nib, (cp >> shift) & 0xF);
}

static void encode_cp(uint32_t cp, NibBuf *nib) {
  uint32_t lower = cp_tolower(cp);
  int is_upper   = cp_isupper(cp);
  int t0         = tier0_index(cp);
  int t0l        = tier0_index(lower);

  // Uppercase whose lowercase is Tier0
  if (is_upper && t0l >= 0) {
    nib_push(nib, ESC_CAP);
    nib_push(nib, CTRL_CAP);
    nib_push(nib, (uint8_t)t0l);
    return;
  }

  // Tier 0 direct
  if (t0 >= 0) {
    nib_push(nib, (uint8_t)t0);
    return;
  }

  // Tier 1: 0x00–0xFF
  if (cp <= 0xFF) {
    nib_push(nib, ESC_TIER1);
    nib_push(nib, (cp >> 4) & 0xF);
    nib_push(nib, cp & 0xF);
    return;
  }

  // Tier 2: 0x100–0xFFFF (n3 <= 7)
  if (cp <= 0xFFFF) {
    uint8_t n3 = (cp >> 12) & 0xF;
    if (n3 <= 0x7) {
      nib_push(nib, ESC_TIER23);
      nib_push(nib, n3);
      nib_push(nib, (cp >> 8) & 0xF);
      nib_push(nib, (cp >> 4) & 0xF);
      nib_push(nib, cp & 0xF);
    } else {
      encode_tier3(cp, nib);
    }
    return;
  }

  // Tier 3: 0x10000–0xFFFFFFFF
  if (cp <= 0xFFFFFFFFU) {
    encode_tier3(cp, nib);
    return;
  }

  // Tier 4: > 0xFFFFFFFF (up to 60-bit)
  nib_push(nib, ESC_TIER4);
  for (int shift = 56; shift >= 0; shift -= 4)
    nib_push(nib, (uint8_t)((cp >> shift) & 0xF));
}

/**
 * Decode a single UTF-8 sequence, return code point.
 * Advances *p past the sequence. Returns 0xFFFD on error.
 */
static uint32_t utf8_next(const uint8_t **p, const uint8_t *end) {
  uint8_t b0 = **p;
  (*p)++;
  if (b0 < 0x80) return b0;
  int extra;
  uint32_t cp;
  if      ((b0 & 0xE0) == 0xC0) { extra = 1; cp = b0 & 0x1F; }
  else if ((b0 & 0xF0) == 0xE0) { extra = 2; cp = b0 & 0x0F; }
  else if ((b0 & 0xF8) == 0xF0) { extra = 3; cp = b0 & 0x07; }
  else return 0xFFFD;
  for (int i = 0; i < extra; i++) {
    if (*p >= end) return 0xFFFD;
    cp = (cp << 6) | (**p & 0x3F);
    (*p)++;
  }
  return cp;
}

/**
 * Encode a UTF-8 string to UTF-64 bytes.
 * Returns heap-allocated buffer; caller must free(). Sets *out_len.
 */
uint8_t *utf64_encode(const char *str, size_t str_len, size_t *out_len) {
  NibBuf nib = {0};

  // BOM
  nib_push(&nib, ESC_TIER1);
  nib_push(&nib, 0x0);
  nib_push(&nib, 0x2);

  const uint8_t *p   = (const uint8_t *)str;
  const uint8_t *end = p + str_len;
  while (p < end) {
    uint32_t cp = utf8_next(&p, end);
    encode_cp(cp, &nib);
  }

  // Pad to even
  if (nib.len % 2) nib_push(&nib, 0x0);

  // Pack nibbles → bytes
  size_t payload = nib.len / 2;
  size_t total   = MAGIC_LEN + payload;
  uint8_t *out   = malloc(total);
  memcpy(out, MAGIC, MAGIC_LEN);
  for (size_t i = 0; i < nib.len; i += 2)
    out[MAGIC_LEN + i/2] = (nib.data[i] << 4) | nib.data[i+1];

  free(nib.data);
  *out_len = total;
  return out;
}

// ─── Decoder ─────────────────────────────────────────────────────────────────

/** Write a Unicode code point as UTF-8 into buf. Returns bytes written. */
static int cp_to_utf8(uint32_t cp, char *buf) {
  if (cp < 0x80)        { buf[0] = (char)cp; return 1; }
  if (cp < 0x800)       { buf[0] = 0xC0|(cp>>6); buf[1] = 0x80|(cp&0x3F); return 2; }
  if (cp < 0x10000)     { buf[0] = 0xE0|(cp>>12); buf[1] = 0x80|((cp>>6)&0x3F); buf[2] = 0x80|(cp&0x3F); return 3; }
  if (cp < 0x110000)    { buf[0] = 0xF0|(cp>>18); buf[1] = 0x80|((cp>>12)&0x3F); buf[2] = 0x80|((cp>>6)&0x3F); buf[3] = 0x80|(cp&0x3F); return 4; }
  buf[0] = '\xEF'; buf[1] = '\xBF'; buf[2] = '\xBD'; return 3; // U+FFFD
}

/**
 * Decode UTF-64 bytes to a UTF-8 string.
 * Returns heap-allocated null-terminated string; caller must free().
 */
char *utf64_decode(const uint8_t *buf, size_t buf_len) {
  size_t byte_offset = 0;
  // Strip magic
  if (buf_len >= MAGIC_LEN && memcmp(buf, MAGIC, MAGIC_LEN) == 0)
    byte_offset = MAGIC_LEN;

  // Unpack bytes → nibbles
  size_t nb_count = (buf_len - byte_offset) * 2;
  uint8_t *nib = malloc(nb_count);
  for (size_t i = 0; i < buf_len - byte_offset; i++) {
    nib[i*2]   = (buf[byte_offset + i] >> 4) & 0xF;
    nib[i*2+1] = buf[byte_offset + i] & 0xF;
  }

  // Output buffer (worst case: 4 bytes per nibble)
  char *out = malloc(nb_count * 4 + 1);
  size_t out_pos = 0;
  size_t i = 0;
  int cap_next = 0;

  // Skip BOM
  if (i+2 < nb_count && nib[i]==ESC_TIER1 && nib[i+1]==0x0 && nib[i+2]==0x2) i += 3;

  while (i < nb_count) {
    if (i == nb_count-1 && nib[i] == 0x0) break; // trailing pad

    uint8_t n = nib[i];

    if (n <= 0xB) {
      char c = TIER0_CHARS[n];
      if (cap_next && c >= 'a' && c <= 'z') { c -= 32; cap_next = 0; }
      out[out_pos++] = c;
      i++;
      continue;
    }

    if (n == ESC_CAP) {
      uint8_t ctrl = nib[i+1] & 0x3;
      if (ctrl == CTRL_CAP) cap_next = 1;
      i += 2;
      continue;
    }

    if (n == ESC_TIER1) {
      if (i+2 >= nb_count) { out[out_pos++] = '?'; i++; continue; }
      uint32_t cp = ((uint32_t)nib[i+1] << 4) | nib[i+2];
      if (cap_next && cp >= 'a' && cp <= 'z') { cp -= 32; cap_next = 0; }
      char tmp[4]; int w = cp_to_utf8(cp, tmp);
      memcpy(out + out_pos, tmp, w); out_pos += w;
      i += 3;
      continue;
    }

    if (n == ESC_TIER23) {
      if (i+1 >= nb_count) { out[out_pos++] = '?'; i++; continue; }
      if (nib[i+1] <= 0x7) {
        if (i+4 >= nb_count) { out[out_pos++] = '?'; i++; continue; }
        uint32_t cp = ((uint32_t)nib[i+1]<<12)|((uint32_t)nib[i+2]<<8)|((uint32_t)nib[i+3]<<4)|nib[i+4];
        char tmp[4]; int w = cp_to_utf8(cp, tmp);
        memcpy(out + out_pos, tmp, w); out_pos += w;
        i += 5;
      } else {
        if (i+8 >= nb_count) { out[out_pos++] = '?'; i++; continue; }
        uint32_t cp = ((uint32_t)nib[i+2]<<24)|((uint32_t)nib[i+3]<<20)|
                      ((uint32_t)nib[i+4]<<16)|((uint32_t)nib[i+5]<<12)|
                      ((uint32_t)nib[i+6]<<8) |((uint32_t)nib[i+7]<<4)|nib[i+8];
        char tmp[4]; int w = cp_to_utf8(cp, tmp);
        memcpy(out + out_pos, tmp, w); out_pos += w;
        i += 9;
      }
      continue;
    }

    if (n == ESC_TIER4) {
      if (i+15 >= nb_count) { out[out_pos++] = '?'; i++; continue; }
      uint64_t cp = 0;
      for (int j = 1; j <= 15; j++) cp = (cp << 4) | nib[i+j];
      char tmp[4]; int w = cp_to_utf8((uint32_t)cp, tmp);
      memcpy(out + out_pos, tmp, w); out_pos += w;
      i += 16;
      continue;
    }

    out[out_pos++] = '?';
    i++;
  }

  out[out_pos] = '\0';
  free(nib);
  return out;
}

// ─── Test Suite ──────────────────────────────────────────────────────────────

static void run_tests(void) {
  const char *tests[] = {
    "hello",
    "Hello",
    "",
    "the rain in spain",
    "Hello, World!",
    "H\xC3\xA9llo",   // Héllo (UTF-8)
    "\xE6\x97\xA5\xE6\x9C\xAC\xE8\xAA\x9E", // 日本語
  };
  const char *descs[] = {
    "lowercase hello",
    "capitalized Hello",
    "empty string",
    "tier0-heavy sentence",
    "mixed ascii",
    "accented char (Tier2)",
    "Japanese (Tier2)",
  };
  int n = sizeof(tests)/sizeof(tests[0]);

  printf("UTF-64 C Test Suite\n%s\n", "========================================");
  for (int t = 0; t < n; t++) {
    size_t out_len;
    uint8_t *enc = utf64_encode(tests[t], strlen(tests[t]), &out_len);
    char    *dec = utf64_decode(enc, out_len);
    int pass = strcmp(dec, tests[t]) == 0;
    printf("[%s] %s\n", pass ? "PASS" : "FAIL", descs[t]);
    if (!pass) {
      printf("  expected: \"%s\"\n", tests[t]);
      printf("  got:      \"%s\"\n", dec);
    } else {
      printf("  \"%s\" → %zu payload bytes\n", tests[t], out_len - MAGIC_LEN);
    }
    printf("  hex:");
    for (size_t b = 0; b < out_len; b++) printf(" %02x", enc[b]);
    printf("\n\n");
    free(enc);
    free(dec);
  }
}

int main(void) {
  run_tests();
  return 0;
}
