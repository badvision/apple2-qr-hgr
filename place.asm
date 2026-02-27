; place.asm — QR data bit placement (zigzag scan with mask)
; Reads the interleaved codeword stream and places each module into
; the HGR page, skipping function modules.
; Uses fixed mask pattern 0: invert if (row + col) mod 2 = 0.
;
; ZP usage for PLACE_DATA:
;   ZP_PTR ($06-$07) = INVERT_PIXEL's HGR byte address (owned by INVERT_PIXEL)
;   ZP_PTR2($08-$09) = codeword buffer read pointer (lo/hi)
;   ZP_CBIT ($FA)    = bit offset within current codeword byte (0=MSB=bit7)
;   ZP_SRC  ($EB)    = right column of current scan pair (IS_FUNC_MODULE-safe)
;   ZP_TMP2 ($FC)    = zigzag direction (0=upward, 1=downward)
;   ZP_TMP  ($FB)    = scratch (clobbered by IS_FUNC_MODULE and INVERT_PIXEL)

; ── PLACE_DATA ───────────────────────────────────────────────────
; Place all data and EC bits into the QR matrix on the HGR page.
;
; Must call after:
;   - ZP_CBIT = 0 (read from bit 7 of first byte)
;   - ZP_VER, ZP_SIZE set
;
; Zigzag scan: start at rightmost column, move left in pairs of columns.
; Skip column 6 (timing). Within each pair: alternate up/down direction.
;
; Clobbers: A, X, Y, ZP_ROW, ZP_COL, ZP_TMP, ZP_TMP2, ZP_SRC, ZP_CBIT,
;           ZP_PTR (via INVERT_PIXEL), ZP_PTR2, ZP_BITPOS

PLACE_DATA:
        ; Initialize codeword read pointer:
        LDA     #<CODEWORD_BUF
        STA     ZP_PTR2
        LDA     #>CODEWORD_BUF
        STA     ZP_PTR2+1

        ; ZP_CBIT = 0 (start at MSB of first byte) — set by caller (qr.asm)

        ; right_col = ZP_SIZE - 1 (start from rightmost column pair)
        ; Store in ZP_SRC ($EB) — safe from IS_FUNC_MODULE and INVERT_PIXEL clobbers.
        LDA     ZP_SIZE
        SEC
        SBC     #1
        STA     ZP_SRC          ; ZP_SRC = right_col (persistent, clobber-safe)

        LDA     #0
        STA     ZP_TMP2         ; direction: 0 = upward (row decreases)

.pd_pair:
        LDA     ZP_SRC          ; right_col
        CMP     #$FF            ; wrapped past 0? (happens after right_col=1: 1-2=$FF)
        BEQ     .pd_done

        ; Skip column 6 (timing): the scan sequence 20,18,...,8,6,4,2,0 would miss $FF.
        ; When right_col=6, decrement by 1 (not 2) to shift parity to odd (5,3,1,$FF).
        CMP     #6
        BNE     .pd_not6
        DEC     ZP_SRC          ; right_col = 5; pair (5,4); col 6 right-side handled by IFM
.pd_not6:

        ; Scan the column pair based on direction:
        LDA     ZP_TMP2
        BNE     .pd_down

        ; Upward: start at bottom row, go up
        LDA     ZP_SIZE
        SEC
        SBC     #1
        STA     ZP_ROW
.pd_up_row:
        JSR     PD_FILL_PAIR    ; fill right then left col at ZP_ROW
        LDA     ZP_ROW
        BEQ     .pd_up_done     ; reached row 0
        DEC     ZP_ROW
        JMP     .pd_up_row
.pd_up_done:
        LDA     #1
        STA     ZP_TMP2         ; switch to downward
        JMP     .pd_advance

.pd_down:
        ; Downward: start at top row, go down
        LDA     #0
        STA     ZP_ROW
.pd_down_row:
        JSR     PD_FILL_PAIR
        LDA     ZP_ROW
        CMP     ZP_SIZE
        BCS     .pd_down_done
        LDA     ZP_SIZE
        SEC
        SBC     #1
        CMP     ZP_ROW
        BEQ     .pd_down_done
        INC     ZP_ROW
        JMP     .pd_down_row
.pd_down_done:
        LDA     #0
        STA     ZP_TMP2

.pd_advance:
        ; right_col -= 2; ZP_SRC holds the clobber-safe right_col value.
        LDA     ZP_SRC
        SEC
        SBC     #2
        STA     ZP_SRC          ; right_col -= 2
        JMP     .pd_pair

.pd_done:
        RTS

; ── PD_FILL_PAIR ─────────────────────────────────────────────────
; Place modules at (ZP_ROW, right_col) and (ZP_ROW, right_col-1).
; ZP_SRC = right_col (persistent, clobber-safe across IS_FUNC_MODULE).
; Clobbers: A, X, Y, ZP_COL, ZP_TMP, ZP_BITPOS

PD_FILL_PAIR:
        ; Right column: load right_col from ZP_SRC (safe from IS_FUNC_MODULE)
        LDA     ZP_SRC
        STA     ZP_COL
        JSR     PD_PLACE_MODULE ; clobbers ZP_TMP — ZP_SRC is unaffected
        ; Left column: right_col - 1, reload right_col from ZP_SRC
        LDA     ZP_SRC
        SEC
        SBC     #1
        STA     ZP_COL
        JMP     PD_PLACE_MODULE ; tail call

; ── PD_PLACE_MODULE ──────────────────────────────────────────────
; Place one QR module at (ZP_ROW, ZP_COL).
; Skips if function module. Gets next bit from codeword stream,
; applies mask pattern 0 ((row+col) mod 2 = 0 → invert).
; Dark modules call INVERT_PIXEL; light modules are already white.
;
; State: ZP_PTR2 = byte pointer into CODEWORD_BUF
;        ZP_CBIT = bit offset in current byte (0=MSB=bit7, 7=LSB=bit0)
; Clobbers: A, X, Y, ZP_TMP, ZP_BITPOS, ZP_PTR (via INVERT_PIXEL)

PD_PLACE_MODULE:
        ; Check if function module: if so, skip (no bit consumed)
        JSR     IS_FUNC_MODULE
        BCS     .ppm_skip

        ; Fetch next bit from codeword stream:
        ; Current byte at ZP_PTR2, bit position = ZP_CBIT (0=MSB).
        ; Extract bit: shift the byte left ZP_CBIT times; bit 7 = desired bit.
        LDA     ZP_CBIT
        STA     ZP_BITPOS       ; save bit position
        LDY     #0
        LDA     (ZP_PTR2),Y     ; current codeword byte
        LDX     ZP_BITPOS       ; X = bit position (0..7)
        BEQ     .ppm_extracted  ; position 0 → bit 7 is already the bit
.ppm_shift:
        ASL                     ; shift left: moves bit at (7-X) to higher position
        DEX
        BNE     .ppm_shift
.ppm_extracted:
        ; Bit 7 of A = the desired data bit (1=dark, 0=light)
        AND     #$80
        STA     ZP_BITPOS+1     ; save raw bit (0 or $80)

        ; Advance bit stream pointer:
        LDA     ZP_BITPOS       ; old bit position
        CLC
        ADC     #1
        CMP     #8
        BCC     .ppm_same_byte
        ; Crossed byte boundary: advance byte pointer
        LDA     #0              ; new bit position = 0
        INC     ZP_PTR2
        BNE     .ppm_same_byte
        INC     ZP_PTR2+1
.ppm_same_byte:
        STA     ZP_CBIT         ; update bit position

        ; Apply mask pattern 0: (row + col) mod 2 = 0 → invert bit
        LDA     ZP_ROW
        CLC
        ADC     ZP_COL
        AND     #1
        BNE     .ppm_no_mask    ; (row+col) odd: no mask
        LDA     ZP_BITPOS+1
        EOR     #$80            ; flip bit
        STA     ZP_BITPOS+1
.ppm_no_mask:
        ; If bit = dark ($80): invert pixel (white→dark)
        ; If bit = light (0):  skip (already white)
        LDA     ZP_BITPOS+1
        BEQ     .ppm_skip       ; light: skip
        JSR     INVERT_PIXEL    ; dark: XOR pixel
        ; NOTE: INVERT_PIXEL uses ZP_PTR for HGR byte address.
        ; ZP_PTR2 (codeword pointer) is NOT clobbered by INVERT_PIXEL. ✓
        ; ZP_CBIT is NOT clobbered by INVERT_PIXEL. ✓
        ; ZP_ROW and ZP_COL are NOT clobbered by INVERT_PIXEL. ✓
        ; ZP_SRC (right_col) is NOT clobbered by INVERT_PIXEL. ✓

.ppm_skip:
        RTS
