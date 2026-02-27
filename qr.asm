; qr.asm — QR Code Generator for Apple II HGR
; Assemble: acme -f plain -o qr.bin --setpc 6000 qr.asm
;   (plain binary with explicit load address)
;   Then: BLOAD QR.BIN,A$6000   (or monitor: CALL -151, 6000.8FFFR QR.BIN)
;
; Caller sets in zero page before JSR QR_GENERATE:
;   ZP_SRC  ($EB/$EC) = lo/hi address of input data
;   ZP_LEN  ($ED/$EE) = lo/hi length of input data in bytes
;   ZP_PAGE ($EF)     = 0 → HGR page 1 ($2000) / 1 → HGR page 2 ($4000)
;
; On return: carry clear = success, QR code visible on screen
;            carry set   = error (A = $FF: data too long for any version)
;
; RAM layout (outside the binary, used at runtime):
;   $9000-$9EFF  CODEWORD_BUF  (3840B codeword scratch)
;   $9F00-$9FFF  GF_LOG        (256B, built by GF_BUILD_TABLES)
;   $A000-$A0FF  GF_ALOG       (256B, built by GF_BUILD_TABLES)
;   $A100-$A11F  RS_GENPOLY    (31B, built by RS_GEN_POLY)
;   $A120-$A13F  RS_REM        (30B, RS remainder)
;   $A150-$A160  alignment scratch (IS_ALIGN_MODULE, DRAW_ALIGNMENT)
;   $2000-$3FFF  HGR page 1 (output A)
;   $4000-$5FFF  HGR page 2 (output B)

        * = $6000               ; entire binary loads at $6000

; ── Zero page equates (no bytes emitted) ─────────────────────────
!src "zp.asm"

; ── Entry point ──────────────────────────────────────────────────
QR_GENERATE:
        ; Step 1: Version selection
        JSR     QR_SELECT_VER
        BCS     .qg_err

        ; Step 2: Build GF(256) tables in RAM
        JSR     GF_BUILD_TABLES

        ; Step 3: Encode data codewords
        JSR     QR_ENCODE_DATA

        ; Step 4: Reed-Solomon error correction (all blocks)
        JSR     QR_RS_ALL_BLOCKS

        ; Step 5: Interleave codewords into final stream
        JSR     QR_INTERLEAVE

        ; Step 6: Initialize HGR page (firmware: clears to white, shows it)
        JSR     HGR_INIT

        ; Step 7: Draw function patterns
        JSR     DRAW_FINDERS
        JSR     DRAW_TIMING
        JSR     DRAW_ALIGNMENT
        JSR     DRAW_DARKMOD

        ; Step 8: (Format info areas already white — no-op)
        JSR     FORMAT_RESERVE

        ; Step 9: Place data bits (zigzag with mask pattern 0)
        ; Re-initialize ZP_PTR for read (PLACE_DATA reads from CODEWORD_BUF):
        LDA     #<CODEWORD_BUF
        STA     ZP_PTR
        LDA     #>CODEWORD_BUF
        STA     ZP_PTR+1
        LDA     #0
        STA     ZP_CBIT         ; bit offset within current byte (0=MSB)
        JSR     PLACE_DATA

        ; Step 10: Write format information
        JSR     FORMAT_INFO

        ; Step 11: Write version information (V7+)
        JSR     VERSION_INFO

        CLC
        RTS
.qg_err:
        LDA     #$FF
        SEC
        RTS

; ── QR_RS_ALL_BLOCKS ─────────────────────────────────────────────
; Run Reed-Solomon encoding for every block in the current version.
; Builds the generator polynomial once (same degree for all blocks),
; then calls RS_ENCODE_BLOCK for each block.
;
; Memory layout assumed by this routine:
;   Input (CODEWORD_BUF):
;     [blk0_data(d1)][blk1_data(d1)]...[g2blk0_data(d2)]...
;     (contiguous, as written by QR_ENCODE_DATA)
;   Output (CODEWORD_BUF, appended after all data):
;     [blk0_ec(ecpb)][blk1_ec(ecpb)]...[g2blk0_ec(ecpb)]...
;     EC for block i written to: CODEWORD_BUF + total_data + i * ecpb
;
; For single-block versions (V1-5): EC bytes immediately follow data,
; so CODEWORD_BUF = [data(d1)][ec(ecpb)] — same as before.
;
; Input:  CODEWORD_BUF[0..total_data-1] filled by QR_ENCODE_DATA
;         ZP_VER set
; Output: CODEWORD_BUF[total_data..total_data+nblk*ecpb-1] = all EC bytes
; Clobbers: A, X, Y, ZP_TMP, ZP_TMP2, ZP_CBIT, ZP_BITPOS, ZP_PTR, ZP_PTR2

QR_RS_ALL_BLOCKS:
        ; Load BLK_PARAMS for this version:
        LDA     ZP_VER
        SEC
        SBC     #1
        STA     ZP_TMP2         ; VER-1
        ASL
        ASL
        CLC
        ADC     ZP_TMP2         ; (VER-1)*5
        TAY

        ; Build generator polynomial (same for all blocks):
        LDA     BLK_PARAMS,Y    ; ecpb = n_ec
        PHA                     ; save n_ec
        JSR     RS_GEN_POLY
        PLA
        STA     ZP_TMP2         ; ZP_TMP2 = n_ec

        ; Recompute BLK_PARAMS offset:
        LDA     ZP_VER
        SEC
        SBC     #1
        STA     ZP_TMP
        ASL
        ASL
        CLC
        ADC     ZP_TMP
        TAY

        ; Compute total_data = b1*d1 + b2*d2 as 16-bit value in ZP_BITPOS:
        ; Use ZP_PTR lo temporarily (it's about to be set anyway).
        LDA     BLK_PARAMS+2,Y  ; d1
        STA     ZP_PTR          ; borrow ZP_PTR lo as d1 scratch
        LDA     #0
        STA     ZP_BITPOS       ; total lo = 0
        STA     ZP_BITPOS+1     ; total hi = 0
        LDA     BLK_PARAMS+1,Y  ; b1
        TAX                     ; X = b1; TAX sets Z if b1=0
        BEQ     .qrs_b1d1_done  ; b1=0: skip
.qrs_b1d1_add:
        CLC
        LDA     ZP_BITPOS
        ADC     ZP_PTR          ; lo += d1
        STA     ZP_BITPOS
        BCC     .qrs_b1d1_nc
        INC     ZP_BITPOS+1     ; hi++ on carry
.qrs_b1d1_nc:
        DEX
        BNE     .qrs_b1d1_add
.qrs_b1d1_done:
        ; Add b2*d2 (if b2 > 0):
        LDA     BLK_PARAMS+3,Y  ; b2
        BEQ     .qrs_no_g2_total
        TAX                     ; X = b2 (count)
        LDA     BLK_PARAMS+4,Y  ; d2
        STA     ZP_PTR          ; borrow ZP_PTR lo as d2 scratch
.qrs_b2d2_add:
        CLC
        LDA     ZP_BITPOS
        ADC     ZP_PTR          ; lo += d2
        STA     ZP_BITPOS
        BCC     .qrs_b2d2_nc
        INC     ZP_BITPOS+1     ; hi++ on carry
.qrs_b2d2_nc:
        DEX
        BNE     .qrs_b2d2_add
.qrs_no_g2_total:

        ; ZP_BITPOS:ZP_BITPOS+1 = total_data (16-bit).
        ; EC dest pointer = CODEWORD_BUF + total_data:
        LDA     #<CODEWORD_BUF
        CLC
        ADC     ZP_BITPOS
        STA     ZP_PTR2
        LDA     #>CODEWORD_BUF
        ADC     ZP_BITPOS+1
        STA     ZP_PTR2+1       ; ZP_PTR2 = CODEWORD_BUF + total_data (EC base)

        ; Data source pointer = CODEWORD_BUF:
        LDA     #<CODEWORD_BUF
        STA     ZP_PTR
        LDA     #>CODEWORD_BUF
        STA     ZP_PTR+1        ; ZP_PTR = CODEWORD_BUF (data base)

        ; Reload BLK_PARAMS offset (Y may be stale):
        LDA     ZP_VER
        SEC
        SBC     #1
        STA     ZP_TMP
        ASL
        ASL
        CLC
        ADC     ZP_TMP
        TAY

        ; Process group 1 blocks:
        LDA     BLK_PARAMS+1,Y  ; b1
        BEQ     .qrs_g2
        STA     ZP_CBIT         ; g1 block counter
        LDA     BLK_PARAMS+2,Y  ; d1
        STA     ZP_TMP          ; n_data for each g1 block

.qrs_g1:
        ; RS_ENCODE_BLOCK: input data at ZP_PTR, n_data in ZP_TMP, n_ec in ZP_TMP2
        ; RS_ENCODE_BLOCK clobbers ZP_CBIT, ZP_TMP — save them:
        LDA     ZP_TMP
        PHA
        LDA     ZP_CBIT
        PHA
        JSR     RS_ENCODE_BLOCK ; RS_REM[0..n_ec-1] = EC bytes
        PLA
        STA     ZP_CBIT
        PLA
        STA     ZP_TMP          ; n_data restored
        ; Copy EC to ZP_PTR2 (EC dest):
        LDA     ZP_TMP2         ; n_ec
        JSR     RS_COPY_EC      ; copies RS_REM[0..n_ec-1] to (ZP_PTR2)
        ; Advance data src by d1 (n_data):
        LDA     ZP_PTR
        CLC
        ADC     ZP_TMP
        STA     ZP_PTR
        BCC     .qrs_g1_src_nc
        INC     ZP_PTR+1
.qrs_g1_src_nc:
        ; Advance EC dest by ecpb (n_ec = ZP_TMP2):
        LDA     ZP_PTR2
        CLC
        ADC     ZP_TMP2
        STA     ZP_PTR2
        BCC     .qrs_g1_ec_nc
        INC     ZP_PTR2+1
.qrs_g1_ec_nc:
        DEC     ZP_CBIT
        BNE     .qrs_g1

.qrs_g2:
        ; Reload params:
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
        BEQ     .qrs_done
        STA     ZP_CBIT
        LDA     BLK_PARAMS+4,Y  ; d2
        STA     ZP_TMP

.qrs_g2_loop:
        LDA     ZP_TMP
        PHA
        LDA     ZP_CBIT
        PHA
        JSR     RS_ENCODE_BLOCK
        PLA
        STA     ZP_CBIT
        PLA
        STA     ZP_TMP
        LDA     ZP_TMP2
        JSR     RS_COPY_EC
        ; Advance data src by d2:
        LDA     ZP_PTR
        CLC
        ADC     ZP_TMP
        STA     ZP_PTR
        BCC     .qrs_g2_src_nc
        INC     ZP_PTR+1
.qrs_g2_src_nc:
        ; Advance EC dest by ecpb:
        LDA     ZP_PTR2
        CLC
        ADC     ZP_TMP2
        STA     ZP_PTR2
        BCC     .qrs_g2_ec_nc
        INC     ZP_PTR2+1
.qrs_g2_ec_nc:
        DEC     ZP_CBIT
        BNE     .qrs_g2_loop

.qrs_done:
        RTS

; ── Included modules (assembled sequentially after entry point) ──
!src "hgr.asm"
!src "rs.asm"
!src "matrix.asm"
!src "encode.asm"
!src "place.asm"
!src "format.asm"
; Tables go last — labels resolve from wherever they land in the binary:
!src "tables.asm"
