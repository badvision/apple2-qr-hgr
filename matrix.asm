; matrix.asm — Draw QR function patterns (finders, timing, alignment, dark mod)
; HGR page is pre-initialized to white ($7F per byte) by firmware.
; Drawing uses INVERT_PIXEL (XOR) to set dark modules.
; ZP_VER and ZP_SIZE must be set before calling any routine here.

; Scratch area for alignment pattern iteration:
; ALN_BASE must be in zero page (required for (ptr),Y indirect addressing).
; $0A-$0B: safe (H2/V2 ROM scratch; we never call HPLOT or Sweet-16).
ALN_BASE   = $0A                ; 2B ZP: lo/hi pointer into ALN_DATA positions
ALN_COUNT  = $8250              ; count of position values for this version (was $5150)
ALN_CR     = $8253              ; center row candidate (was $5153)
ALN_CC     = $8254              ; center col candidate (was $5154)
ALN_IDX_I  = $8255              ; outer loop index (was $5155)
ALN_IDX_J  = $8256              ; inner loop index (was $5156)

; ── IS_FUNC_MODULE ───────────────────────────────────────────────
; Test whether (ZP_ROW, ZP_COL) is a QR reserved function module.
; Input:  ZP_ROW, ZP_COL, ZP_VER, ZP_SIZE
; Output: carry set = function module (skip); carry clear = data module
; Clobbers: A, X, Y, ZP_TMP, ZP_TMP2

; Each "yes" path returns SEC; RTS inline to avoid long forward branches.
IS_FUNC_MODULE:
        ; ── Timing patterns: row 6 or col 6 ──
        LDA     ZP_ROW
        CMP     #6
        BNE     .ifm_t1
        SEC
        RTS
.ifm_t1:
        LDA     ZP_COL
        CMP     #6
        BNE     .ifm_not_timing
        SEC
        RTS
.ifm_not_timing:

        ; ── Finder + separator: 3 corners, each 8×8 ──
        ; Top-left: row 0-7, col 0-7
        LDA     ZP_ROW
        CMP     #8
        BCS     .ifm_not_tl
        LDA     ZP_COL
        CMP     #8
        BCS     .ifm_not_tl
        SEC
        RTS
.ifm_not_tl:
        ; Top-right: row 0-7, col SIZE-8..SIZE-1
        LDA     ZP_ROW
        CMP     #8
        BCS     .ifm_not_tr
        LDA     ZP_SIZE
        SEC
        SBC     #8
        STA     ZP_TMP
        LDA     ZP_COL
        CMP     ZP_TMP
        BCC     .ifm_not_tr
        SEC
        RTS
.ifm_not_tr:
        ; Bottom-left: row SIZE-8..SIZE-1, col 0-7
        LDA     ZP_SIZE
        SEC
        SBC     #8
        STA     ZP_TMP
        LDA     ZP_ROW
        CMP     ZP_TMP
        BCC     .ifm_not_bl
        LDA     ZP_COL
        CMP     #8
        BCS     .ifm_not_bl
        SEC
        RTS
.ifm_not_bl:

        ; ── Format info areas ──
        ; Row 8: cols 0-8 and cols SIZE-8..SIZE-1
        LDA     ZP_ROW
        CMP     #8
        BNE     .ifm_not_row8
        LDA     ZP_COL
        CMP     #9
        BCS     .ifm_row8_hi
        SEC                     ; col 0-8: format info
        RTS
.ifm_row8_hi:
        LDA     ZP_SIZE
        SEC
        SBC     #8
        STA     ZP_TMP
        LDA     ZP_COL
        CMP     ZP_TMP
        BCC     .ifm_not_row8
        SEC                     ; col >= SIZE-8: format info
        RTS
.ifm_not_row8:
        ; Col 8: rows 0-8 and rows SIZE-8..SIZE-1
        LDA     ZP_COL
        CMP     #8
        BNE     .ifm_not_col8
        LDA     ZP_ROW
        CMP     #9
        BCS     .ifm_col8_hi
        SEC                     ; row 0-8: format info
        RTS
.ifm_col8_hi:
        LDA     ZP_SIZE
        SEC
        SBC     #8
        STA     ZP_TMP
        LDA     ZP_ROW
        CMP     ZP_TMP
        BCC     .ifm_not_col8
        SEC                     ; row >= SIZE-8: format info
        RTS
.ifm_not_col8:

        ; ── Dark module: (4*VER+9, 8) ──
        LDA     ZP_VER
        ASL
        ASL                     ; VER * 4
        CLC
        ADC     #9              ; 4*VER + 9
        CMP     ZP_ROW
        BNE     .ifm_not_dark
        LDA     ZP_COL
        CMP     #8
        BNE     .ifm_not_dark
        SEC
        RTS
.ifm_not_dark:

        ; ── Version info: versions 7+ (two 3×6 regions) ──
        LDA     ZP_VER
        CMP     #7
        BCC     .ifm_no_ver     ; V1-6: no version info
        ; Top-right region: row 0-5, col SIZE-11..SIZE-9
        LDA     ZP_ROW
        CMP     #6
        BCS     .ifm_ver_bot    ; row >= 6: not this region
        LDA     ZP_SIZE
        SEC
        SBC     #11
        STA     ZP_TMP
        LDA     ZP_COL
        CMP     ZP_TMP
        BCC     .ifm_ver_bot    ; col < SIZE-11: not this region
        LDA     ZP_SIZE
        SEC
        SBC     #9
        STA     ZP_TMP
        LDA     ZP_COL
        CMP     ZP_TMP          ; compare col with SIZE-9
        BEQ     .ifm_vtr_yes    ; col = SIZE-9: YES
        BCS     .ifm_ver_bot    ; col > SIZE-9: not here
.ifm_vtr_yes:
        SEC                     ; col in [SIZE-11, SIZE-9]: version info
        RTS
.ifm_ver_bot:
        ; Bottom-left region: row SIZE-11..SIZE-9, col 0-5
        LDA     ZP_COL
        CMP     #6
        BCS     .ifm_no_ver     ; col >= 6: not this region
        LDA     ZP_SIZE
        SEC
        SBC     #11
        STA     ZP_TMP
        LDA     ZP_ROW
        CMP     ZP_TMP
        BCC     .ifm_no_ver     ; row < SIZE-11
        LDA     ZP_SIZE
        SEC
        SBC     #9
        STA     ZP_TMP
        LDA     ZP_ROW
        CMP     ZP_TMP          ; compare row with SIZE-9
        BEQ     .ifm_vbl_yes    ; row = SIZE-9: YES
        BCS     .ifm_no_ver     ; row > SIZE-9: not here
.ifm_vbl_yes:
        SEC                     ; row in [SIZE-11, SIZE-9]: version info
        RTS
.ifm_no_ver:

        ; ── Alignment patterns ──
        JSR     IS_ALIGN_MODULE
        BCS     .ifm_yes        ; is an alignment module
        CLC
        RTS
.ifm_yes:
        SEC
        RTS

; ── IS_ALIGN_MODULE ──────────────────────────────────────────────
; Check if (ZP_ROW, ZP_COL) falls within any 5×5 alignment pattern.
; Returns carry set if yes, clear if no.
; Clobbers: A, X, Y, ZP_TMP, ZP_TMP2

IS_ALIGN_MODULE:
        LDA     ZP_VER
        CMP     #2
        BCS     .iam_ok         ; V2+: has alignment patterns
        CLC                     ; V1: no alignment patterns
        RTS
.iam_ok:

        ; Load count and base address for this version's position list:
        LDA     ZP_VER
        SEC
        SBC     #1
        TAX
        LDA     ALN_IDX,X       ; byte offset into ALN_DATA
        TAY
        LDA     ALN_DATA,Y      ; count of position values
        STA     ALN_COUNT
        INY                     ; Y → first position entry

        ; Compute ALN_BASE = &ALN_DATA[Y]:
        LDA     #<ALN_DATA
        STY     ZP_TMP
        CLC
        ADC     ZP_TMP
        STA     ALN_BASE
        LDA     #>ALN_DATA
        ADC     #0
        STA     ALN_BASE+1

        ; Iterate all (i, j) pairs of positions:
        LDA     #0
        STA     ALN_IDX_I
.iam_ol:
        LDA     ALN_IDX_I
        CMP     ALN_COUNT
        BCC     .iam_ol_go      ; i < count: process
        CLC                     ; i >= count: done, return false
        RTS
.iam_ol_go:

        ; center_r = ALN_BASE[i]:
        LDY     ALN_IDX_I
        LDA     (ALN_BASE),Y
        STA     ALN_CR

        ; Check if ZP_ROW in [center_r-2 .. center_r+2]:
        LDA     ALN_CR
        SEC
        SBC     #2
        STA     ZP_TMP
        LDA     ZP_ROW
        CMP     ZP_TMP
        BCC     .iam_row_miss   ; row < center_r-2
        LDA     ALN_CR
        CLC
        ADC     #2
        STA     ZP_TMP
        LDA     ZP_ROW
        CMP     ZP_TMP
        BEQ     .iam_row_ok
        BCS     .iam_row_miss   ; row > center_r+2
        JMP     .iam_row_ok
.iam_row_miss:
        JMP     .iam_ol_next
.iam_row_ok:
        ; Row is within range. Check all columns:
        LDA     #0
        STA     ALN_IDX_J
.iam_il:
        LDA     ALN_IDX_J
        CMP     ALN_COUNT
        BCC     .iam_il_go
        JMP     .iam_ol_next    ; j >= count: try next i
.iam_il_go:

        LDY     ALN_IDX_J
        LDA     (ALN_BASE),Y
        STA     ALN_CC

        ; Check if ZP_COL in [center_c-2 .. center_c+2]:
        LDA     ALN_CC
        SEC
        SBC     #2
        STA     ZP_TMP
        LDA     ZP_COL
        CMP     ZP_TMP
        BCC     .iam_il_next    ; col < center_c-2
        LDA     ALN_CC
        CLC
        ADC     #2
        STA     ZP_TMP
        LDA     ZP_COL
        CMP     ZP_TMP
        BEQ     .iam_col_ok
        BCS     .iam_il_next    ; col > center_c+2
.iam_col_ok:
        ; (ZP_ROW, ZP_COL) is within 5×5 area of (ALN_CR, ALN_CC).
        ; Return alignment=true ONLY if this center was actually drawn.
        ; DRAW_ALIGNMENT skips centers that overlap finder patterns:
        ;   top-left:    cr <= 8 and cc <= 8
        ;   top-right:   cr <= 8 and cc >= SIZE-8
        ;   bottom-left: cr >= SIZE-8 and cc <= 8
        ; (all three checks use "< 9" or ">= SIZE-8" thresholds)
        LDA     ALN_CR
        CMP     #9
        BCS     .iam_check_bot  ; cr >= 9: not top region → check bottom
        ; cr <= 8: check cc for top-left or top-right
        LDA     ALN_CC
        CMP     #9
        BCC     .iam_il_next    ; cc <= 8: top-left finder → skip
        LDA     ZP_SIZE
        SEC
        SBC     #8
        STA     ZP_TMP2         ; ZP_TMP2 = SIZE-8
        LDA     ALN_CC
        CMP     ZP_TMP2
        BCS     .iam_il_next    ; cc >= SIZE-8: top-right finder → skip
        JMP     .iam_yes        ; cr <= 8 but cc not near any finder corner → drawn
.iam_check_bot:
        ; cr >= 9: check if cr >= SIZE-8 (bottom region)
        LDA     ZP_SIZE
        SEC
        SBC     #8
        STA     ZP_TMP2         ; ZP_TMP2 = SIZE-8
        LDA     ALN_CR
        CMP     ZP_TMP2
        BCC     .iam_yes        ; cr < SIZE-8: not near any finder → drawn
        ; cr >= SIZE-8: bottom region → skip if cc <= 8
        LDA     ALN_CC
        CMP     #9
        BCS     .iam_yes        ; cc >= 9: bottom-right region → drawn
        JMP     .iam_il_next    ; cc <= 8: bottom-left finder → skip
.iam_yes:
        SEC
        RTS

.iam_il_next:
        INC     ALN_IDX_J
        JMP     .iam_il
.iam_ol_next:
        INC     ALN_IDX_I
        JMP     .iam_ol

; ── DRAW_FINDER ──────────────────────────────────────────────────
; Draw one 7×7 finder pattern.
; Input: ZP_ROW, ZP_COL = top-left corner of 7×7 region
; Pattern bit patterns (bit 7 = leftmost col, drawn via ASL → carry):
;   Row 0: 11111110 ($FE)
;   Row 1: 10000010 ($82)
;   Row 2: 10111010 ($BA)
;   Row 3: 10111010 ($BA)
;   Row 4: 10111010 ($BA)
;   Row 5: 10000010 ($82)
;   Row 6: 11111110 ($FE)
; (bit 7 = leftmost col in 7-pixel sequence; bit 1 = rightmost; bit 0 = unused)
; Clobbers: A, X, Y, ZP_TMP, ZP_TMP2, ZP_BITPOS, ZP_PTR

DRAW_FINDER:
        ; Save origin
        LDA     ZP_ROW
        STA     ZP_TMP          ; origin row
        LDA     ZP_COL
        STA     ZP_TMP2         ; origin col

        LDX     #0              ; row offset (0-6)
.df_row:
        CPX     #7
        BEQ     .df_done

        ; Set ZP_ROW = origin_row + X:
        LDA     ZP_TMP
        STX     ZP_BITPOS+1     ; save X
        CLC
        ADC     ZP_BITPOS+1     ; origin_row + X
        STA     ZP_ROW

        ; Load column pattern for this row:
        LDA     .df_patterns,X
        STA     ZP_BITPOS       ; bit pattern (bit7=leftmost)

        ; Draw 7 columns:
        LDY     #0              ; column offset
.df_col:
        CPY     #7
        BEQ     .df_next_row
        ASL     ZP_BITPOS       ; shift out bit 7 → carry = should_draw
        BCC     .df_col_skip
        ; Dark pixel at (ZP_ROW, origin_col + Y):
        ; Compute ZP_COL = origin_col + Y BEFORE any register clobbering.
        ; ZP_TMP2 = origin_col (untouched here); Y = col offset.
        TYA                     ; A = Y (col offset)
        CLC
        ADC     ZP_TMP2         ; A = origin_col + Y (ZP_TMP2 intact)
        STA     ZP_COL          ; ZP_COL = origin_col + Y (CORRECT)
        ; Save Y, origin_row (ZP_TMP), origin_col (ZP_TMP2), and X (ZP_BITPOS+1)
        ; before calling INVERT_PIXEL which clobbers ZP_TMP and ZP_TMP2:
        TYA
        PHA                     ; save Y (col offset)
        LDA     ZP_TMP
        PHA                     ; save origin_row
        LDA     ZP_TMP2
        PHA                     ; save origin_col
        LDA     ZP_BITPOS+1
        PHA                     ; save X (row offset)
        JSR     INVERT_PIXEL
        PLA
        STA     ZP_BITPOS+1     ; restore X
        PLA
        STA     ZP_TMP2         ; restore origin_col
        PLA
        STA     ZP_TMP          ; restore origin_row
        PLA
        TAY                     ; restore Y (col offset)
.df_col_skip:
        INY
        JMP     .df_col
.df_next_row:
        LDX     ZP_BITPOS+1     ; restore X
        INX
        JMP     .df_row
.df_done:
        ; Restore ZP_ROW and ZP_COL to origin:
        LDA     ZP_TMP
        STA     ZP_ROW
        LDA     ZP_TMP2
        STA     ZP_COL
        RTS

.df_patterns:
!byte $FE, $82, $BA, $BA, $BA, $82, $FE

; ── DRAW_FINDERS ─────────────────────────────────────────────────
; Draw all three finder patterns at their standard QR positions.
; Clobbers: same as DRAW_FINDER

DRAW_FINDERS:
        LDA     #0
        STA     ZP_ROW
        STA     ZP_COL
        JSR     DRAW_FINDER

        LDA     #0
        STA     ZP_ROW
        LDA     ZP_SIZE
        SEC
        SBC     #7
        STA     ZP_COL
        JSR     DRAW_FINDER

        LDA     ZP_SIZE
        SEC
        SBC     #7
        STA     ZP_ROW
        LDA     #0
        STA     ZP_COL
        JSR     DRAW_FINDER
        RTS

; ── DRAW_TIMING ──────────────────────────────────────────────────
; Draw timing patterns (alternating dark/light, dark at even positions).
; Row timing: row=6, col=8..SIZE-9
; Col timing: col=6, row=8..SIZE-9
; HGR is white; only dark (even position) pixels are inverted.
; Clobbers: A, ZP_ROW, ZP_COL, ZP_BITPOS

DRAW_TIMING:
        LDA     ZP_SIZE
        SEC
        SBC     #8
        STA     ZP_BITPOS       ; SIZE-8 = exclusive end; ZP_BITPOS safe from INVERT_PIXEL

        ; Row timing: row=6
        LDA     #6
        STA     ZP_ROW
        LDA     #8
        STA     ZP_COL
.dt_r:
        LDA     ZP_COL
        CMP     ZP_BITPOS       ; ZP_BITPOS not clobbered by INVERT_PIXEL
        BCS     .dt_r_done
        AND     #1              ; col & 1: dark if even (col & 1 = 0)
        BNE     .dt_r_next
        JSR     INVERT_PIXEL
.dt_r_next:
        INC     ZP_COL
        JMP     .dt_r
.dt_r_done:

        ; Col timing: col=6
        LDA     #6
        STA     ZP_COL
        LDA     #8
        STA     ZP_ROW
.dt_c:
        LDA     ZP_ROW
        CMP     ZP_BITPOS       ; ZP_BITPOS not clobbered by INVERT_PIXEL
        BCS     .dt_c_done
        AND     #1
        BNE     .dt_c_next
        JSR     INVERT_PIXEL
.dt_c_next:
        INC     ZP_ROW
        JMP     .dt_c
.dt_c_done:
        RTS

; ── DRAW_ALIGNMENT ───────────────────────────────────────────────
; Draw all alignment patterns for this version (V2+).
; Each is a 5×5 region with 3 rings: dark border, light ring, dark center.
; Centers at all (pos[i], pos[j]) that don't overlap finder patterns.
; Clobbers: A, X, Y, ZP_ROW, ZP_COL, ZP_TMP, ZP_TMP2, ZP_BITPOS, ZP_PTR

DRAW_ALIGNMENT:
        LDA     ZP_VER
        CMP     #2
        BCS     .da_v2_plus     ; V2+: draw alignment patterns
        RTS                     ; V1: nothing to draw
.da_v2_plus:

        ; Load position list:
        LDA     ZP_VER
        SEC
        SBC     #1
        TAX
        LDA     ALN_IDX,X
        TAY
        LDA     ALN_DATA,Y
        STA     ALN_COUNT
        INY
        LDA     #<ALN_DATA
        STY     ZP_TMP
        CLC
        ADC     ZP_TMP
        STA     ALN_BASE
        LDA     #>ALN_DATA
        ADC     #0
        STA     ALN_BASE+1

        LDA     #0
        STA     ALN_IDX_I
.da_ol:
        LDA     ALN_IDX_I
        CMP     ALN_COUNT
        BCC     .da_ol_go       ; i < count: process
        RTS                     ; i >= count: done
.da_ol_go:
        LDY     ALN_IDX_I
        LDA     (ALN_BASE),Y
        STA     ALN_CR

        LDA     #0
        STA     ALN_IDX_J
.da_il:
        LDA     ALN_IDX_J
        CMP     ALN_COUNT
        BCC     .da_il_go       ; j < count: process
        JMP     .da_ol_next     ; j >= count: advance outer loop
.da_il_go:

        LDY     ALN_IDX_J
        LDA     (ALN_BASE),Y
        STA     ALN_CC

        ; Skip if center overlaps finder (corners of matrix):
        LDA     ALN_CR
        CMP     #9              ; cr ≤ 8?
        BCS     .da_check2      ; cr >= 9: not top region
        LDA     ALN_CC
        CMP     #9
        BCC     .da_skip        ; top-left finder
        LDA     ZP_SIZE
        SEC
        SBC     #8
        STA     ZP_TMP
        LDA     ALN_CC
        CMP     ZP_TMP
        BCS     .da_skip        ; top-right finder
.da_check2:
        LDA     ZP_SIZE
        SEC
        SBC     #8
        STA     ZP_TMP
        LDA     ALN_CR
        CMP     ZP_TMP
        BCC     .da_draw        ; cr < SIZE-8: not bottom region
        LDA     ALN_CC
        CMP     #9
        BCC     .da_skip        ; bottom-left finder

.da_draw:
        ; Draw 5×5 alignment pattern:
        ; Row pattern (bit7 = leftmost of 5 pixels, bit3=rightmost, bits2-0 unused):
        ;   Rows -2, +2: 11111000 = $F8  (all dark)
        ;   Rows -1, +1: 10001000 = $88  (dark, 3 light, dark)
        ;   Row  0:      10101000 = $A8  (dark, light, dark, light, dark)
        LDX     #0              ; row offset (0-4)
.da_pat:
        CPX     #5
        BEQ     .da_skip

        LDA     ALN_CR
        SEC
        SBC     #2              ; cr - 2 = top row of pattern
        STX     ZP_TMP
        CLC
        ADC     ZP_TMP          ; row = cr-2 + X
        STA     ZP_ROW

        LDA     .da_patterns,X
        STA     ZP_BITPOS

        LDY     #0
.da_col:
        CPY     #5
        BEQ     .da_next_row
        ASL     ZP_BITPOS
        BCC     .da_col_skip
        ; Dark pixel at (ZP_ROW, ALN_CC-2+Y):
        LDA     ALN_CC
        SEC
        SBC     #2
        STY     ZP_TMP
        CLC
        ADC     ZP_TMP          ; col = cc-2 + Y
        STA     ZP_COL
        TYA
        PHA
        STX     ZP_BITPOS+1     ; save X (row offset)
        JSR     INVERT_PIXEL
        LDX     ZP_BITPOS+1
        PLA
        TAY
.da_col_skip:
        INY
        JMP     .da_col
.da_next_row:
        LDX     ZP_BITPOS+1
        INX
        JMP     .da_pat

.da_skip:
        INC     ALN_IDX_J
        JMP     .da_il
.da_ol_next:
        INC     ALN_IDX_I
        JMP     .da_ol
.da_done:
        RTS

; Alignment pattern row bit patterns (bit7=leftmost of 5 pixels):
.da_patterns:
!byte $F8, $88, $A8, $88, $F8

; ── DRAW_DARKMOD ─────────────────────────────────────────────────
; Draw the single mandatory dark module at (4*VER+9, 8).
; Clobbers: A, ZP_ROW, ZP_COL

DRAW_DARKMOD:
        LDA     ZP_VER
        ASL
        ASL
        CLC
        ADC     #9
        STA     ZP_ROW
        LDA     #8
        STA     ZP_COL
        JMP     INVERT_PIXEL    ; tail call

; ── FORMAT_RESERVE ───────────────────────────────────────────────
; Placeholder: format areas are already white (initialized by firmware).
; FORMAT_INFO will write the correct dark bits later.
FORMAT_RESERVE:
        RTS
