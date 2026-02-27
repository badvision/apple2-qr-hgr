; encode.asm — Version selection, data encoding, RS block dispatch, interleaving
; Produces the complete interleaved codeword stream in CODEWORD_BUF.

CODEWORD_BUF = $9000            ; data + EC codewords for all blocks

; Bit-packing state for PACK_BITS:
;   ZP_PTR ($06)  = write byte pointer into CODEWORD_BUF
;   ZP_PTR+1($07) = hi byte of write pointer
;   ZP_PTR2($08)  = bit mask for current byte position ($80 initially)
;   ZP_CBIT($FA)  = total data codeword count (for padding)

; ── QR_SELECT_VER ────────────────────────────────────────────────
; Find minimum version for ZP_LEN bytes in byte mode (EC level L).
; Input:  ZP_LEN (2B lo/hi) = number of bytes to encode
; Output: ZP_VER = version (1-40), ZP_SIZE = 4*VER+17
;         carry set if data too long for V40
; Clobbers: A, X, Y, ZP_TMP, ZP_TMP2

QR_SELECT_VER:
        LDX     #0              ; version - 1 (0..39)
.qsv_loop:
        CPX     #40
        BCS     .qsv_long
        TXA
        ASL                     ; X*2 = byte offset into CAP_TABLE (!word entries)
        TAY
        LDA     CAP_TABLE,Y     ; capacity lo
        STA     ZP_TMP
        LDA     CAP_TABLE+1,Y   ; capacity hi
        STA     ZP_TMP2
        ; if ZP_LEN (hi:lo) <= cap (ZP_TMP2:ZP_TMP): this version fits
        LDA     ZP_LEN+1
        CMP     ZP_TMP2
        BCC     .qsv_fits       ; len_hi < cap_hi: fits
        BNE     .qsv_next       ; len_hi > cap_hi: too large
        LDA     ZP_LEN
        CMP     ZP_TMP
        BCC     .qsv_fits       ; len_lo < cap_lo: fits
        BEQ     .qsv_fits       ; len_lo == cap_lo: exactly fits
.qsv_next:
        INX
        JMP     .qsv_loop
.qsv_fits:
        INX                     ; version = X + 1
        STX     ZP_VER
        TXA
        ASL
        ASL                     ; VER * 4
        CLC
        ADC     #17             ; VER*4 + 17
        STA     ZP_SIZE
        CLC
        RTS
.qsv_long:
        SEC
        RTS

; ── PACK_BITS ────────────────────────────────────────────────────
; Append N bits (right-aligned) to the codeword buffer.
; Input:  A = value (bits N-1..0 are the N bits to write, MSB first)
;         X = N (1..8)
; State:  ZP_PTR  = current write byte pointer (initialized before use)
;         ZP_PTR2 = current bit mask for position in byte ($80 = MSB)
; Output: buffer updated, ZP_PTR/ZP_PTR2 advanced as needed
; Clobbers: A, X, Y, ZP_TMP, ZP_TMP2
; NOTE: CODEWORD_BUF must be zeroed before first call to PACK_BITS.

PACK_BITS:
        ; Save value on stack; compute pre-shift count in Y; reload and shift:
        STA     ZP_TMP2         ; save value temporarily to ZP_TMP2
        STX     ZP_TMP          ; save N
        LDA     #8
        SEC
        SBC     ZP_TMP          ; 8-N
        TAY                     ; Y = pre-shift count
        LDA     ZP_TMP2         ; restore value
        BEQ     .pb_shifted     ; value = 0, no need to shift (all bits = 0)
        CPY     #0
        BEQ     .pb_shifted     ; N = 8, no pre-shift
.pb_preshift:
        ASL
        DEY
        BNE     .pb_preshift
.pb_shifted:
        ; Now A has the N bits left-aligned in bits 7..8-N.
        ; Emit N bits (ZP_TMP = N):
        LDY     ZP_TMP          ; Y = N (bit count)
.pb_loop:
        ASL                     ; emit MSB → carry; A shifts left
        PHA                     ; save remaining bits + shifted state
        BCC     .pb_bit0
        ; Bit = 1: OR the mask into current buffer byte:
        TYA
        PHA                     ; save Y (count)
        LDY     #0
        LDA     ZP_PTR2         ; current bit mask
        ORA     (ZP_PTR),Y      ; OR into buffer byte
        STA     (ZP_PTR),Y
        PLA
        TAY
.pb_bit0:
        ; Advance bit mask: rotate right. If mask reaches 0, advance byte ptr.
        LDA     ZP_PTR2
        LSR
        STA     ZP_PTR2
        BNE     .pb_same_byte
        ; Rolled off bit 0 → start next byte:
        LDA     #$80
        STA     ZP_PTR2
        INC     ZP_PTR
        BNE     .pb_same_byte
        INC     ZP_PTR+1
        ; Also zero the new byte (so future ORs work correctly).
        ; Y holds the bit count — save/restore it around LDY #0:
        TYA
        PHA                     ; save Y (bit count) on stack
        LDY     #0
        LDA     #0
        STA     (ZP_PTR),Y
        PLA
        TAY                     ; restore Y (bit count)
.pb_same_byte:
        PLA                     ; restore shifted value
        DEY
        BNE     .pb_loop
        RTS

; ── QR_ENCODE_DATA ───────────────────────────────────────────────
; Build the data codeword stream in CODEWORD_BUF.
; Encodes: mode indicator (4b) + char count (8/16b) + data bytes +
;          terminator (4b) + bit padding + byte padding (0xEC/0x11).
;
; Input:  ZP_SRC (2B) = source data pointer
;         ZP_LEN (2B) = data length in bytes
;         ZP_VER = version
; Output: CODEWORD_BUF[0..n_data-1] = data codewords
;         ZP_CBIT = total data codeword count
; Clobbers: A, X, Y, ZP_TMP, ZP_TMP2, ZP_PTR, ZP_PTR2, ZP_CBIT, ZP_BITPOS

QR_ENCODE_DATA:
        ; Pre-zero CODEWORD_BUF[0..total_data-1] so PACK_BITS (which ORs bits)
        ; produces correct output even if the buffer has stale data from a prior run.
        ; Compute total_data = b1*d1 + b2*d2 from BLK_PARAMS:
        LDA     ZP_VER
        SEC
        SBC     #1
        STA     ZP_TMP
        ASL
        ASL
        CLC
        ADC     ZP_TMP          ; (VER-1)*5 = BLK_PARAMS offset
        TAY
        ; 16-bit b1*d1: sum d1 b1 times with carry tracking
        LDA     BLK_PARAMS+2,Y  ; d1
        STA     ZP_TMP2         ; d1
        LDA     #0
        STA     ZP_BITPOS       ; total_lo = 0
        STA     ZP_BITPOS+1     ; total_hi = 0
        LDA     BLK_PARAMS+1,Y  ; b1
        TAX                     ; X = b1 (count); TAX sets Z if b1=0
        BEQ     .qed_z_g1_skip  ; b1=0: skip
.qed_z_g1_add:
        CLC
        LDA     ZP_BITPOS
        ADC     ZP_TMP2         ; lo += d1
        STA     ZP_BITPOS
        BCC     .qed_z_g1_nc
        INC     ZP_BITPOS+1     ; hi++
.qed_z_g1_nc:
        DEX
        BNE     .qed_z_g1_add
.qed_z_g1_skip:
        ; Reload Y (X clobbered by loop):
        LDA     ZP_VER
        SEC
        SBC     #1
        STA     ZP_TMP
        ASL
        ASL
        CLC
        ADC     ZP_TMP
        TAY
        LDA     BLK_PARAMS+3,Y  ; b2
        BEQ     .qed_zero_buf   ; b2=0: no group 2
        TAX                     ; X = b2 (count)
        LDA     BLK_PARAMS+4,Y  ; d2
        STA     ZP_TMP2         ; d2
.qed_z_g2_add:
        CLC
        LDA     ZP_BITPOS
        ADC     ZP_TMP2         ; lo += d2
        STA     ZP_BITPOS
        BCC     .qed_z_g2_nc
        INC     ZP_BITPOS+1     ; hi++
.qed_z_g2_nc:
        DEX
        BNE     .qed_z_g2_add
.qed_zero_buf:
        ; Zero ZP_BITPOS:ZP_BITPOS+1 bytes starting at CODEWORD_BUF:
        LDA     #<CODEWORD_BUF
        STA     ZP_PTR
        LDA     #>CODEWORD_BUF
        STA     ZP_PTR+1
        LDY     #0
        LDA     #0
.qed_zloop:
        LDA     ZP_BITPOS
        ORA     ZP_BITPOS+1
        BEQ     .qed_zinit      ; count reached zero: done
        LDA     #0
        STA     (ZP_PTR),Y      ; zero this byte
        INC     ZP_PTR
        BNE     .qed_znc
        INC     ZP_PTR+1
.qed_znc:
        LDA     ZP_BITPOS
        BNE     .qed_zdlo
        DEC     ZP_BITPOS+1
.qed_zdlo:
        DEC     ZP_BITPOS
        JMP     .qed_zloop
.qed_zinit:
        ; Re-initialize write pointer and bit mask:
        LDA     #<CODEWORD_BUF
        STA     ZP_PTR
        LDA     #>CODEWORD_BUF
        STA     ZP_PTR+1
        LDA     #$80            ; start at MSB of first byte
        STA     ZP_PTR2

        ; 1. Mode indicator: 0100 byte mode = value $04 in 4 bits
        LDA     #$04
        LDX     #4
        JSR     PACK_BITS

        ; 2. Character count indicator:
        LDA     ZP_VER
        CMP     #10
        BCS     .qed_cc16
        ; V1-9: 8-bit count
        LDA     ZP_LEN          ; lo byte (assumes length ≤ 255 for V1-9)
        LDX     #8
        JSR     PACK_BITS
        JMP     .qed_data
.qed_cc16:
        ; V10-40: 16-bit count (hi byte first)
        LDA     ZP_LEN+1
        LDX     #8
        JSR     PACK_BITS
        LDA     ZP_LEN
        LDX     #8
        JSR     PACK_BITS

.qed_data:
        ; 3. Data bytes (ZP_LEN bytes from ZP_SRC):
        LDA     ZP_LEN+1
        STA     ZP_BITPOS+1     ; loop counter hi
        LDA     ZP_LEN
        STA     ZP_BITPOS       ; loop counter lo
        LDY     #0
.qed_byte:
        LDA     ZP_BITPOS
        ORA     ZP_BITPOS+1
        BEQ     .qed_term
        TYA
        PHA                     ; save Y (source index) before pack
        LDA     (ZP_SRC),Y      ; load data byte
        LDX     #8
        JSR     PACK_BITS       ; PACK_BITS clobbers A, X, Y
        PLA                     ; restore Y (source index)
        TAY
        INY
        BNE     .qed_cnt
        INC     ZP_SRC+1
        LDY     #0
.qed_cnt:
        LDA     ZP_BITPOS
        BNE     .qed_cnt_lo
        DEC     ZP_BITPOS+1
.qed_cnt_lo:
        DEC     ZP_BITPOS
        JMP     .qed_byte

.qed_term:
        ; 4. Terminator: 0000 (4 bits, or fewer if at buffer capacity)
        LDA     #$00
        LDX     #4
        JSR     PACK_BITS

        ; 5. Bit padding to next byte boundary:
        ; ZP_PTR2 = current mask. If mask = $80, we're at a byte boundary.
        LDA     ZP_PTR2
        CMP     #$80
        BEQ     .qed_bytepad
        ; Pad remaining bits to 0 (buffer already 0, just advance mask):
.qed_bitpad:
        LSR     ZP_PTR2
        BNE     .qed_bitpad     ; until mask = 0 (all 8 bits used)
        LDA     #$80
        STA     ZP_PTR2
        INC     ZP_PTR
        BNE     .qed_bytepad
        INC     ZP_PTR+1
        LDA     #0
        LDY     #0
        STA     (ZP_PTR),Y      ; zero next byte

.qed_bytepad:
        ; 6. Byte padding with 0xEC/0x11 alternating:
        ; Compute 16-bit total data codewords into ZP_BITPOS/ZP_BITPOS+1.
        ; ZP_VER is preserved throughout encoding; ZP_TMP/ZP_TMP2/Y are free now.
        LDA     ZP_VER
        SEC
        SBC     #1
        STA     ZP_TMP
        ASL
        ASL
        CLC
        ADC     ZP_TMP          ; (VER-1)*5 = offset into BLK_PARAMS
        TAY
        ; b1*d1 (16-bit): sum d1 b1 times with carry
        LDA     BLK_PARAMS+2,Y  ; d1
        STA     ZP_TMP2         ; d1
        LDA     #0
        STA     ZP_BITPOS       ; total_lo = 0
        STA     ZP_BITPOS+1     ; total_hi = 0
        LDA     BLK_PARAMS+1,Y  ; b1
        TAX                     ; X = b1; TAX sets Z if b1=0
        BEQ     .qed_pad_g1_skip
.qed_pad_g1_add:
        CLC
        LDA     ZP_BITPOS
        ADC     ZP_TMP2         ; lo += d1
        STA     ZP_BITPOS
        BCC     .qed_pad_g1_nc
        INC     ZP_BITPOS+1
.qed_pad_g1_nc:
        DEX
        BNE     .qed_pad_g1_add
.qed_pad_g1_skip:
        ; Reload Y:
        LDA     ZP_VER
        SEC
        SBC     #1
        STA     ZP_TMP
        ASL
        ASL
        CLC
        ADC     ZP_TMP
        TAY
        ; + b2*d2 (if b2 != 0):
        LDA     BLK_PARAMS+3,Y  ; b2
        BEQ     .qed_no_g2
        TAX                     ; X = b2 (count)
        LDA     BLK_PARAMS+4,Y  ; d2
        STA     ZP_TMP2         ; d2
.qed_pad_g2_add:
        CLC
        LDA     ZP_BITPOS
        ADC     ZP_TMP2         ; lo += d2
        STA     ZP_BITPOS
        BCC     .qed_pad_g2_nc
        INC     ZP_BITPOS+1
.qed_pad_g2_nc:
        DEX
        BNE     .qed_pad_g2_add
.qed_no_g2:
        ; Use ZP_CBIT ($FA) as pad toggle: 0=$EC, 1=$11.
        ; ZP_BITPOS/ZP_BITPOS+1 = 16-bit total data codeword count.
        LDA     #0
        STA     ZP_CBIT         ; toggle: 0=$EC, 1=$11
.qed_padloop:
        ; 16-bit comparison: offset = ZP_PTR - CODEWORD_BUF
        ; offset_lo = ZP_PTR - lo(CODEWORD_BUF); offset_hi from borrow
        LDA     ZP_PTR
        SEC
        SBC     #<CODEWORD_BUF
        STA     ZP_TMP          ; offset_lo (carry set if no borrow)
        LDA     ZP_PTR+1
        SBC     #>CODEWORD_BUF  ; offset_hi
        ; Compare offset >= total: first compare hi bytes
        CMP     ZP_BITPOS+1
        BCC     .qed_pad_write  ; offset_hi < total_hi: definitely less
        BNE     .qed_done       ; offset_hi > total_hi: definitely done
        ; hi bytes equal: compare lo bytes
        LDA     ZP_TMP
        CMP     ZP_BITPOS       ; compare offset_lo with total_lo
        BCS     .qed_done       ; offset_lo >= total_lo: done

.qed_pad_write:
        LDA     ZP_CBIT         ; load toggle
        BNE     .qed_pad11
        LDA     #$EC
        JMP     .qed_write_pad
.qed_pad11:
        LDA     #$11
.qed_write_pad:
        PHA                     ; save pad value ($EC or $11)
        LDA     ZP_CBIT
        EOR     #1
        STA     ZP_CBIT         ; flip toggle before PACK_BITS clobbers ZP_TMP
        PLA                     ; restore pad value
        LDX     #8
        JSR     PACK_BITS
        JMP     .qed_padloop

.qed_done:
        RTS

; ── MUL8 ─────────────────────────────────────────────────────────
; 8-bit unsigned multiply via repeated addition.
; Input:  ZP_TMP = multiplicand a,  ZP_TMP2 = multiplier b
; Output: A = (a * b) mod 256
; Clobbers: A, X

MUL8:
        LDX     ZP_TMP          ; count = a
        BEQ     .m8_done        ; a = 0 → result 0 (test BEFORE clearing A)
        LDA     #0              ; start sum at 0
.m8:
        CLC
        ADC     ZP_TMP2
        DEX
        BNE     .m8
        RTS
.m8_done:
        LDA     #0
        RTS

; ── QR_INTERLEAVE ────────────────────────────────────────────────
; Interleave codewords from multiple blocks into the final stream.
; For V1-V5 (single block), data is already in final order — no-op.
; For multi-block versions: interleave data bytes, then EC bytes.
;
; Input layout in CODEWORD_BUF (as written by QR_ENCODE_DATA + QR_RS_ALL_BLOCKS):
;   [blk0_data(d1)][blk1_data(d1)]...[g2blk0_data(d2)]...[blk0_ec(ecpb)][blk1_ec(ecpb)]...
;   Data is contiguous, followed by all EC bytes (no interleaved gaps).
;
; EC base = CODEWORD_BUF + total_data where total_data = b1*d1 + b2*d2.
;
; Output layout (written to INTERLEAVE_BUF=$A200, then copied back to CODEWORD_BUF):
;   data: cw0_blk0, cw0_blk1, ..., cw1_blk0, ..., extra_g2_cw
;   ec:   ec0_blk0, ec0_blk1, ..., ec1_blk0, ...
;
; Scratch: INTERLEAVE_BUF ($A200) — max 3706 bytes, ends at $B0EA.
;          $A1F0-$A1FA: interleave parameters.
; ZP usage: ZP_PTR (source), ZP_PTR2 (dest), ZP_ROW (j index),
;           ZP_COL (block index), ZP_TMP, ZP_TMP2, ZP_CBIT, ZP_BITPOS
;
; Clobbers: A, X, Y, ZP_TMP, ZP_TMP2, ZP_PTR, ZP_PTR2,
;           ZP_CBIT, ZP_BITPOS, ZP_ROW, ZP_COL

INTERLEAVE_BUF  = $A200
QI_B1           = $A1F0  ; b1 (group 1 block count)
QI_B2           = $A1F1  ; b2 (group 2 block count)
QI_D1           = $A1F2  ; d1 (group 1 data codewords per block)
QI_D2           = $A1F3  ; d2 (group 2 data codewords per block)
QI_ECPB         = $A1F4  ; EC codewords per block
QI_BLKSZ1       = $A1F5  ; (unused/repurposed; kept for label compat)
QI_BLKSZ2       = $A1F6  ; (unused/repurposed; kept for label compat)
QI_MAXD         = $A1F7  ; max data per block = d2 (if b2>0) else d1
QI_NBLK         = $A1F8  ; total block count = b1 + b2
QI_G1END_LO     = $A1F9  ; lo byte: EC base = CODEWORD_BUF + total_data
QI_G1END_HI     = $A1FA  ; hi byte: EC base = CODEWORD_BUF + total_data

QR_INTERLEAVE:
        ; Single-block versions (V1-5) need no interleaving:
        LDA     ZP_VER
        CMP     #6
        BCS     .qi_multi       ; V6+: do interleave
        RTS                     ; V1-5: nothing to do
.qi_multi:

        ; ── Load BLK_PARAMS for this version ──
        LDA     ZP_VER
        SEC
        SBC     #1
        STA     ZP_TMP
        ASL
        ASL
        CLC
        ADC     ZP_TMP          ; (VER-1)*5 = offset into BLK_PARAMS
        TAY

        LDA     BLK_PARAMS,Y    ; ecpb
        STA     QI_ECPB
        LDA     BLK_PARAMS+1,Y  ; b1
        STA     QI_B1
        LDA     BLK_PARAMS+2,Y  ; d1
        STA     QI_D1
        LDA     BLK_PARAMS+3,Y  ; b2
        STA     QI_B2
        LDA     BLK_PARAMS+4,Y  ; d2
        STA     QI_D2

        ; maxd = d2 if b2>0, else d1
        LDA     QI_B2
        BEQ     .qi_maxd_g1
        LDA     QI_D2
        JMP     .qi_set_maxd
.qi_maxd_g1:
        LDA     QI_D1
.qi_set_maxd:
        STA     QI_MAXD

        ; nblk = b1 + b2
        LDA     QI_B1
        CLC
        ADC     QI_B2
        STA     QI_NBLK

        ; Compute EC base = CODEWORD_BUF + total_data where total_data = b1*d1 + b2*d2.
        ; Use ZP_CBIT:ZP_BITPOS+1 as accumulator (16-bit).
        ; b1*d1 first (8-bit result since max b1=20, d1=153 → 3060 > 255, need 16-bit!):
        LDA     #0
        STA     ZP_CBIT         ; total lo
        STA     ZP_BITPOS+1     ; total hi
        LDX     QI_B1
        BEQ     .qi_total_g1_done
.qi_total_g1_add:
        LDA     ZP_CBIT
        CLC
        ADC     QI_D1
        STA     ZP_CBIT
        BCC     .qi_total_g1_nc
        INC     ZP_BITPOS+1
.qi_total_g1_nc:
        DEX
        BNE     .qi_total_g1_add
.qi_total_g1_done:
        ; + b2*d2:
        LDX     QI_B2
        BEQ     .qi_total_done
.qi_total_g2_add:
        LDA     ZP_CBIT
        CLC
        ADC     QI_D2
        STA     ZP_CBIT
        BCC     .qi_total_g2_nc
        INC     ZP_BITPOS+1
.qi_total_g2_nc:
        DEX
        BNE     .qi_total_g2_add
.qi_total_done:
        ; ZP_CBIT:ZP_BITPOS+1 = total_data (16-bit).
        ; EC base = CODEWORD_BUF + total_data:
        LDA     #<CODEWORD_BUF
        CLC
        ADC     ZP_CBIT
        STA     QI_G1END_LO
        LDA     #>CODEWORD_BUF
        ADC     ZP_BITPOS+1
        STA     QI_G1END_HI

        ; ── Initialize destination pointer ──
        LDA     #<INTERLEAVE_BUF
        STA     ZP_PTR2
        LDA     #>INTERLEAVE_BUF
        STA     ZP_PTR2+1

        ; ── Phase 1: Interleave data bytes ──
        ; Outer loop: j = ZP_ROW = 0..maxd-1
        LDA     #0
        STA     ZP_ROW          ; j = 0

.qi_data_j:
        LDA     ZP_ROW
        CMP     QI_MAXD
        BNE     .qi_data_j_go   ; j != maxd: continue
        JMP     .qi_ec_phase    ; j == maxd: done with data
.qi_data_j_go:

        ; Inner loop: blk = ZP_COL = 0..nblk-1
        LDA     #0
        STA     ZP_COL          ; blk = 0

        ; Compute base address for block 0: CODEWORD_BUF + j
        ; (blocks are contiguous: blk_i starts at CODEWORD_BUF + i*d1 for g1)
        ; We start at blk0[j] = CODEWORD_BUF + j, then advance by d1 to reach blk1[j], etc.
        LDA     #<CODEWORD_BUF
        CLC
        ADC     ZP_ROW
        STA     ZP_PTR
        LDA     #>CODEWORD_BUF
        ADC     #0
        STA     ZP_PTR+1

.qi_data_blk:
        LDA     ZP_COL
        CMP     QI_NBLK
        BEQ     .qi_data_j_next ; all blocks done for this j

        ; Determine if this block is g1 or g2:
        CMP     QI_B1
        BCC     .qi_data_g1     ; blk < b1: group 1

        ; Group 2 block: skip if j >= d2
        LDA     ZP_ROW
        CMP     QI_D2
        BCS     .qi_data_skip   ; j >= d2: no byte for this block at this j
        JMP     .qi_data_read

.qi_data_g1:
        ; Group 1 block: skip if j >= d1
        LDA     ZP_ROW
        CMP     QI_D1
        BCS     .qi_data_skip   ; j >= d1: skip

.qi_data_read:
        ; Read byte from ZP_PTR
        LDY     #0
        LDA     (ZP_PTR),Y
        ; Write to destination
        STA     (ZP_PTR2),Y
        ; Advance dest pointer
        INC     ZP_PTR2
        BNE     .qi_data_adv_src
        INC     ZP_PTR2+1

.qi_data_adv_src:
        ; Advance source by block data size (d1 for g1, d2 for g2).
        ; Data is contiguous: blk0[j] at base+j, blk1[j] at base+d1+j, etc.
        LDA     ZP_COL
        CMP     QI_B1
        BCS     .qi_data_adv2
        ; g1: advance by d1
        LDA     ZP_PTR
        CLC
        ADC     QI_D1
        STA     ZP_PTR
        BCC     .qi_data_blk_next
        INC     ZP_PTR+1
        JMP     .qi_data_blk_next

.qi_data_adv2:
        ; g2: advance by d2
        LDA     ZP_PTR
        CLC
        ADC     QI_D2
        STA     ZP_PTR
        BCC     .qi_data_blk_next
        INC     ZP_PTR+1
        JMP     .qi_data_blk_next

.qi_data_skip:
        ; No byte from this block for this j: still advance src.
        LDA     ZP_COL
        CMP     QI_B1
        BCS     .qi_data_skip2
        LDA     ZP_PTR
        CLC
        ADC     QI_D1
        STA     ZP_PTR
        BCC     .qi_data_blk_next
        INC     ZP_PTR+1
        JMP     .qi_data_blk_next
.qi_data_skip2:
        LDA     ZP_PTR
        CLC
        ADC     QI_D2
        STA     ZP_PTR
        BCC     .qi_data_blk_next
        INC     ZP_PTR+1

.qi_data_blk_next:
        INC     ZP_COL
        JMP     .qi_data_blk

.qi_data_j_next:
        INC     ZP_ROW
        JMP     .qi_data_j

        ; ── Phase 2: Interleave EC bytes ──
        ; EC bytes are stored contiguously after data:
        ; blk0_ec[0..ecpb-1] at EC_BASE+0, blk1_ec at EC_BASE+ecpb, etc.
        ; For EC byte j of blk i: EC_BASE + i*ecpb + j
.qi_ec_phase:
        ; Outer loop: j = ZP_ROW = 0..ecpb-1
        LDA     #0
        STA     ZP_ROW          ; j = 0

.qi_ec_j:
        LDA     ZP_ROW
        CMP     QI_ECPB
        BEQ     .qi_copy_back   ; j == ecpb: done with EC

        ; Inner loop: blk = ZP_COL = 0..nblk-1
        LDA     #0
        STA     ZP_COL

        ; Source = EC_BASE + j = QI_G1END + ZP_ROW
        LDA     QI_G1END_LO
        CLC
        ADC     ZP_ROW
        STA     ZP_PTR
        LDA     QI_G1END_HI
        ADC     #0
        STA     ZP_PTR+1

.qi_ec_blk:
        LDA     ZP_COL
        CMP     QI_NBLK
        BEQ     .qi_ec_j_next   ; all blocks done for this j

        ; Read EC byte
        LDY     #0
        LDA     (ZP_PTR),Y
        STA     (ZP_PTR2),Y
        ; Advance dest
        INC     ZP_PTR2
        BNE     .qi_ec_adv_src
        INC     ZP_PTR2+1

.qi_ec_adv_src:
        ; Advance source by ecpb to reach next block's EC area
        LDA     ZP_PTR
        CLC
        ADC     QI_ECPB
        STA     ZP_PTR
        BCC     .qi_ec_blk_next
        INC     ZP_PTR+1

.qi_ec_blk_next:
        INC     ZP_COL
        JMP     .qi_ec_blk

.qi_ec_j_next:
        INC     ZP_ROW
        JMP     .qi_ec_j

        ; ── Phase 3: Copy INTERLEAVE_BUF back to CODEWORD_BUF ──
.qi_copy_back:
        ; bytes_to_copy = ZP_PTR2 - INTERLEAVE_BUF (16-bit).
        LDA     ZP_PTR2
        SEC
        SBC     #<INTERLEAVE_BUF
        STA     ZP_CBIT         ; byte count lo
        LDA     ZP_PTR2+1
        SBC     #>INTERLEAVE_BUF
        STA     ZP_BITPOS+1     ; byte count hi

        ; Source = INTERLEAVE_BUF, Dest = CODEWORD_BUF
        LDA     #<INTERLEAVE_BUF
        STA     ZP_PTR
        LDA     #>INTERLEAVE_BUF
        STA     ZP_PTR+1
        LDA     #<CODEWORD_BUF
        STA     ZP_PTR2
        LDA     #>CODEWORD_BUF
        STA     ZP_PTR2+1

        ; Copy ZP_CBIT:ZP_BITPOS+1 bytes
        LDY     #0
.qi_copy:
        LDA     ZP_CBIT
        ORA     ZP_BITPOS+1
        BEQ     .qi_done        ; count = 0: done
        LDA     (ZP_PTR),Y
        STA     (ZP_PTR2),Y
        INC     ZP_PTR
        BNE     .qi_copy_nc1
        INC     ZP_PTR+1
.qi_copy_nc1:
        INC     ZP_PTR2
        BNE     .qi_copy_nc2
        INC     ZP_PTR2+1
.qi_copy_nc2:
        LDA     ZP_CBIT
        BNE     .qi_copy_dlo
        DEC     ZP_BITPOS+1
.qi_copy_dlo:
        DEC     ZP_CBIT
        JMP     .qi_copy

.qi_done:
        RTS
