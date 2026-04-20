/**
 * UTF-64 — Universal Transformation Format 64
 * Specification v0.1 — Java Reference Implementation
 *
 * Pure Java, no dependencies. Compatible with Java 8+.
 * Package: com.utf64
 */

package com.utf64;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;

public final class UTF64 {

    // ─── Constants ───────────────────────────────────────────────────────────

    private static final byte[] MAGIC = { '&', '-', '9', 'E', 'X' };

    private static final int[] TIER0_CHARS = {
        ' ', 'e', 't', 'a', 'o', 'i', 'n', 's', 'h', 'r', 'l', '\n'
    };

    private static final int[] TIER0_MAP = new int[128];

    private static final int ESC_CAP    = 0xC;
    private static final int ESC_TIER1  = 0xD;
    private static final int ESC_TIER23 = 0xE;
    private static final int ESC_TIER4  = 0xF;
    private static final int CTRL_CAP   = 0x0;

    static {
        for (int i = 0; i < TIER0_MAP.length; i++) TIER0_MAP[i] = -1;
        for (int i = 0; i < TIER0_CHARS.length; i++) {
            TIER0_MAP[TIER0_CHARS[i]] = i;
        }
    }

    private UTF64() {}

    // ─── Tier0 helpers ───────────────────────────────────────────────────────

    private static int tier0Index(int cp) {
        if (cp >= 0 && cp < TIER0_MAP.length) return TIER0_MAP[cp];
        return -1;
    }

    // ─── Encoder ─────────────────────────────────────────────────────────────

    private static void encodeTier3(int cp, ArrayList<Integer> nib) {
        nib.add(ESC_TIER23);
        nib.add(0x8);
        for (int shift = 24; shift >= 0; shift -= 4)
            nib.add((cp >> shift) & 0xF);
    }

    private static void encodeCP(int cp, ArrayList<Integer> nib) {
        int lower    = (cp >= 'A' && cp <= 'Z') ? cp + 32 : cp;
        boolean isUp = (cp >= 'A' && cp <= 'Z');
        int t0l      = tier0Index(lower);
        int t0       = tier0Index(cp);

        // Uppercase whose lowercase is Tier0
        if (isUp && t0l >= 0) {
            nib.add(ESC_CAP); nib.add(CTRL_CAP); nib.add(t0l);
            return;
        }

        // Tier 0 direct
        if (t0 >= 0) {
            nib.add(t0);
            return;
        }

        // Tier 1: 0x00–0xFF
        if (cp <= 0xFF) {
            nib.add(ESC_TIER1);
            nib.add((cp >> 4) & 0xF);
            nib.add(cp & 0xF);
            return;
        }

        // Tier 2: 0x100–0xFFFF
        if (cp <= 0xFFFF) {
            int n3 = (cp >> 12) & 0xF;
            if (n3 <= 0x7) {
                nib.add(ESC_TIER23);
                nib.add(n3);
                nib.add((cp >> 8) & 0xF);
                nib.add((cp >> 4) & 0xF);
                nib.add(cp & 0xF);
            } else {
                encodeTier3(cp, nib);
            }
            return;
        }

        // Tier 3: 0x10000–0xFFFFFFFF
        if (cp <= 0xFFFFFFFF) {
            encodeTier3(cp, nib);
            return;
        }

        // Tier 4: > 0xFFFFFFFF (up to 60-bit, via long)
        nib.add(ESC_TIER4);
        for (int shift = 56; shift >= 0; shift -= 4)
            nib.add((int)((((long) cp) >> shift) & 0xF));
    }

    /**
     * Encode a Java String to UTF-64 bytes.
     *
     * @param s Input string
     * @return  UTF-64 encoded byte array
     */
    public static byte[] encode(String s) {
        ArrayList<Integer> nib = new ArrayList<>();

        // BOM
        nib.add(ESC_TIER1); nib.add(0x0); nib.add(0x2);

        int i = 0;
        while (i < s.length()) {
            int cp = s.codePointAt(i);
            i += Character.charCount(cp);
            encodeCP(cp, nib);
        }

        // Pad to even
        if (nib.size() % 2 != 0) nib.add(0x0);

        // Pack nibbles → bytes
        byte[] payload = new byte[nib.size() / 2];
        for (int j = 0; j < nib.size(); j += 2)
            payload[j / 2] = (byte)(((nib.get(j) & 0xF) << 4) | (nib.get(j+1) & 0xF));

        byte[] out = new byte[MAGIC.length + payload.length];
        System.arraycopy(MAGIC, 0, out, 0, MAGIC.length);
        System.arraycopy(payload, 0, out, MAGIC.length, payload.length);
        return out;
    }

    // ─── Decoder ─────────────────────────────────────────────────────────────

    /**
     * Decode UTF-64 bytes to a Java String.
     *
     * @param buf UTF-64 encoded byte array
     * @return    Decoded String
     */
    public static String decode(byte[] buf) {
        // Strip magic
        int byteOffset = 0;
        if (buf.length >= MAGIC.length) {
            boolean hasMagic = true;
            for (int i = 0; i < MAGIC.length; i++)
                if (buf[i] != MAGIC[i]) { hasMagic = false; break; }
            if (hasMagic) byteOffset = MAGIC.length;
        }

        // Unpack bytes → nibbles
        int[] nib = new int[(buf.length - byteOffset) * 2];
        for (int i = 0; i < buf.length - byteOffset; i++) {
            int b = buf[byteOffset + i] & 0xFF;
            nib[i*2]   = (b >> 4) & 0xF;
            nib[i*2+1] =  b & 0xF;
        }

        StringBuilder sb = new StringBuilder();
        int i = 0;
        boolean capNext = false;

        // Skip BOM
        if (nib.length >= 3 && nib[0] == ESC_TIER1 && nib[1] == 0x0 && nib[2] == 0x2)
            i = 3;

        while (i < nib.length) {
            // Trailing pad
            if (i == nib.length - 1 && nib[i] == 0x0) break;

            int n = nib[i];

            if (n <= 0xB) {
                int cp = TIER0_CHARS[n];
                if (capNext && cp >= 'a' && cp <= 'z') { cp -= 32; capNext = false; }
                sb.appendCodePoint(cp);
                i++; continue;
            }

            if (n == ESC_CAP) {
                int ctrl = nib[i+1] & 0x3;
                capNext = (ctrl == CTRL_CAP);
                i += 2; continue;
            }

            if (n == ESC_TIER1) {
                if (i+2 >= nib.length) { sb.append('\uFFFD'); i++; continue; }
                int cp = (nib[i+1] << 4) | nib[i+2];
                if (capNext && cp >= 'a' && cp <= 'z') { cp -= 32; capNext = false; }
                sb.appendCodePoint(cp);
                i += 3; continue;
            }

            if (n == ESC_TIER23) {
                if (i+1 >= nib.length) { sb.append('\uFFFD'); i++; continue; }
                if (nib[i+1] <= 0x7) {
                    if (i+4 >= nib.length) { sb.append('\uFFFD'); i++; continue; }
                    int cp = (nib[i+1] << 12) | (nib[i+2] << 8) | (nib[i+3] << 4) | nib[i+4];
                    if (capNext) { capNext = false; }
                    sb.appendCodePoint(cp);
                    i += 5;
                } else {
                    if (i+8 >= nib.length) { sb.append('\uFFFD'); i++; continue; }
                    int cp = (nib[i+2] << 24) | (nib[i+3] << 20) | (nib[i+4] << 16)
                           | (nib[i+5] << 12) | (nib[i+6] << 8)  | (nib[i+7] << 4) | nib[i+8];
                    sb.appendCodePoint(cp);
                    i += 9;
                }
                continue;
            }

            if (n == ESC_TIER4) {
                if (i+15 >= nib.length) { sb.append('\uFFFD'); i++; continue; }
                long cp = 0;
                for (int j = 1; j <= 15; j++) cp = (cp << 4) | nib[i+j];
                sb.appendCodePoint((int) cp);
                i += 16; continue;
            }

            sb.append('\uFFFD');
            i++;
        }

        return sb.toString();
    }

    // ─── Utilities ───────────────────────────────────────────────────────────

    /** Encode to hex string for debugging. */
    public static String encodeToHex(String s) {
        byte[] enc = encode(s);
        StringBuilder sb = new StringBuilder();
        for (byte b : enc) {
            if (sb.length() > 0) sb.append(' ');
            sb.append(String.format("%02x", b & 0xFF));
        }
        return sb.toString();
    }

    /** Payload byte size excluding magic header. */
    public static int payloadByteSize(String s) {
        ArrayList<Integer> nib = new ArrayList<>();
        int i = 0;
        while (i < s.length()) {
            int cp = s.codePointAt(i);
            i += Character.charCount(cp);
            encodeCP(cp, nib);
        }
        if (nib.size() % 2 != 0) nib.add(0);
        return nib.size() / 2;
    }

    // ─── Test Suite ──────────────────────────────────────────────────────────

    public static void runTests() {
        String[][] tests = {
            { "hello",             "lowercase hello"        },
            { "Hello",             "capitalized Hello"      },
            { "",                  "empty string"           },
            { "the rain in spain", "tier0-heavy sentence"   },
            { "Hello, World!",     "mixed ascii"            },
            { "H\u00E9llo",        "accented char (Tier2)"  },
            { "\u65E5\u672C\u8A9E","Japanese (Tier2)"       },
        };

        System.out.println("UTF-64 Java Test Suite");
        System.out.println("=".repeat(40));
        for (String[] t : tests) {
            String input = t[0], desc = t[1];
            byte[] enc = encode(input);
            String dec = decode(enc);
            boolean pass = dec.equals(input);
            System.out.printf("[%s] %s%n", pass ? "PASS" : "FAIL", desc);
            if (!pass) {
                System.out.printf("  expected: %s%n", input);
                System.out.printf("  got:      %s%n", dec);
            } else {
                System.out.printf("  \"%s\" → %d payload bytes%n", input, payloadByteSize(input));
            }
            System.out.printf("  hex: %s%n%n", encodeToHex(input));
        }
    }

    public static void main(String[] args) {
        runTests();
    }
}
