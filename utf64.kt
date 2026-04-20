/**
 * UTF-64 — Universal Transformation Format 64
 * Specification v0.1 — Kotlin Reference Implementation
 *
 * Pure Kotlin, no dependencies. Compatible with Kotlin 1.5+ / Android API 21+.
 * Package: com.utf64
 */

package com.utf64

object UTF64 {

    // ─── Constants ───────────────────────────────────────────────────────────

    private val MAGIC = byteArrayOf('&'.code.toByte(), '-'.code.toByte(),
                                    '9'.code.toByte(), 'E'.code.toByte(), 'X'.code.toByte())

    private val TIER0_CHARS = intArrayOf(
        ' '.code, 'e'.code, 't'.code, 'a'.code, 'o'.code, 'i'.code,
        'n'.code, 's'.code, 'h'.code, 'r'.code, 'l'.code, '\n'.code
    )

    private val TIER0_MAP = HashMap<Int, Int>(16).also { map ->
        TIER0_CHARS.forEachIndexed { i, cp -> map[cp] = i }
    }

    private const val ESC_CAP    = 0xC
    private const val ESC_TIER1  = 0xD
    private const val ESC_TIER23 = 0xE
    private const val ESC_TIER4  = 0xF
    private const val CTRL_CAP   = 0x0

    // ─── Encoder ─────────────────────────────────────────────────────────────

    private fun encodeTier3(cp: Int, nib: MutableList<Int>) {
        nib += ESC_TIER23; nib += 0x8
        for (shift in 24 downTo 0 step 4) nib += (cp ushr shift) and 0xF
    }

    private fun encodeCP(cp: Int, nib: MutableList<Int>) {
        val lower = if (cp in 'A'.code..'Z'.code) cp + 32 else cp
        val isUp  = cp in 'A'.code..'Z'.code
        val t0l   = TIER0_MAP[lower] ?: -1
        val t0    = TIER0_MAP[cp]    ?: -1

        // Uppercase whose lowercase is Tier0
        if (isUp && t0l >= 0) {
            nib += ESC_CAP; nib += CTRL_CAP; nib += t0l; return
        }

        // Tier 0 direct
        if (t0 >= 0) { nib += t0; return }

        // Tier 1: 0x00–0xFF
        if (cp <= 0xFF) {
            nib += ESC_TIER1; nib += (cp ushr 4) and 0xF; nib += cp and 0xF; return
        }

        // Tier 2: 0x100–0xFFFF
        if (cp <= 0xFFFF) {
            val n3 = (cp ushr 12) and 0xF
            if (n3 <= 0x7) {
                nib += ESC_TIER23; nib += n3
                nib += (cp ushr 8) and 0xF; nib += (cp ushr 4) and 0xF; nib += cp and 0xF
            } else {
                encodeTier3(cp, nib)
            }
            return
        }

        // Tier 3: 0x10000–0xFFFFFFFF
        if (cp <= 0xFFFFFFFF.toInt()) { encodeTier3(cp, nib); return }

        // Tier 4: > 0xFFFFFFFF (up to 60-bit via Long)
        nib += ESC_TIER4
        val cpL = cp.toLong()
        for (shift in 56 downTo 0 step 4) nib += ((cpL ushr shift) and 0xFL).toInt()
    }

    /**
     * Encode a String to UTF-64 bytes.
     */
    fun encode(s: String): ByteArray {
        val nib = mutableListOf<Int>()

        // BOM
        nib += ESC_TIER1; nib += 0x0; nib += 0x2

        var i = 0
        while (i < s.length) {
            val cp = s.codePointAt(i)
            i += Character.charCount(cp)
            encodeCP(cp, nib)
        }

        // Pad to even
        if (nib.size % 2 != 0) nib += 0x0

        // Pack nibbles → bytes
        val payload = ByteArray(nib.size / 2) { j ->
            (((nib[j * 2] and 0xF) shl 4) or (nib[j * 2 + 1] and 0xF)).toByte()
        }

        return MAGIC + payload
    }

    // ─── Decoder ─────────────────────────────────────────────────────────────

    /**
     * Decode UTF-64 bytes to a String.
     */
    fun decode(buf: ByteArray): String {
        // Strip magic
        val byteOffset = if (buf.size >= MAGIC.size && buf.take(MAGIC.size).toByteArray()
                .contentEquals(MAGIC)) MAGIC.size else 0

        // Unpack bytes → nibbles
        val nib = IntArray((buf.size - byteOffset) * 2) { k ->
            val b = buf[byteOffset + k / 2].toInt() and 0xFF
            if (k % 2 == 0) (b ushr 4) and 0xF else b and 0xF
        }

        val sb = StringBuilder()
        var i = 0
        var capNext = false

        // Skip BOM
        if (nib.size >= 3 && nib[0] == ESC_TIER1 && nib[1] == 0x0 && nib[2] == 0x2) i = 3

        while (i < nib.size) {
            if (i == nib.size - 1 && nib[i] == 0x0) break // trailing pad

            when (val n = nib[i]) {
                in 0x0..0xB -> {
                    var cp = TIER0_CHARS[n]
                    if (capNext && cp in 'a'.code..'z'.code) { cp -= 32; capNext = false }
                    sb.appendCodePoint(cp); i++
                }
                ESC_CAP -> {
                    capNext = (nib[i + 1] and 0x3) == CTRL_CAP
                    i += 2
                }
                ESC_TIER1 -> {
                    if (i + 2 >= nib.size) { sb.append('\uFFFD'); i++; continue }
                    var cp = (nib[i+1] shl 4) or nib[i+2]
                    if (capNext && cp in 'a'.code..'z'.code) { cp -= 32; capNext = false }
                    sb.appendCodePoint(cp); i += 3
                }
                ESC_TIER23 -> {
                    if (i + 1 >= nib.size) { sb.append('\uFFFD'); i++; continue }
                    if (nib[i+1] <= 0x7) {
                        if (i + 4 >= nib.size) { sb.append('\uFFFD'); i++; continue }
                        val cp = (nib[i+1] shl 12) or (nib[i+2] shl 8) or (nib[i+3] shl 4) or nib[i+4]
                        if (capNext) capNext = false
                        sb.appendCodePoint(cp); i += 5
                    } else {
                        if (i + 8 >= nib.size) { sb.append('\uFFFD'); i++; continue }
                        val cp = (nib[i+2] shl 24) or (nib[i+3] shl 20) or (nib[i+4] shl 16) or
                                 (nib[i+5] shl 12) or (nib[i+6] shl 8)  or (nib[i+7] shl 4)  or nib[i+8]
                        sb.appendCodePoint(cp); i += 9
                    }
                }
                ESC_TIER4 -> {
                    if (i + 15 >= nib.size) { sb.append('\uFFFD'); i++; continue }
                    var cp = 0L
                    for (j in 1..15) cp = (cp shl 4) or nib[i+j].toLong()
                    sb.appendCodePoint(cp.toInt()); i += 16
                }
                else -> { sb.append('\uFFFD'); i++ }
            }
        }

        return sb.toString()
    }

    // ─── Utilities ───────────────────────────────────────────────────────────

    /** Encode to hex string for debugging. */
    fun encodeToHex(s: String): String =
        encode(s).joinToString(" ") { "%02x".format(it.toInt() and 0xFF) }

    /** Payload byte size excluding magic header. */
    fun payloadByteSize(s: String): Int {
        val nib = mutableListOf<Int>()
        var i = 0
        while (i < s.length) {
            val cp = s.codePointAt(i); i += Character.charCount(cp)
            encodeCP(cp, nib)
        }
        if (nib.size % 2 != 0) nib += 0
        return nib.size / 2
    }

    // ─── Test Suite ──────────────────────────────────────────────────────────

    fun runTests() {
        val tests = listOf(
            "hello"             to "lowercase hello",
            "Hello"             to "capitalized Hello",
            ""                  to "empty string",
            "the rain in spain" to "tier0-heavy sentence",
            "Hello, World!"     to "mixed ascii",
            "H\u00E9llo"        to "accented char (Tier2)",
            "\u65E5\u672C\u8A9E" to "Japanese (Tier2)",
        )

        println("UTF-64 Kotlin Test Suite")
        println("=".repeat(40))
        for ((input, desc) in tests) {
            val enc  = encode(input)
            val dec  = decode(enc)
            val pass = dec == input
            println("[${if (pass) "PASS" else "FAIL"}] $desc")
            if (!pass) {
                println("  expected: $input")
                println("  got:      $dec")
            } else {
                println("  \"$input\" → ${payloadByteSize(input)} payload bytes")
            }
            println("  hex: ${encodeToHex(input)}\n")
        }
    }
}

fun main() = UTF64.runTests()
