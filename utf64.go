package main

import (
	"fmt"
	"strings"
	"unicode"
	"unicode/utf8"
)

// ─── Constants ────────────────────────────────────────────────────────────────

var legacyMagic = []byte("&-9EX")

var tier0Chars = []rune{' ', 'e', 't', 'a', 'o', 'i', 'n', 's', 'h', 'r', 'l', '\n'}

var tier0Map map[rune]int

func init() {
	tier0Map = make(map[rune]int, len(tier0Chars))
	for i, c := range tier0Chars {
		tier0Map[c] = i
	}
}

const (
	escCap    = 0xC
	escTier1  = 0xD
	escTier23 = 0xE
	escTier4  = 0xF
	ctrlCap   = 0x0
)

// ─── Encoder ──────────────────────────────────────────────────────────────────

func encodeTier3(cp rune, nib *[]int) {
	*nib = append(*nib, escTier23, 0x8)
	for shift := 24; shift >= 0; shift -= 4 {
		*nib = append(*nib, int(cp>>shift)&0xF)
	}
}

func encodeCp(cp rune, nib *[]int) {
	char := string(cp)
	lower := strings.ToLower(char)
	isUpper := char != lower && char == strings.ToUpper(char)

	t0l, hasT0l := tier0Map[[]rune(lower)[0]]

	if isUpper && hasT0l {
		*nib = append(*nib, escCap, ctrlCap, t0l)
		return
	}

	if t0, ok := tier0Map[cp]; ok {
		*nib = append(*nib, t0)
		return
	}

	if cp <= 0xFF {
		*nib = append(*nib, escTier1, int(cp>>4)&0xF, int(cp)&0xF)
		return
	}

	if cp <= 0xFFFF {
		n3 := int(cp>>12) & 0xF
		if n3 <= 0x7 {
			*nib = append(*nib, escTier23, n3, int(cp>>8)&0xF, int(cp>>4)&0xF, int(cp)&0xF)
		} else {
			encodeTier3(cp, nib)
		}
		return
	}

	if cp <= rune(0x10FFFF) {
		encodeTier3(cp, nib)
		return
	}

	*nib = append(*nib, escTier4)
	for shift := 56; shift >= 0; shift -= 4 {
		*nib = append(*nib, int(cp>>shift)&0xF)
	}
}

func Encode(s string) []byte {
	nib := []int{}
	nib = append(nib, escTier1, 0x0, 0x2)
	for _, cp := range s {
		encodeCp(cp, &nib)
	}
	if len(nib)%2 != 0 {
		nib = append(nib, 0x0)
	}
	out := make([]byte, len(nib)/2)
	for i := 0; i < len(nib); i += 2 {
		out[i/2] = byte((nib[i]&0xF)<<4) | byte(nib[i+1]&0xF)
	}
	return out
}

// ─── Decoder ──────────────────────────────────────────────────────────────────

func Decode(buf []byte) string {
	offset := 0
	if len(buf) >= len(legacyMagic) {
		match := true
		for i, b := range legacyMagic {
			if buf[i] != b {
				match = false
				break
			}
		}
		if match {
			offset = len(legacyMagic)
		}
	}

	nib := make([]int, 0, (len(buf)-offset)*2)
	for _, b := range buf[offset:] {
		nib = append(nib, int(b>>4)&0xF, int(b)&0xF)
	}

	var result strings.Builder
	i := 0
	capNext := false

	if len(nib) >= 3 && nib[0] == escTier1 && nib[1] == 0x0 && nib[2] == 0x2 {
		i = 3
	}

	for i < len(nib) {
		if i == len(nib)-1 && nib[i] == 0x0 {
			break
		}

		n := nib[i]

		switch {
		case n <= 0xB:
			c := tier0Chars[n]
			if capNext {
				c = unicode.ToUpper(c)
				capNext = false
			}
			result.WriteRune(c)
			i++

		case n == escCap:
			ctrl := nib[i+1] & 0x3
			if ctrl == ctrlCap {
				capNext = true
			}
			i += 2

		case n == escTier1:
			if i+2 >= len(nib) {
				result.WriteRune('\uFFFD')
				i++
				continue
			}
			cp := rune((nib[i+1] << 4) | nib[i+2])
			c := string(cp)
			if capNext {
				c = strings.ToUpper(c)
				capNext = false
			}
			result.WriteString(c)
			i += 3

		case n == escTier23:
			if i+1 >= len(nib) {
				result.WriteRune('\uFFFD')
				i++
				continue
			}
			if nib[i+1] <= 0x7 {
				if i+4 >= len(nib) {
					result.WriteRune('\uFFFD')
					i++
					continue
				}
				cp := rune((nib[i+1] << 12) | (nib[i+2] << 8) | (nib[i+3] << 4) | nib[i+4])
				c := string(cp)
				if capNext {
					c = strings.ToUpper(c)
					capNext = false
				}
				result.WriteString(c)
				i += 5
			} else {
				if i+8 >= len(nib) {
					result.WriteRune('\uFFFD')
					i++
					continue
				}
				cp := rune((nib[i+2] << 24) | (nib[i+3] << 20) | (nib[i+4] << 16) |
					(nib[i+5] << 12) | (nib[i+6] << 8) | (nib[i+7] << 4) | nib[i+8])
				result.WriteRune(cp)
				i += 9
			}

		case n == escTier4:
			if i+15 >= len(nib) {
				result.WriteRune('\uFFFD')
				i++
				continue
			}
			cp := rune(0)
			for j := 1; j <= 15; j++ {
				cp = (cp << 4) | rune(nib[i+j])
			}
			result.WriteRune(cp)
			i += 16

		default:
			result.WriteRune('\uFFFD')
			i++
		}
	}

	return result.String()
}

// ─── Utilities ────────────────────────────────────────────────────────────────

func EncodeToHex(s string) string {
	b := Encode(s)
	parts := make([]string, len(b))
	for i, v := range b {
		parts[i] = fmt.Sprintf("%02x", v)
	}
	return strings.Join(parts, " ")
}

func PayloadByteSize(s string) int {
	nib := []int{}
	for _, cp := range s {
		encodeCp(cp, &nib)
	}
	if len(nib)%2 != 0 {
		nib = append(nib, 0)
	}
	return len(nib) / 2
}

// ─── Tests ────────────────────────────────────────────────────────────────────

func main() {
	_ = utf8.RuneError

	tests := []struct{ input, desc string }{
		{"hello", "lowercase hello"},
		{"Hello", "capitalized Hello"},
		{"", "empty string"},
		{"the rain in spain", "tier0-heavy sentence"},
		{"Hello, World!", "mixed ascii"},
		{"Héllo", "accented char (Tier2)"},
		{"日本語", "Japanese (Tier2)"},
	}

	fmt.Println("UTF-64 Go Test Suite")
	fmt.Println(strings.Repeat("=", 40))
	for _, tt := range tests {
		enc := Encode(tt.input)
		dec := Decode(enc)
		ok := dec == tt.input
		status := "PASS"
		if !ok {
			status = "FAIL"
		}
		fmt.Printf("[%s] %s\n", status, tt.desc)
		if !ok {
			fmt.Printf("  expected: %q\n", tt.input)
			fmt.Printf("  got:      %q\n", dec)
		} else {
			fmt.Printf("  %q → %d bytes\n", tt.input, PayloadByteSize(tt.input))
		}
		fmt.Printf("  hex: %s\n\n", EncodeToHex(tt.input))
	}
}
