;;
;; UTF-64 — Universal Transformation Format 64
;; Specification v0.1 — WAT Reference Implementation
;;
;; Memory layout (linear memory, 1 page = 64 KiB):
;;   0x0000–0x000B  TIER0_CHARS (12 bytes, ASCII)
;;   0x0010–0x0014  MAGIC bytes (5 bytes: "&-9EX")
;;   0x0100–0x3FFF  nibble scratch buffer (up to ~16 KB)
;;   0x4000–0x7FFF  output byte buffer    (up to 16 KB)
;;   0x8000–0xBFFF  input string buffer   (up to 16 KB)
;;   0xC000–0xFFFF  decode output buffer  (up to 16 KB)
;;
;; Exported functions:
;;   encode(str_ptr, str_len) -> (out_ptr, out_len)   [returns i32 pair via memory]
;;   decode(buf_ptr, buf_len) -> (out_ptr, out_len)   [returns i32 pair via memory]
;;   result_ptr() -> i32   pointer to [out_ptr: i32, out_len: i32] pair
;;
;; For JS interop: write input to 0x8000, call encode/decode,
;; read result_ptr() to get [ptr, len] of output.
;;

(module
  (memory (export "mem") 1)

  ;; ── Static data ─────────────────────────────────────────────────────────────
  ;; TIER0_CHARS at 0x0000
  (data (i32.const 0x0000) " etaoinshr l\n")
  ;;                         0123456789AB
  ;; (note: index 0xA = 'l', 0xB = '\n')

  ;; MAGIC at 0x0010
  (data (i32.const 0x0010) "&-9EX")

  ;; Result pair [ptr: i32, len: i32] stored at 0x0020
  ;; (written by encode/decode before returning)

  ;; ── Constants ────────────────────────────────────────────────────────────────
  ;; ESC_CAP    = 0xC
  ;; ESC_TIER1  = 0xD
  ;; ESC_TIER23 = 0xE
  ;; ESC_TIER4  = 0xF
  ;; NIB_BUF    = 0x0100
  ;; OUT_BUF    = 0x4000
  ;; IN_BUF     = 0x8000
  ;; DEC_BUF    = 0xC000
  ;; MAGIC_LEN  = 5

  ;; ── Globals (mutable) ────────────────────────────────────────────────────────
  (global $nib_len (mut i32) (i32.const 0))
  (global $out_len (mut i32) (i32.const 0))

  ;; ── result_ptr ───────────────────────────────────────────────────────────────
  (func (export "result_ptr") (result i32)
    i32.const 0x0020
  )

  ;; ── tier0_index: (cp: i32) -> i32  (-1 if not found) ────────────────────────
  (func $tier0_index (param $cp i32) (result i32)
    (local $i i32)
    (local.set $i (i32.const 0))
    (block $break
      (loop $loop
        (br_if $break (i32.ge_u (local.get $i) (i32.const 12)))
        (if (i32.eq
              (i32.load8_u (i32.add (i32.const 0x0000) (local.get $i)))
              (local.get $cp))
          (then
            (return (local.get $i))
          )
        )
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)
      )
    )
    i32.const -1
  )

  ;; ── nib_push: push one nibble to scratch buffer ───────────────────────────
  (func $nib_push (param $v i32)
    (i32.store8
      (i32.add (i32.const 0x0100) (global.get $nib_len))
      (i32.and (local.get $v) (i32.const 0xF))
    )
    (global.set $nib_len (i32.add (global.get $nib_len) (i32.const 1)))
  )

  ;; ── nib_get: get nibble at index i ───────────────────────────────────────
  (func $nib_get (param $i i32) (result i32)
    (i32.load8_u (i32.add (i32.const 0x0100) (local.get $i)))
  )

  ;; ── encode_tier3 ──────────────────────────────────────────────────────────
  (func $encode_tier3 (param $cp i32)
    (call $nib_push (i32.const 0xE)) ;; ESC_TIER23
    (call $nib_push (i32.const 0x8))
    ;; 7 nibbles: shifts 24,20,16,12,8,4,0
    (call $nib_push (i32.and (i32.shr_u (local.get $cp) (i32.const 24)) (i32.const 0xF)))
    (call $nib_push (i32.and (i32.shr_u (local.get $cp) (i32.const 20)) (i32.const 0xF)))
    (call $nib_push (i32.and (i32.shr_u (local.get $cp) (i32.const 16)) (i32.const 0xF)))
    (call $nib_push (i32.and (i32.shr_u (local.get $cp) (i32.const 12)) (i32.const 0xF)))
    (call $nib_push (i32.and (i32.shr_u (local.get $cp) (i32.const 8))  (i32.const 0xF)))
    (call $nib_push (i32.and (i32.shr_u (local.get $cp) (i32.const 4))  (i32.const 0xF)))
    (call $nib_push (i32.and                             (local.get $cp) (i32.const 0xF)))
  )

  ;; ── encode_cp: encode one code point → nibbles ────────────────────────────
  (func $encode_cp (param $cp i32)
    (local $lower i32)
    (local $is_upper i32)
    (local $t0 i32)
    (local $t0l i32)
    (local $n3 i32)

    ;; Crude lowercase for ASCII A-Z only
    (local.set $is_upper
      (i32.and
        (i32.ge_u (local.get $cp) (i32.const 65))   ;; 'A'
        (i32.le_u (local.get $cp) (i32.const 90))   ;; 'Z'
      )
    )
    (if (local.get $is_upper)
      (then (local.set $lower (i32.add (local.get $cp) (i32.const 32))))
      (else (local.set $lower (local.get $cp)))
    )

    (local.set $t0  (call $tier0_index (local.get $cp)))
    (local.set $t0l (call $tier0_index (local.get $lower)))

    ;; Uppercase whose lowercase is Tier0
    (if (i32.and (local.get $is_upper) (i32.ne (local.get $t0l) (i32.const -1)))
      (then
        (call $nib_push (i32.const 0xC)) ;; ESC_CAP
        (call $nib_push (i32.const 0x0)) ;; CTRL_CAP
        (call $nib_push (local.get $t0l))
        (return)
      )
    )

    ;; Tier 0 direct
    (if (i32.ne (local.get $t0) (i32.const -1))
      (then
        (call $nib_push (local.get $t0))
        (return)
      )
    )

    ;; Tier 1: 0x00–0xFF
    (if (i32.le_u (local.get $cp) (i32.const 0xFF))
      (then
        (call $nib_push (i32.const 0xD)) ;; ESC_TIER1
        (call $nib_push (i32.and (i32.shr_u (local.get $cp) (i32.const 4)) (i32.const 0xF)))
        (call $nib_push (i32.and                             (local.get $cp) (i32.const 0xF)))
        (return)
      )
    )

    ;; Tier 2: 0x100–0xFFFF
    (if (i32.le_u (local.get $cp) (i32.const 0xFFFF))
      (then
        (local.set $n3 (i32.and (i32.shr_u (local.get $cp) (i32.const 12)) (i32.const 0xF)))
        (if (i32.le_u (local.get $n3) (i32.const 7))
          (then
            (call $nib_push (i32.const 0xE)) ;; ESC_TIER23
            (call $nib_push (local.get $n3))
            (call $nib_push (i32.and (i32.shr_u (local.get $cp) (i32.const 8))  (i32.const 0xF)))
            (call $nib_push (i32.and (i32.shr_u (local.get $cp) (i32.const 4))  (i32.const 0xF)))
            (call $nib_push (i32.and                             (local.get $cp) (i32.const 0xF)))
          )
          (else
            (call $encode_tier3 (local.get $cp))
          )
        )
        (return)
      )
    )

    ;; Tier 3: 0x10000–0xFFFFFFFF
    (call $encode_tier3 (local.get $cp))
    ;; (Tier 4 omitted — WAT i32 can't exceed 0xFFFFFFFF; use i64 extension for Tier 4)
  )

  ;; ── utf8_next: decode one UTF-8 code point from memory ──────────────────
  ;; (param $ptr i32, $end i32) -> (cp: i32, new_ptr: i32)
  (func $utf8_next (param $ptr i32) (param $end i32) (result i32 i32)
    (local $b0 i32)
    (local $cp i32)
    (local $extra i32)
    (local $i i32)

    (local.set $b0 (i32.load8_u (local.get $ptr)))
    (local.set $ptr (i32.add (local.get $ptr) (i32.const 1)))

    ;; ASCII
    (if (i32.lt_u (local.get $b0) (i32.const 0x80))
      (then (return (local.get $b0) (local.get $ptr)))
    )

    ;; 2-byte
    (if (i32.eq (i32.and (local.get $b0) (i32.const 0xE0)) (i32.const 0xC0))
      (then
        (local.set $cp (i32.and (local.get $b0) (i32.const 0x1F)))
        (local.set $extra (i32.const 1))
      )
    )
    ;; 3-byte
    (if (i32.eq (i32.and (local.get $b0) (i32.const 0xF0)) (i32.const 0xE0))
      (then
        (local.set $cp (i32.and (local.get $b0) (i32.const 0x0F)))
        (local.set $extra (i32.const 2))
      )
    )
    ;; 4-byte
    (if (i32.eq (i32.and (local.get $b0) (i32.const 0xF8)) (i32.const 0xF0))
      (then
        (local.set $cp (i32.and (local.get $b0) (i32.const 0x07)))
        (local.set $extra (i32.const 3))
      )
    )

    (local.set $i (i32.const 0))
    (block $break
      (loop $loop
        (br_if $break (i32.ge_u (local.get $i) (local.get $extra)))
        (br_if $break (i32.ge_u (local.get $ptr) (local.get $end)))
        (local.set $cp
          (i32.or
            (i32.shl (local.get $cp) (i32.const 6))
            (i32.and (i32.load8_u (local.get $ptr)) (i32.const 0x3F))
          )
        )
        (local.set $ptr (i32.add (local.get $ptr) (i32.const 1)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)
      )
    )

    (local.get $cp)
    (local.get $ptr)
  )

  ;; ── cp_to_utf8: write code point as UTF-8, return bytes written ──────────
  (func $cp_to_utf8 (param $cp i32) (param $dst i32) (result i32)
    (if (i32.lt_u (local.get $cp) (i32.const 0x80))
      (then
        (i32.store8 (local.get $dst) (local.get $cp))
        (return (i32.const 1))
      )
    )
    (if (i32.lt_u (local.get $cp) (i32.const 0x800))
      (then
        (i32.store8 (local.get $dst)
          (i32.or (i32.const 0xC0) (i32.shr_u (local.get $cp) (i32.const 6))))
        (i32.store8 (i32.add (local.get $dst) (i32.const 1))
          (i32.or (i32.const 0x80) (i32.and (local.get $cp) (i32.const 0x3F))))
        (return (i32.const 2))
      )
    )
    (if (i32.lt_u (local.get $cp) (i32.const 0x10000))
      (then
        (i32.store8 (local.get $dst)
          (i32.or (i32.const 0xE0) (i32.shr_u (local.get $cp) (i32.const 12))))
        (i32.store8 (i32.add (local.get $dst) (i32.const 1))
          (i32.or (i32.const 0x80) (i32.and (i32.shr_u (local.get $cp) (i32.const 6)) (i32.const 0x3F))))
        (i32.store8 (i32.add (local.get $dst) (i32.const 2))
          (i32.or (i32.const 0x80) (i32.and (local.get $cp) (i32.const 0x3F))))
        (return (i32.const 3))
      )
    )
    ;; 4-byte
    (i32.store8 (local.get $dst)
      (i32.or (i32.const 0xF0) (i32.shr_u (local.get $cp) (i32.const 18))))
    (i32.store8 (i32.add (local.get $dst) (i32.const 1))
      (i32.or (i32.const 0x80) (i32.and (i32.shr_u (local.get $cp) (i32.const 12)) (i32.const 0x3F))))
    (i32.store8 (i32.add (local.get $dst) (i32.const 2))
      (i32.or (i32.const 0x80) (i32.and (i32.shr_u (local.get $cp) (i32.const 6)) (i32.const 0x3F))))
    (i32.store8 (i32.add (local.get $dst) (i32.const 3))
      (i32.or (i32.const 0x80) (i32.and (local.get $cp) (i32.const 0x3F))))
    i32.const 4
  )

  ;; ── encode: (str_ptr: i32, str_len: i32) -> void  (result at 0x0020) ────
  (func (export "encode") (param $str_ptr i32) (param $str_len i32)
    (local $ptr i32)
    (local $end i32)
    (local $cp i32)
    (local $new_ptr i32)
    (local $i i32)
    (local $out_ptr i32)
    (local $total i32)

    ;; Reset nibble buffer
    (global.set $nib_len (i32.const 0))

    ;; BOM: [0xD][0x0][0x2]
    (call $nib_push (i32.const 0xD))
    (call $nib_push (i32.const 0x0))
    (call $nib_push (i32.const 0x2))

    ;; Encode each code point
    (local.set $ptr (local.get $str_ptr))
    (local.set $end (i32.add (local.get $str_ptr) (local.get $str_len)))
    (block $break
      (loop $loop
        (br_if $break (i32.ge_u (local.get $ptr) (local.get $end)))
        (call $utf8_next (local.get $ptr) (local.get $end))
        (local.set $new_ptr)
        (local.set $cp)
        (call $encode_cp (local.get $cp))
        (local.set $ptr (local.get $new_ptr))
        (br $loop)
      )
    )

    ;; Pad to even
    (if (i32.rem_u (global.get $nib_len) (i32.const 2))
      (then (call $nib_push (i32.const 0x0)))
    )

    ;; Write MAGIC to OUT_BUF
    (memory.copy (i32.const 0x4000) (i32.const 0x0010) (i32.const 5))

    ;; Pack nibbles → bytes at OUT_BUF + 5
    (local.set $out_ptr (i32.const 0x4005))
    (local.set $i (i32.const 0))
    (block $break2
      (loop $loop2
        (br_if $break2 (i32.ge_u (local.get $i) (global.get $nib_len)))
        (i32.store8
          (local.get $out_ptr)
          (i32.or
            (i32.shl (call $nib_get (local.get $i)) (i32.const 4))
            (call $nib_get (i32.add (local.get $i) (i32.const 1)))
          )
        )
        (local.set $out_ptr (i32.add (local.get $out_ptr) (i32.const 1)))
        (local.set $i (i32.add (local.get $i) (i32.const 2)))
        (br $loop2)
      )
    )

    ;; Store result pair at 0x0020: [ptr=0x4000, len=total]
    (local.set $total (i32.add (i32.const 5) (i32.div_u (global.get $nib_len) (i32.const 2))))
    (i32.store (i32.const 0x0020) (i32.const 0x4000))
    (i32.store (i32.const 0x0024) (local.get $total))
  )

  ;; ── decode: (buf_ptr: i32, buf_len: i32) -> void  (result at 0x0020) ────
  (func (export "decode") (param $buf_ptr i32) (param $buf_len i32)
    (local $byte_offset i32)
    (local $nib_ptr i32)  ;; start of nibble array in linear memory
    (local $nb i32)       ;; nibble count
    (local $i i32)
    (local $b i32)
    (local $n i32)
    (local $cp i32)
    (local $out i32)
    (local $cap_next i32)
    (local $w i32)
    (local $ctrl i32)

    ;; Check magic
    (local.set $byte_offset (i32.const 0))
    (if (i32.ge_u (local.get $buf_len) (i32.const 5))
      (then
        (if (i32.and
              (i32.and
                (i32.eq (i32.load8_u (local.get $buf_ptr))                    (i32.const 38))  ;; '&'
                (i32.eq (i32.load8_u (i32.add (local.get $buf_ptr) (i32.const 1))) (i32.const 45))  ;; '-'
              )
              (i32.and
                (i32.eq (i32.load8_u (i32.add (local.get $buf_ptr) (i32.const 2))) (i32.const 57))  ;; '9'
                (i32.and
                  (i32.eq (i32.load8_u (i32.add (local.get $buf_ptr) (i32.const 3))) (i32.const 69))  ;; 'E'
                  (i32.eq (i32.load8_u (i32.add (local.get $buf_ptr) (i32.const 4))) (i32.const 88))  ;; 'X'
                )
              )
            )
          (then (local.set $byte_offset (i32.const 5)))
        )
      )
    )

    ;; Unpack bytes → nibbles into scratch buffer
    (global.set $nib_len (i32.const 0))
    (local.set $i (local.get $byte_offset))
    (block $break
      (loop $loop
        (br_if $break (i32.ge_u (local.get $i) (local.get $buf_len)))
        (local.set $b (i32.load8_u (i32.add (local.get $buf_ptr) (local.get $i))))
        (call $nib_push (i32.shr_u (local.get $b) (i32.const 4)))
        (call $nib_push (i32.and (local.get $b) (i32.const 0xF)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)
      )
    )
    (local.set $nb (global.get $nib_len))

    (local.set $out (i32.const 0xC000))
    (local.set $i (i32.const 0))
    (local.set $cap_next (i32.const 0))

    ;; Skip BOM
    (if (i32.and
          (i32.ge_u (local.get $nb) (i32.const 3))
          (i32.and
            (i32.eq (call $nib_get (i32.const 0)) (i32.const 0xD))
            (i32.and
              (i32.eq (call $nib_get (i32.const 1)) (i32.const 0x0))
              (i32.eq (call $nib_get (i32.const 2)) (i32.const 0x2))
            )
          )
        )
      (then (local.set $i (i32.const 3)))
    )

    (block $done
      (loop $main
        (br_if $done (i32.ge_u (local.get $i) (local.get $nb)))

        ;; Trailing pad check
        (if (i32.and
              (i32.eq (local.get $i) (i32.sub (local.get $nb) (i32.const 1)))
              (i32.eq (call $nib_get (local.get $i)) (i32.const 0))
            )
          (then (br $done))
        )

        (local.set $n (call $nib_get (local.get $i)))

        ;; Tier 0
        (if (i32.le_u (local.get $n) (i32.const 0xB))
          (then
            (local.set $cp (i32.load8_u (i32.add (i32.const 0x0000) (local.get $n))))
            (if (i32.and (local.get $cap_next) (i32.and (i32.ge_u (local.get $cp) (i32.const 97)) (i32.le_u (local.get $cp) (i32.const 122))))
              (then
                (local.set $cp (i32.sub (local.get $cp) (i32.const 32)))
                (local.set $cap_next (i32.const 0))
              )
            )
            (i32.store8 (local.get $out) (local.get $cp))
            (local.set $out (i32.add (local.get $out) (i32.const 1)))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $main)
          )
        )

        ;; ESC_CAP = 0xC
        (if (i32.eq (local.get $n) (i32.const 0xC))
          (then
            (local.set $ctrl (i32.and (call $nib_get (i32.add (local.get $i) (i32.const 1))) (i32.const 0x3)))
            (if (i32.eqz (local.get $ctrl))
              (then (local.set $cap_next (i32.const 1)))
            )
            (local.set $i (i32.add (local.get $i) (i32.const 2)))
            (br $main)
          )
        )

        ;; ESC_TIER1 = 0xD
        (if (i32.eq (local.get $n) (i32.const 0xD))
          (then
            (local.set $cp
              (i32.or
                (i32.shl (call $nib_get (i32.add (local.get $i) (i32.const 1))) (i32.const 4))
                (call $nib_get (i32.add (local.get $i) (i32.const 2)))
              )
            )
            (if (i32.and (local.get $cap_next) (i32.and (i32.ge_u (local.get $cp) (i32.const 97)) (i32.le_u (local.get $cp) (i32.const 122))))
              (then
                (local.set $cp (i32.sub (local.get $cp) (i32.const 32)))
                (local.set $cap_next (i32.const 0))
              )
            )
            (local.set $w (call $cp_to_utf8 (local.get $cp) (local.get $out)))
            (local.set $out (i32.add (local.get $out) (local.get $w)))
            (local.set $i (i32.add (local.get $i) (i32.const 3)))
            (br $main)
          )
        )

        ;; ESC_TIER23 = 0xE
        (if (i32.eq (local.get $n) (i32.const 0xE))
          (then
            (if (i32.le_u (call $nib_get (i32.add (local.get $i) (i32.const 1))) (i32.const 7))
              (then
                ;; Tier 2
                (local.set $cp
                  (i32.or
                    (i32.or
                      (i32.shl (call $nib_get (i32.add (local.get $i) (i32.const 1))) (i32.const 12))
                      (i32.shl (call $nib_get (i32.add (local.get $i) (i32.const 2))) (i32.const 8))
                    )
                    (i32.or
                      (i32.shl (call $nib_get (i32.add (local.get $i) (i32.const 3))) (i32.const 4))
                      (call $nib_get (i32.add (local.get $i) (i32.const 4)))
                    )
                  )
                )
                (local.set $w (call $cp_to_utf8 (local.get $cp) (local.get $out)))
                (local.set $out (i32.add (local.get $out) (local.get $w)))
                (local.set $i (i32.add (local.get $i) (i32.const 5)))
              )
              (else
                ;; Tier 3
                (local.set $cp
                  (i32.or
                    (i32.or
                      (i32.or
                        (i32.shl (call $nib_get (i32.add (local.get $i) (i32.const 2))) (i32.const 24))
                        (i32.shl (call $nib_get (i32.add (local.get $i) (i32.const 3))) (i32.const 20))
                      )
                      (i32.or
                        (i32.shl (call $nib_get (i32.add (local.get $i) (i32.const 4))) (i32.const 16))
                        (i32.shl (call $nib_get (i32.add (local.get $i) (i32.const 5))) (i32.const 12))
                      )
                    )
                    (i32.or
                      (i32.or
                        (i32.shl (call $nib_get (i32.add (local.get $i) (i32.const 6))) (i32.const 8))
                        (i32.shl (call $nib_get (i32.add (local.get $i) (i32.const 7))) (i32.const 4))
                      )
                      (call $nib_get (i32.add (local.get $i) (i32.const 8)))
                    )
                  )
                )
                (local.set $w (call $cp_to_utf8 (local.get $cp) (local.get $out)))
                (local.set $out (i32.add (local.get $out) (local.get $w)))
                (local.set $i (i32.add (local.get $i) (i32.const 9)))
              )
            )
            (br $main)
          )
        )

        ;; Unknown / ESC_TIER4 (0xF) — write U+FFFD (0xEF 0xBF 0xBD)
        (i32.store8 (local.get $out)                    (i32.const 0xEF))
        (i32.store8 (i32.add (local.get $out) (i32.const 1)) (i32.const 0xBF))
        (i32.store8 (i32.add (local.get $out) (i32.const 2)) (i32.const 0xBD))
        (local.set $out (i32.add (local.get $out) (i32.const 3)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $main)
      )
    )

    ;; Null terminate
    (i32.store8 (local.get $out) (i32.const 0))

    ;; Store result pair at 0x0020
    (i32.store (i32.const 0x0020) (i32.const 0xC000))
    (i32.store (i32.const 0x0024) (i32.sub (local.get $out) (i32.const 0xC000)))
  )
)
