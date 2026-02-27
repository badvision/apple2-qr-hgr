; format.asm — Write format info and version info to QR matrix
; Format info: 15 bits written to two reserved regions.
; Version info: 18 bits for versions 7-40, written to two 3×6 regions.
; Both assume HGR page is already drawn with function patterns.

; ── FORMAT_INFO ──────────────────────────────────────────────────
; Write 15-bit format information for EC level L and the current mask
; to both format info regions.
;
; Fixed mask = 0 (index into FMT_INFO_L table).
; ZP_MASK_PATTERN ZP location holds mask index if caller wants to override;
; For simplicity we use mask 0 directly here.
;
; Format info placement (QR spec ISO 18004, verified against segno+ZXing):
;   FMT_INFO_L stores the final format word (BCH XOR'd with 0x5412).
;   Shift register emits MSB (bit14) first; tables/code map each step to spec position.
;   Region 1 (near top-left finder):
;     Bit 14 → (8,0), Bit 13 → (8,1), ..., Bit 8 → (8,7) [skip col 6 timing]
;     Bit  7 → (8,8), Bit  6 → (7,8), ..., Bit 0 → (0,8) [skip row 6 timing]
;   Region 2 (near bottom-left + top-right finders):
;     Bit 14 → (SIZE-1,8), ..., Bit 8 → (SIZE-7,8)  [bottom-left, descending row]
;     Bit  7 → (8,SIZE-8), ..., Bit 0 → (8,SIZE-1)  [top-right, ascending col]
;     (dark module at (4*VER+9,8) is separate, not part of format info)
;
; Input:  ZP_SIZE, ZP_VER set; HGR page initialized with function patterns
; Clobbers: A, X, Y, ZP_ROW, ZP_COL, ZP_TMP, ZP_TMP2, ZP_BITPOS, ZP_CBIT

FORMAT_INFO:
        ; Load format word for L level, mask 0:
        LDA     FMT_INFO_L      ; lo byte of format word
        STA     ZP_BITPOS       ; save lo byte
        LDA     FMT_INFO_L+1    ; hi byte
        STA     ZP_BITPOS+1     ; save hi byte

        ; Format word = 0x77C4 (L level, mask 0):
        ; Bits 14..0 in ZP_BITPOS+1 (bits 6..0 = bits 14..8) and ZP_BITPOS (bits 7..0).

        ; ── Region 1: row 8 horizontal + col 8 vertical near top-left ──
        ; We write bit 14 first (MSB), then decreasing to bit 0.
        ; Sequence of (row, col) positions for bits 14..0:

        ; Bit 14 → (0, 8): row 0, col 8
        ; Bit 13 → (1, 8)
        ; Bit 12 → (2, 8)
        ; Bit 11 → (3, 8)
        ; Bit 10 → (4, 8)
        ; Bit  9 → (5, 8)
        ; Bit  8 → (7, 8)   [row 6 is timing, skipped → go to row 7]
        ; Bit  7 → (8, 8)   [dark module, reserved but format bit still here]
        ; Bit  6 → (8, 7)
        ; Bit  5 → (8, 5)   [col 6 is timing, skipped]
        ; Bit  4 → (8, 4)
        ; Bit  3 → (8, 3)
        ; Bit  2 → (8, 2)
        ; Bit  1 → (8, 1)
        ; Bit  0 → (8, 0)

        ; Write region 1:
        LDA     ZP_BITPOS+1     ; hi byte contains bits 14..8 in bits 6..0
        ; Shift to extract bit 14 first:
        ; format_hi has bit 14 in bit 6 (since 0x77C4 hi = 0x77, bit 14 = bit 6 of hi byte):
        ; Actually: format word = 15 bits stored in (ZP_BITPOS+1:ZP_BITPOS):
        ; bit 14 is in bit 6 of ZP_BITPOS+1 (0x77 = 0111_0111, bit6 = 1 for 0x77C4).
        ; Let me work MSB first: concatenate as (ZP_BITPOS+1 bits 6..0)(ZP_BITPOS bits 7..0):
        ; Build as 16-bit with bit15=0, bits 14..0 = format word:
        ; bit 14 = bit 6 of ZP_BITPOS+1. Extract by shifting ZP_BITPOS+1 left twice:
        ; After 2 ASLs: bit 14 is in bit 8 (overflow) → carry. Too complex.
        ; Simpler: use a scratch register to shift the 15-bit value.

        ; Load format word into a 2-byte shift register (ZP_TMP:ZP_TMP2, hi:lo):
        ; Arrange so that bit 14 is in bit 6 of ZP_TMP (hi):
        ; Format word hi nibble is in ZP_BITPOS+1, lo byte in ZP_BITPOS.
        ; Build 16-bit: high = ZP_BITPOS+1, low = ZP_BITPOS → shift left once:
        ; Then bit 15 = bit 14 of format word.

        LDA     ZP_BITPOS+1
        STA     ZP_TMP          ; hi byte of shift register
        LDA     ZP_BITPOS
        STA     ZP_TMP2         ; lo byte of shift register
        ; Left-shift once to put bit 14 into bit 15 (i.e., into carry on next ASL):
        ASL     ZP_TMP2
        ROL     ZP_TMP          ; now bit 14 of format word is in bit 7 of ZP_TMP

        ; ── Format region 1 bit positions ──
        LDX     #0              ; index into fi_r1_row / fi_r1_col tables
.fi_r1:
        CPX     #15
        BEQ     .fi_r1_done

        ; Shift out the next bit (bit 14..0):
        ; Current top bit is in bit 7 of ZP_TMP. Extract it:
        ASL     ZP_TMP2
        ROL     ZP_TMP          ; bit 14-X moves into carry
        BCC     .fi_r1_skip     ; bit = 0: pixel stays white

        ; Bit = 1: write dark pixel
        ; Must save ZP_TMP:ZP_TMP2 (shift register) — INVERT_PIXEL clobbers them.
        LDA     fi_r1_row,X
        STA     ZP_ROW
        LDA     fi_r1_col,X
        STA     ZP_COL
        LDA     ZP_TMP          ; save shift register hi
        PHA
        LDA     ZP_TMP2         ; save shift register lo
        PHA
        TXA
        PHA                     ; save loop index X
        JSR     INVERT_PIXEL
        PLA
        TAX                     ; restore X
        PLA
        STA     ZP_TMP2         ; restore shift register lo
        PLA
        STA     ZP_TMP          ; restore shift register hi
.fi_r1_skip:
        INX
        JMP     .fi_r1
.fi_r1_done:

        ; ── Region 2: top-right + bottom-left ──
        ; Reload format word:
        LDA     ZP_BITPOS+1
        STA     ZP_TMP
        LDA     ZP_BITPOS
        STA     ZP_TMP2
        ASL     ZP_TMP2
        ROL     ZP_TMP

        LDX     #0
.fi_r2:
        CPX     #15
        BEQ     .fi_r2_done

        ASL     ZP_TMP2
        ROL     ZP_TMP
        BCC     .fi_r2_skip

        ; Bit = 1: compute position from version size.
        ; Save shift register FIRST — INVERT_PIXEL clobbers ZP_TMP:ZP_TMP2.
        LDA     ZP_TMP          ; shift register hi
        PHA
        LDA     ZP_TMP2         ; shift register lo
        PHA
        TXA
        PHA                     ; loop index X
        ; Region 2 positions (ZP_TMP free to use as scratch now):
        ; Step X emits bit (14-X); bit i placed at:
        ;   Bit 14-8 (X=0-6)  → col=8, row=ZP_SIZE-1-X  (bottom-left, descending)
        ;   Bit  7-0 (X=7-14) → row=8, col=ZP_SIZE-15+X  (top-right, ascending)
        CPX     #7
        BCS     .fi_r2_top_right
        ; Bit 14-8 (X = 0-6) → col = 8, row = ZP_SIZE-1-X
        STX     ZP_TMP
        LDA     ZP_SIZE
        SEC
        SBC     #1
        SEC
        SBC     ZP_TMP          ; ZP_SIZE-1-X
        STA     ZP_ROW
        LDA     #8
        STA     ZP_COL
        JMP     .fi_r2_draw
.fi_r2_top_right:
        ; Bit 7-0 (X = 7-14) → row = 8, col = ZP_SIZE-15+X
        STX     ZP_TMP
        LDA     ZP_SIZE
        SEC
        SBC     #15
        CLC
        ADC     ZP_TMP          ; ZP_SIZE-15+X
        STA     ZP_COL
        LDA     #8
        STA     ZP_ROW
.fi_r2_draw:
        JSR     INVERT_PIXEL
        PLA
        TAX                     ; restore X
        PLA
        STA     ZP_TMP2         ; restore shift register lo
        PLA
        STA     ZP_TMP          ; restore shift register hi
.fi_r2_skip:
        INX
        JMP     .fi_r2
.fi_r2_done:
        RTS

; Format region 1 row positions (for bits 14..0, MSB first from shift register):
; Shift register emits bit 14 first (MSB) at step 0, bit 0 (LSB) at step 14.
; Bit i goes to row fi_r1_row[14-i], col fi_r1_col[14-i].
; So step 0 (bit 14) → (8,0), step 14 (bit 0) → (0,8).
fi_r1_row:
!byte 8,8,8,8,8,8,8,8,7,5,4,3,2,1,0

; Format region 1 col positions (for bits 14..0, MSB first from shift register):
fi_r1_col:
!byte 0,1,2,3,4,5,7,8,8,8,8,8,8,8,8

; ── VERSION_INFO ─────────────────────────────────────────────────
; Write version information for versions 7-40.
; 18-bit word from lookup table in tables.asm (VER_INFO_WORDS).
; Placed in two 3×6 regions (top-right and bottom-left of matrix).
;
; Bit placement for bit i (0=LSB, 17=MSB):
;   Top-right:   row = (i / 3),          col = ZP_SIZE-11 + (i mod 3)
;   Bottom-left: row = ZP_SIZE-11 + (i mod 3), col = (i / 3)
; This matches ZXing's readVersion() bottom-left loop:
;   for j=5..0: for i=SIZE-9..SIZE-11: copyBit(i,j,versionBits)
;   → bit 0 at (SIZE-11,0), bit 1 at (SIZE-10,0), bit 2 at (SIZE-9,0),
;     bit 3 at (SIZE-11,1), ..., bit 17 at (SIZE-9,5)
; Dark = bit value 1 → INVERT_PIXEL. Light = 0 → skip.
;
; Input: ZP_VER, ZP_SIZE
; Clobbers: A, X, Y, ZP_ROW, ZP_COL, ZP_TMP, ZP_TMP2, ZP_BITPOS, ZP_CBIT

VERSION_INFO:
        LDA     ZP_VER
        CMP     #7
        BCS     .vi_start       ; V7+: has version info
        RTS                     ; V1-6: nothing to do
.vi_start:

        ; Load 18-bit word from VER_INFO_WORDS table (indexed by VER-7):
        LDA     ZP_VER
        SEC
        SBC     #7              ; A = VER-7 (0-based index for V7)
        ; Multiply by 3 for 3-byte table entries: index*3 = index*2 + index
        STA     ZP_TMP          ; save index
        ASL                     ; index * 2
        CLC
        ADC     ZP_TMP          ; index * 3
        TAY                     ; Y = byte offset into VER_INFO_WORDS
        LDA     VER_INFO_WORDS,Y
        STA     ZP_BITPOS       ; lo byte (bits 7..0)
        LDA     VER_INFO_WORDS+1,Y
        STA     ZP_BITPOS+1     ; mid byte (bits 15..8)
        LDA     VER_INFO_WORDS+2,Y
        STA     ZP_CBIT         ; hi byte (bits 17..16, 2 bits only)

        ; Precompute ZP_SIZE-11 into ZP_TMP2 (used for both regions):
        LDA     ZP_SIZE
        SEC
        SBC     #11
        STA     ZP_TMP2         ; ZP_TMP2 = SIZE-11

        ; ZP_TMP = bit index i (0..17), LSR through the 3-byte shift register.
        LDA     #0
        STA     ZP_TMP          ; i = 0

.vi_bit:
        LDA     ZP_TMP
        CMP     #18
        BEQ     .vi_done        ; all 18 bits placed

        ; Extract current bit: shift right ZP_BITPOS, ZP_BITPOS+1, ZP_CBIT.
        ; LSB of ZP_BITPOS → carry before shift.
        LSR     ZP_CBIT
        ROR     ZP_BITPOS+1
        ROR     ZP_BITPOS       ; bit i is now in carry

        BCC     .vi_next_bit    ; bit = 0: no pixel to draw

        ; Bit = 1: compute positions and draw in both regions.
        ; INVERT_PIXEL clobbers: A, ZP_TMP ($FB), ZP_TMP2 ($FC), ZP_PTR ($06-$07).
        ; Does NOT clobber: ZP_ROW ($CE), ZP_COL ($CF), ZP_BITPOS ($FD-FE), ZP_CBIT ($FA).
        ; Use scratch area $A1F0-$A1F1 (safe: QR_INTERLEAVE has already completed).
        ; VI_ROWOFF ($A1F0) = row_offset (i mod 6)
        ; VI_COLBASE ($A1F1) = SIZE-11+col_offset (placed into col for top-right)

VI_ROWOFF    = $A1F0
VI_COLBASE   = $A1F1

        ; Save shift register and i across INVERT_PIXEL calls:
        LDA     ZP_BITPOS
        PHA
        LDA     ZP_BITPOS+1
        PHA
        LDA     ZP_CBIT
        PHA
        LDA     ZP_TMP          ; save i
        PHA

        ; Compute row_index = i/3, col_rem = i mod 3:
        ;   Top-right:   row = i/3,          col = SIZE-11 + (i mod 3)
        ;   Bottom-left: row = SIZE-11+(i mod 3), col = i/3
        ; i ranges 0..17, split into 6 bands of 3.
        ; Subtract 3 repeatedly: quotient → X, remainder → A.
        LDA     ZP_TMP          ; i
        LDX     #0              ; quotient (= i/3) starts at 0
.vi_div3:
        CMP     #3
        BCC     .vi_div3_done   ; A < 3: remainder found
        SEC
        SBC     #3
        INX                     ; quotient++
        JMP     .vi_div3
.vi_div3_done:
        ; A = i mod 3 (0-2), X = i/3 (0-5)
        ; VI_COLBASE = SIZE-11 + (i mod 3):
        CLC
        ADC     ZP_TMP2         ; A = SIZE-11 + (i mod 3)
        STA     VI_COLBASE      ; col for top-right; row for bottom-left
        STX     VI_ROWOFF       ; row for top-right (i/3); col for bottom-left

        ; ── Top-right: row = i/3, col = SIZE-11+(i mod 3) ──
        LDX     VI_ROWOFF
        STX     ZP_ROW          ; row = i/3
        LDA     VI_COLBASE
        STA     ZP_COL          ; col = SIZE-11+(i mod 3)
        JSR     INVERT_PIXEL    ; clobbers ZP_TMP, ZP_TMP2

        ; ── Bottom-left: row = SIZE-11+(i mod 3), col = i/3 ──
        LDA     VI_COLBASE
        STA     ZP_ROW          ; row = SIZE-11+(i mod 3)
        LDX     VI_ROWOFF
        STX     ZP_COL          ; col = i/3
        JSR     INVERT_PIXEL    ; clobbers ZP_TMP, ZP_TMP2

        ; Restore loop state (ZP_TMP2/SIZE-11 needs reload since clobbered):
        LDA     ZP_SIZE
        SEC
        SBC     #11
        STA     ZP_TMP2         ; restore SIZE-11
        PLA
        STA     ZP_TMP          ; restore i
        PLA
        STA     ZP_CBIT
        PLA
        STA     ZP_BITPOS+1
        PLA
        STA     ZP_BITPOS

.vi_next_bit:
        INC     ZP_TMP          ; i++
        JMP     .vi_bit

.vi_done:
        RTS
