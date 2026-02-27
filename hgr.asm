; hgr.asm — HGR init and pixel routines
; Assembled as part of qr.asm (included, not standalone).

; Display placement offsets — shift the QR origin from the screen corner
QR_ROW_OFFSET = 7    ; rows down from top of HGR screen
QR_COL_OFFSET = 7    ; bytes (49 pixels) right from left edge

; ── HGR_INIT ─────────────────────────────────────────────────────
; Call Apple II firmware to clear & show the correct HGR page.
; ZP_PAGE = 0 → HGR page 1 ($2000), firmware sets HPAG ($E6) = $20
; ZP_PAGE = 1 → HGR page 2 ($4000), firmware sets HPAG ($E6) = $40
; After call: page is white ($7F per byte fills done by firmware).
; Clobbers: A, X, Y (firmware may use all)

HGR_INIT:
        LDA     ZP_PAGE
        BNE     HGR_INIT_P2
        JSR     $F3E2           ; firmware HGR: clear page 1, show it
        RTS
HGR_INIT_P2:
        JSR     $F3D8           ; firmware HGR2: clear page 2, show it
        RTS

; ── INVERT_PIXEL ─────────────────────────────────────────────────
; XOR the pixel at (ZP_ROW, ZP_COL) in the current HGR page.
; Starting from an all-white page ($7F each byte), one invert
; sets a pixel dark; a second invert clears it back to white.
; Each QR module is touched exactly once, so SET = dark, CLEAR = skip.
;
; Input:  ZP_ROW (Y coord, 0-based), ZP_COL (X coord, 0-based)
;         HPAG ($E6) = page base hi-byte ($20 or $40) — set by firmware
; Output: pixel at (ZP_ROW, ZP_COL) inverted
; Clobbers: A, ZP_TMP, ZP_TMP2, ZP_PTR (2B)
;
; Address formula:
;   y_hi = ZP_ROW >> 3
;   y_lo = ZP_ROW & 7
;   byte_addr = (HPAG + ROW_OFS_HI[y_hi] + y_lo*4) * 256 + ROW_OFS_LO[y_hi]
;             + ZP_COL / 7
;   bit_mask  = 1 << (ZP_COL mod 7)

INVERT_PIXEL:
        ; -- compute row address (apply QR_ROW_OFFSET display offset) --
        LDA     ZP_ROW
        CLC
        ADC     #QR_ROW_OFFSET  ; shift display down by QR_ROW_OFFSET rows
        AND     #$07            ; y_lo = (ZP_ROW + offset) & 7
        ASL                     ; y_lo * 2
        ASL                     ; y_lo * 4
        STA     ZP_TMP          ; save y_lo*4

        LDA     ZP_ROW
        CLC
        ADC     #QR_ROW_OFFSET  ; shift display down by QR_ROW_OFFSET rows
        LSR                     ; >> 1
        LSR                     ; >> 2
        LSR                     ; >> 3  = y_hi (0-23)
        TAX                     ; X = y_hi (index into row tables)

        CLC
        LDA     ROW_OFS_HI,X    ; page-relative hi offset
        ADC     ZP_TMP          ; + y_lo*4
        ADC     HPAG            ; + page base hi-byte
        STA     ZP_PTR+1        ; hi byte of row address

        LDA     ROW_OFS_LO,X    ; lo byte of row address
        STA     ZP_PTR          ; ZP_PTR = full row base address

        ; -- compute byte offset within row: ZP_COL / 7 --
        ; For 0-279 range, divide by 7 (40 bytes/row).
        ; Approximate: byte = (ZP_COL * 37) >> 8  (error-free 0-279)
        ; But simplest correct method: subtract 7 repeatedly.
        ; Fast: use reciprocal multiply. ZP_COL/7 = ZP_COL * 0x25 >> 8
        ; Actually: floor(c/7) = (c * 37) >> 8 works for c <= 259 only.
        ; Use: byte = (ZP_COL * 147) >> 10  (works 0-279):
        ;   147/1024 ≈ 1/7 (error: max 0 for 0-279)
        ; Simplest safe method: table or loop. For code size, use loop.
        LDA     ZP_COL
        STA     ZP_TMP2         ; remainder
        LDX     #$FF            ; quotient - 1
.div7:
        INX
        SEC
        SBC     #7
        BCS     .div7           ; while remainder >= 7
        ; Loop exits one iteration past the boundary (A is negative).
        ; Recover correct remainder by adding 7 back:
        CLC
        ADC     #7              ; A = ZP_COL mod 7 (0-6), corrected
        ; X = ZP_COL / 7 (byte index), A = ZP_COL mod 7 (bit index)
        ; bit index A: build mask 1 << A
        TAY                     ; Y = bit position (0-6)

        ; -- add byte offset + QR_COL_OFFSET to ZP_PTR --
        TXA                     ; byte offset from QR column
        CLC
        ADC     #QR_COL_OFFSET  ; shift display right by QR_COL_OFFSET bytes (49 pixels)
        ADC     ZP_PTR          ; add to lo byte (carry from prev add is always 0)
        STA     ZP_PTR
        BCC     .no_carry
        INC     ZP_PTR+1
.no_carry:

        ; -- build bit mask: 1 << Y --
        LDA     #$01
        CPY     #0
        BEQ     .has_mask
.shift_bit:
        ASL
        DEY
        BNE     .shift_bit
.has_mask:
        ; -- XOR bit into HGR byte --
        ; Y is 0 here (shift loop exited on DEY→0, or BEQ jumped directly).
        ; A holds the bit mask (1 << bit_position).
        LDY     #0
        EOR     (ZP_PTR),Y
        STA     (ZP_PTR),Y
        RTS

; ── HGR_DARK ─────────────────────────────────────────────────────
; Set pixel at (ZP_ROW, ZP_COL) to dark (black).
; On a white-initialized page, this is simply INVERT_PIXEL.
; Provided as a named alias for clarity in matrix drawing code.
HGR_DARK    = INVERT_PIXEL

; ── HGR_FILLROW ──────────────────────────────────────────────────
; Fill ZP_SIZE bytes starting at column ZP_COL in row ZP_ROW
; with value in A. Used to draw separator white rows/cols.
; Input:  A = fill value, ZP_ROW, ZP_COL set, ZP_SIZE = count
; Clobbers: A, X, Y, ZP_TMP, ZP_TMP2, ZP_PTR

HGR_FILLROW:
        STA     ZP_TMP2         ; save fill value
        ; Compute address of (ZP_ROW, ZP_COL) then fill ZP_SIZE bytes
        LDA     ZP_ROW
        AND     #$07
        ASL
        ASL
        STA     ZP_TMP
        LDA     ZP_ROW
        LSR
        LSR
        LSR
        TAX
        CLC
        LDA     ROW_OFS_HI,X
        ADC     ZP_TMP
        ADC     HPAG
        STA     ZP_PTR+1
        LDA     ROW_OFS_LO,X
        STA     ZP_PTR
        ; add ZP_COL/7 to get start byte
        LDA     ZP_COL
        LDX     #$FF
.fr_div:
        INX
        SEC
        SBC     #7
        BCS     .fr_div
        TXA
        CLC
        ADC     ZP_PTR
        STA     ZP_PTR
        BCC     .fr_nc
        INC     ZP_PTR+1
.fr_nc:
        LDY     ZP_SIZE
        LDA     ZP_TMP2
.fr_loop:
        DEY
        STA     (ZP_PTR),Y
        BNE     .fr_loop
        RTS
