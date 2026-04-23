<?php
/**
 * UTF-64 — Universal Transformation Format 64
 * Specification v0.2 — PHP Reference Implementation
 *
 * Changes from v0.1:
 *   - Magic bytes removed from encoder output.
 *     Decoder still accepts (and strips) legacy magic-prefixed streams.
 */

// ─── Constants ────────────────────────────────────────────────────────────────

const LEGACY_MAGIC = "&-9EX";
const BOM_CP       = 0x0002;

const TIER0_CHARS = [' ', 'e', 't', 'a', 'o', 'i', 'n', 's', 'h', 'r', 'l', "\n"];
const TIER0_MAP   = ['e' => 1, 't' => 2, 'a' => 3, 'o' => 4, 'i' => 5,
                     'n' => 6, 's' => 7, 'h' => 8, 'r' => 9, 'l' => 10,
                     ' ' => 0, "\n" => 11];

const ESC_CAP    = 0xC;
const ESC_TIER1  = 0xD;
const ESC_TIER23 = 0xE;
const ESC_TIER4  = 0xF;
const CTRL_CAP   = 0x0;

// ─── Encoder ──────────────────────────────────────────────────────────────────

function _encode_tier3(int $cp, array &$nib): void {
    $nib[] = ESC_TIER23;
    $nib[] = 0x8;
    for ($shift = 24; $shift >= 0; $shift -= 4) {
        $nib[] = ($cp >> $shift) & 0xF;
    }
}

function _encode_cp(int $cp, array &$nib): void {
    $char  = mb_chr($cp, 'UTF-8');
    $lower = mb_strtolower($char, 'UTF-8');
    $isUpper = $char !== $lower;
    $t0l = TIER0_MAP[$lower] ?? -1;

    if ($isUpper && $t0l >= 0) {
        $nib[] = ESC_CAP; $nib[] = CTRL_CAP; $nib[] = $t0l;
        return;
    }

    $t0 = TIER0_MAP[$char] ?? -1;
    if ($t0 >= 0) {
        $nib[] = $t0;
        return;
    }

    if ($cp <= 0xFF) {
        $nib[] = ESC_TIER1;
        $nib[] = ($cp >> 4) & 0xF;
        $nib[] = $cp & 0xF;
        return;
    }

    if ($cp <= 0xFFFF) {
        $n3 = ($cp >> 12) & 0xF;
        if ($n3 <= 0x7) {
            $nib[] = ESC_TIER23;
            $nib[] = $n3;
            $nib[] = ($cp >> 8) & 0xF;
            $nib[] = ($cp >> 4) & 0xF;
            $nib[] = $cp & 0xF;
        } else {
            _encode_tier3($cp, $nib);
        }
        return;
    }

    if ($cp <= 0xFFFFFFFF) {
        _encode_tier3($cp, $nib);
        return;
    }

    // Tier 4: > 0xFFFFFFFF
    $nib[] = ESC_TIER4;
    for ($shift = 56; $shift >= 0; $shift -= 4) {
        $nib[] = ($cp >> $shift) & 0xF;
    }
}

function utf64_encode(string $s): string {
    $nib = [];

    // BOM
    $nib[] = ESC_TIER1; $nib[] = 0x0; $nib[] = 0x2;

    // Iterate over Unicode code points
    $len = mb_strlen($s, 'UTF-8');
    for ($i = 0; $i < $len; $i++) {
        $char = mb_substr($s, $i, 1, 'UTF-8');
        $cp   = mb_ord($char, 'UTF-8');
        _encode_cp($cp, $nib);
    }

    if (count($nib) % 2 !== 0) $nib[] = 0x0;

    // Pack nibbles → bytes
    $out = '';
    for ($i = 0; $i < count($nib); $i += 2) {
        $out .= chr((($nib[$i] & 0xF) << 4) | ($nib[$i + 1] & 0xF));
    }
    return $out;
}

// ─── Decoder ──────────────────────────────────────────────────────────────────

function utf64_decode(string $buf): string {
    // Strip legacy magic if present
    $byteOffset = 0;
    if (substr($buf, 0, strlen(LEGACY_MAGIC)) === LEGACY_MAGIC) {
        $byteOffset = strlen(LEGACY_MAGIC);
    }

    // Unpack bytes → nibbles
    $nib = [];
    for ($i = $byteOffset; $i < strlen($buf); $i++) {
        $b = ord($buf[$i]);
        $nib[] = ($b >> 4) & 0xF;
        $nib[] = $b & 0xF;
    }

    $result  = '';
    $i       = 0;
    $capNext = false;
    $len     = count($nib);

    // Skip BOM
    if ($len >= 3 && $nib[0] === ESC_TIER1 && $nib[1] === 0x0 && $nib[2] === 0x2) {
        $i = 3;
    }

    while ($i < $len) {
        if ($i === $len - 1 && $nib[$i] === 0x0) break;

        $n = $nib[$i];

        if ($n <= 0xB) {
            $c = TIER0_CHARS[$n];
            if ($capNext) { $c = mb_strtoupper($c, 'UTF-8'); $capNext = false; }
            $result .= $c;
            $i++;
            continue;
        }

        if ($n === ESC_CAP) {
            $ctrl = $nib[$i + 1] & 0x3;
            if ($ctrl === CTRL_CAP) $capNext = true;
            $i += 2;
            continue;
        }

        if ($n === ESC_TIER1) {
            if ($i + 2 >= $len) { $result .= "\u{FFFD}"; $i++; continue; }
            $cp = ($nib[$i + 1] << 4) | $nib[$i + 2];
            $c  = mb_chr($cp, 'UTF-8');
            if ($capNext) { $c = mb_strtoupper($c, 'UTF-8'); $capNext = false; }
            $result .= $c;
            $i += 3;
            continue;
        }

        if ($n === ESC_TIER23) {
            if ($i + 1 >= $len) { $result .= "\u{FFFD}"; $i++; continue; }
            if ($nib[$i + 1] <= 0x7) {
                if ($i + 4 >= $len) { $result .= "\u{FFFD}"; $i++; continue; }
                $cp = ($nib[$i+1] << 12) | ($nib[$i+2] << 8) | ($nib[$i+3] << 4) | $nib[$i+4];
                $c  = mb_chr($cp, 'UTF-8');
                if ($capNext) { $c = mb_strtoupper($c, 'UTF-8'); $capNext = false; }
                $result .= $c;
                $i += 5;
            } else {
                if ($i + 8 >= $len) { $result .= "\u{FFFD}"; $i++; continue; }
                $cp = ($nib[$i+2] << 24) | ($nib[$i+3] << 20) | ($nib[$i+4] << 16)
                    | ($nib[$i+5] << 12) | ($nib[$i+6] << 8)  | ($nib[$i+7] << 4)
                    |  $nib[$i+8];
                $result .= mb_chr($cp, 'UTF-8');
                $i += 9;
            }
            continue;
        }

        if ($n === ESC_TIER4) {
            if ($i + 15 >= $len) { $result .= "\u{FFFD}"; $i++; continue; }
            $cp = 0;
            for ($j = 1; $j <= 15; $j++) $cp = ($cp << 4) | $nib[$i + $j];
            $result .= mb_chr($cp, 'UTF-8');
            $i += 16;
            continue;
        }

        $result .= "\u{FFFD}";
        $i++;
    }

    return $result;
}

// ─── Utilities ────────────────────────────────────────────────────────────────

function utf64_encode_to_hex(string $s): string {
    return implode(' ', array_map(fn($b) => sprintf('%02x', ord($b)), str_split(utf64_encode($s))));
}

function utf64_payload_byte_size(string $s): int {
    $nib = [];
    $len = mb_strlen($s, 'UTF-8');
    for ($i = 0; $i < $len; $i++) {
        $cp = mb_ord(mb_substr($s, $i, 1, 'UTF-8'), 'UTF-8');
        _encode_cp($cp, $nib);
    }
    if (count($nib) % 2 !== 0) $nib[] = 0;
    return count($nib) / 2;
}

// ─── Test Suite ───────────────────────────────────────────────────────────────

function run_tests(): void {
    $tests = [
        ['hello',             'lowercase hello'],
        ['Hello',             'capitalized Hello'],
        ['',                  'empty string'],
        ['the rain in spain', 'tier0-heavy sentence'],
        ['Hello, World!',     'mixed ascii'],
        ['Héllo',             'accented char (Tier2)'],
        ['日本語',             'Japanese (Tier2)'],
    ];

    echo "UTF-64 PHP Test Suite\n" . str_repeat('=', 40) . "\n";
    foreach ($tests as [$input, $desc]) {
        $enc  = utf64_encode($input);
        $dec  = utf64_decode($enc);
        $ok   = $dec === $input;
        $hex  = implode(' ', array_map(fn($b) => sprintf('%02x', ord($b)), str_split($enc) ?: []));
        echo '[' . ($ok ? 'PASS' : 'FAIL') . '] ' . $desc . "\n";
        if (!$ok) {
            echo "  expected: " . json_encode($input) . "\n";
            echo "  got:      " . json_encode($dec) . "\n";
        } else {
            echo "  " . json_encode($input) . " → " . utf64_payload_byte_size($input) . " bytes\n";
        }
        echo "  hex: $hex\n\n";
    }
}

run_tests();
