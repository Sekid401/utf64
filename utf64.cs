/*!
 * UTF-64 — Universal Transformation Format 64
 * Specification v0.2 — C# Reference Implementation
 *
 * Changes from v0.1:
 *   - Magic bytes removed from encoder output.
 *     Decoder still accepts (and strips) legacy magic-prefixed streams.
 */

using System;
using System.Collections.Generic;
using System.Text;

public static class Utf64
{
    // ─── Constants ────────────────────────────────────────────────────────────

    private static readonly byte[] LegacyMagic = Encoding.ASCII.GetBytes("&-9EX");

    private static readonly char[] Tier0Chars =
        { ' ', 'e', 't', 'a', 'o', 'i', 'n', 's', 'h', 'r', 'l', '\n' };

    private static readonly Dictionary<char, int> Tier0Map = new();

    private const byte EscCap    = 0xC;
    private const byte EscTier1  = 0xD;
    private const byte EscTier23 = 0xE;
    private const byte EscTier4  = 0xF;
    private const byte CtrlCap   = 0x0;

    static Utf64()
    {
        for (int i = 0; i < Tier0Chars.Length; i++)
            Tier0Map[Tier0Chars[i]] = i;
    }

    // ─── Encoder ──────────────────────────────────────────────────────────────

    private static void EncodeTier3(uint cp, List<byte> nib)
    {
        nib.Add(EscTier23);
        nib.Add(0x8);
        for (int shift = 24; shift >= 0; shift -= 4)
            nib.Add((byte)((cp >> shift) & 0xF));
    }

    private static void EncodeCP(uint cp, List<byte> nib)
    {
        string chars  = char.ConvertFromUtf32((int)cp);
        string lower  = chars.ToLowerInvariant();
        bool isUpper  = chars != lower;
        char lowerCh  = lower[0];
        int t0l       = Tier0Map.TryGetValue(lowerCh, out int v0) ? v0 : -1;

        if (isUpper && t0l >= 0)
        {
            nib.Add(EscCap); nib.Add(CtrlCap); nib.Add((byte)t0l);
            return;
        }

        char ch = chars[0];
        if (Tier0Map.TryGetValue(ch, out int t0))
        {
            nib.Add((byte)t0);
            return;
        }

        if (cp <= 0xFF)
        {
            nib.Add(EscTier1);
            nib.Add((byte)((cp >> 4) & 0xF));
            nib.Add((byte)(cp & 0xF));
            return;
        }

        if (cp <= 0xFFFF)
        {
            byte n3 = (byte)((cp >> 12) & 0xF);
            if (n3 <= 0x7)
            {
                nib.Add(EscTier23);
                nib.Add(n3);
                nib.Add((byte)((cp >> 8) & 0xF));
                nib.Add((byte)((cp >> 4) & 0xF));
                nib.Add((byte)(cp & 0xF));
            }
            else
            {
                EncodeTier3(cp, nib);
            }
            return;
        }

        if (cp <= 0xFFFFFFFF)
        {
            EncodeTier3(cp, nib);
            return;
        }

        // Tier 4
        nib.Add(EscTier4);
        for (int shift = 56; shift >= 0; shift -= 4)
            nib.Add((byte)((cp >> shift) & 0xF));
    }

    public static byte[] Encode(string s)
    {
        var nib = new List<byte>();

        // BOM
        nib.Add(EscTier1); nib.Add(0x0); nib.Add(0x2);

        for (int i = 0; i < s.Length; )
        {
            int cp = char.ConvertToUtf32(s, i);
            i += char.IsHighSurrogate(s[i]) ? 2 : 1;
            EncodeCP((uint)cp, nib);
        }

        if (nib.Count % 2 != 0) nib.Add(0x0);

        // Pack nibbles → bytes
        var bytes = new byte[nib.Count / 2];
        for (int i = 0; i < nib.Count; i += 2)
            bytes[i / 2] = (byte)(((nib[i] & 0xF) << 4) | (nib[i + 1] & 0xF));

        return bytes;
    }

    // ─── Decoder ──────────────────────────────────────────────────────────────

    public static string Decode(byte[] buf)
    {
        // Strip legacy magic if present
        int byteOffset = 0;
        if (buf.Length >= LegacyMagic.Length)
        {
            bool hasMagic = true;
            for (int k = 0; k < LegacyMagic.Length && hasMagic; k++)
                if (buf[k] != LegacyMagic[k]) hasMagic = false;
            if (hasMagic) byteOffset = LegacyMagic.Length;
        }

        // Unpack bytes → nibbles
        var nib = new List<byte>();
        for (int k = byteOffset; k < buf.Length; k++)
        {
            nib.Add((byte)((buf[k] >> 4) & 0xF));
            nib.Add((byte)(buf[k] & 0xF));
        }

        var sb      = new StringBuilder();
        int i       = 0;
        bool capNext = false;
        int len     = nib.Count;

        // Skip BOM
        if (len >= 3 && nib[0] == EscTier1 && nib[1] == 0x0 && nib[2] == 0x2) i = 3;

        void AppendCP(uint cp, ref bool cap)
        {
            string s = char.ConvertFromUtf32((int)cp);
            if (cap) { s = s.ToUpperInvariant(); cap = false; }
            sb.Append(s);
        }

        while (i < len)
        {
            if (i == len - 1 && nib[i] == 0x0) break;
            byte n = nib[i];

            if (n <= 0xB)
            {
                string c = Tier0Chars[n].ToString();
                if (capNext) { c = c.ToUpperInvariant(); capNext = false; }
                sb.Append(c);
                i++; continue;
            }

            if (n == EscCap)
            {
                byte ctrl = (byte)(nib[i + 1] & 0x3);
                if (ctrl == CtrlCap) capNext = true;
                i += 2; continue;
            }

            if (n == EscTier1)
            {
                if (i + 2 >= len) { sb.Append('\uFFFD'); i++; continue; }
                uint cp = ((uint)nib[i+1] << 4) | nib[i+2];
                AppendCP(cp, ref capNext);
                i += 3; continue;
            }

            if (n == EscTier23)
            {
                if (i + 1 >= len) { sb.Append('\uFFFD'); i++; continue; }
                if (nib[i+1] <= 0x7)
                {
                    if (i + 4 >= len) { sb.Append('\uFFFD'); i++; continue; }
                    uint cp = ((uint)nib[i+1] << 12) | ((uint)nib[i+2] << 8)
                            | ((uint)nib[i+3] << 4)  |  nib[i+4];
                    AppendCP(cp, ref capNext);
                    i += 5;
                }
                else
                {
                    if (i + 8 >= len) { sb.Append('\uFFFD'); i++; continue; }
                    uint cp = ((uint)nib[i+2] << 24) | ((uint)nib[i+3] << 20)
                            | ((uint)nib[i+4] << 16) | ((uint)nib[i+5] << 12)
                            | ((uint)nib[i+6] << 8)  | ((uint)nib[i+7] << 4)
                            |  nib[i+8];
                    AppendCP(cp, ref capNext);
                    i += 9;
                }
                continue;
            }

            if (n == EscTier4)
            {
                if (i + 15 >= len) { sb.Append('\uFFFD'); i++; continue; }
                ulong cp = 0;
                for (int j = 1; j <= 15; j++) cp = (cp << 4) | nib[i + j];
                AppendCP((uint)cp, ref capNext);
                i += 16; continue;
            }

            sb.Append('\uFFFD');
            i++;
        }

        return sb.ToString();
    }

    // ─── Utilities ────────────────────────────────────────────────────────────

    public static string EncodeToHex(string s)
    {
        var bytes = Encode(s);
        return string.Join(" ", Array.ConvertAll(bytes, b => b.ToString("x2")));
    }

    public static int PayloadByteSize(string s)
    {
        var nib = new List<byte>();
        for (int i = 0; i < s.Length; )
        {
            int cp = char.ConvertToUtf32(s, i);
            i += char.IsHighSurrogate(s[i]) ? 2 : 1;
            EncodeCP((uint)cp, nib);
        }
        if (nib.Count % 2 != 0) nib.Add(0);
        return nib.Count / 2;
    }

    // ─── Test Suite ───────────────────────────────────────────────────────────

    public static void RunTests()
    {
        var tests = new (string input, string desc)[]
        {
            ("hello",             "lowercase hello"),
            ("Hello",             "capitalized Hello"),
            ("",                  "empty string"),
            ("the rain in spain", "tier0-heavy sentence"),
            ("Hello, World!",     "mixed ascii"),
            ("Héllo",             "accented char (Tier2)"),
            ("日本語",             "Japanese (Tier2)"),
        };

        Console.OutputEncoding = Encoding.UTF8;
        Console.WriteLine("UTF-64 C# Test Suite");
        Console.WriteLine(new string('=', 40));

        foreach (var (input, desc) in tests)
        {
            byte[] enc = Encode(input);
            string dec = Decode(enc);
            bool ok    = dec == input;
            string hex = string.Join(" ", Array.ConvertAll(enc, b => b.ToString("x2")));

            Console.WriteLine($"[{(ok ? "PASS" : "FAIL")}] {desc}");
            if (!ok)
            {
                Console.WriteLine($"  expected: {input}");
                Console.WriteLine($"  got:      {dec}");
            }
            else
            {
                Console.WriteLine($"  \"{input}\" → {PayloadByteSize(input)} bytes");
            }
            Console.WriteLine($"  hex: {hex}\n");
        }
    }
}

class Utf64Runner
{
    static void Main() => Utf64.RunTests();
}
