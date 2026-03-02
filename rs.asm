; rs.asm — GF(256) arithmetic and Reed-Solomon encoding
; GF(256) with primitive polynomial 0x11D (x^8+x^4+x^3+x^2+1)
; Per QR Code Standard ISO 18004. Alpha = 2 = primitive element.
;
; RAM tables (built by GF_BUILD_TABLES at startup):
;   GF_LOG  @ $8000  (256B)  GF_LOG[v] = discrete log of v
;                            GF_LOG[0] = $FF (undefined sentinel)
;   GF_ALOG @ $8100  (256B)  GF_ALOG[i] = alpha^i
;                            GF_ALOG[255] = 1 (wrap alias = GF_ALOG[0])
;
; Working buffers:
;   RS_GENPOLY @ $8200  (31B)  generator polynomial coefficients
;   RS_REM     @ $8220  (30B)  remainder accumulator / EC codewords
;
; All scratch buffers use $7100-$82FF (free RAM between QR binary and ProDOS).
; BASIC.SYSTEM loads at $2000-$5FFF on ProDOS BASIC 48K systems.
; The trampoline+string data uses $7000-$70FF, so $7100+ is safe.

GF_LOG     = $8000
GF_ALOG    = $8100
RS_GENPOLY = $8200
RS_REM     = $8220

; ── GF_BUILD_TABLES ──────────────────────────────────────────────
; Build GF_LOG and GF_ALOG in RAM. Call once at startup.
; Clobbers: A, X, Y

GF_BUILD_TABLES:
        LDA     #$FF
        STA     GF_LOG          ; LOG[0] = $FF (undefined)
        LDA     #1              ; val = alpha^0 = 1
        LDX     #0              ; exponent i = 0
.gbt:
        STA     GF_ALOG,X       ; ALOG[i] = val
        TAY
        TXA
        STA     GF_LOG,Y        ; LOG[val] = i   (Y = val, used as index)
        TYA                     ; restore val
        ASL                     ; val *= 2 (multiply by alpha = 2)
        BCC     .gbt_nr
        EOR     #$1D            ; reduce mod x^8+x^4+x^3+x^2+1 (0x11D lower bits)
.gbt_nr:
        INX
        CPX     #$FF            ; 255 iterations (i = 0..254)
        BNE     .gbt
        LDA     #1
        STA     GF_ALOG+$FF     ; ALOG[255] = 1 = ALOG[0] (wrap alias for GF_MUL)
        RTS

; ── GF_MUL ───────────────────────────────────────────────────────
; Multiply two GF(256) elements using log/antilog tables.
; Input:  A = operand a,  X = operand b
; Output: A = a * b in GF(256);  A = 0 if either input is 0
; Scratch: ZP_TMP ($FB) clobbered  — callers must not rely on ZP_TMP
; Clobbers: A, X, ZP_TMP

GF_MUL:
        BEQ     .gfm_zero       ; a = 0 → result 0
        STA     ZP_TMP          ; save a
        TXA
        BEQ     .gfm_zero       ; b = 0 → result 0
        TAX                     ; X = b
        LDA     GF_LOG,X        ; A = LOG[b]
        LDX     ZP_TMP          ; X = a
        CLC
        ADC     GF_LOG,X        ; A = LOG[b] + LOG[a]
        BCC     .gfm_ok
        ADC     #0              ; carry set: (sum + 256) mod 255 = result + 1
.gfm_ok:
        ; A = exponent index, 0..254 or 255.
        ; ALOG[255] = 1 is stored, so A = 255 is handled correctly.
        TAX
        LDA     GF_ALOG,X
        RTS
.gfm_zero:
        LDA     #0
        RTS

; ── RS_GEN_POLY ──────────────────────────────────────────────────
; Build RS generator polynomial of degree N.
; Result in RS_GENPOLY[0..N]: [0] = constant term, [N] = 1 (monic).
; poly = ∏(x + alpha^i)  for i = 0..N-1
;
; Correct in-place multiply algorithm (high-to-low traversal ensures
; old[j-1] is read before overwriting old[j]):
;   for j = current_degree downto 0:
;     if j > 0: poly[j] = poly[j-1] XOR GF_MUL(root, poly[j])
;     else:     poly[0] = GF_MUL(root, poly[0])
;
; Input:  A = N  (max 30)
; Clobbers: A, X, Y, ZP_TMP, ZP_TMP2, ZP_CBIT, ZP_BITPOS

RS_GEN_POLY:
        STA     ZP_CBIT         ; ZP_CBIT = N (target degree)
        ; Init poly = [1], degree 0:
        LDA     #1
        STA     RS_GENPOLY
        LDA     #0
        LDX     #1
.rgp_clr:
        STA     RS_GENPOLY,X
        INX
        CPX     ZP_CBIT
        BNE     .rgp_clr
        STA     RS_GENPOLY,X    ; slot [N] = 0 (set to 1 at end)

        LDA     #1
        STA     ZP_BITPOS       ; current root = alpha^0 = 1
        LDX     #0              ; current poly degree (grows from 0 to N)

.rgp_outer:
        CPX     ZP_CBIT
        BEQ     .rgp_monic

        STX     ZP_TMP2         ; save degree (ZP_TMP clobbered by GF_MUL; ZP_TMP2 is NOT)
        TXA
        CLC
        ADC     #1              ; Y = current_degree + 1 (process new leading slot first)
        TAY

.rgp_inner:
        ; Correct formula (high to low, in-place):
        ;   Y > 0: poly[Y] = poly[Y-1] XOR GF_MUL(root, poly[Y])
        ;   Y = 0: poly[0] = GF_MUL(root, poly[0])
        CPY     #0
        BEQ     .rgp_j0
        ; Y > 0: poly[Y] = poly[Y-1] XOR root * poly[Y]
        LDA     ZP_BITPOS           ; root (arg a for GF_MUL)
        LDX     RS_GENPOLY,Y        ; poly[Y] (arg b)
        JSR     GF_MUL              ; A = root * poly[Y]
        ; GF_MUL clobbered ZP_TMP but not ZP_TMP2 or Y.
        EOR     RS_GENPOLY-1,Y      ; XOR with poly[Y-1]
        STA     RS_GENPOLY,Y
        DEY
        BPL     .rgp_inner          ; continue downward (including Y=0)
.rgp_j0:
        ; Y = 0: poly[0] = GF_MUL(root, poly[0])
        LDA     ZP_BITPOS           ; root
        LDX     RS_GENPOLY          ; poly[0]
        JSR     GF_MUL              ; A = root * poly[0]
        STA     RS_GENPOLY          ; poly[0] updated

        LDX     ZP_TMP2         ; restore degree
        INX                     ; degree += 1

        ; Advance root: alpha^(i+1) = 2 * alpha^i in GF
        LDA     ZP_BITPOS
        ASL
        BCC     .rgp_nr
        EOR     #$1D
.rgp_nr:
        STA     ZP_BITPOS
        JMP     .rgp_outer

.rgp_monic:
        LDA     #1
        STA     RS_GENPOLY,X    ; ensure monic leading coefficient
        RTS

; ── RS_ENCODE_BLOCK ──────────────────────────────────────────────
; Compute EC codewords for one RS block using polynomial remainder.
;
; Standard QR RS encoding algorithm:
;   Initialize rem[0..n_ec-1] = 0
;   For each data byte d[i]:
;     fb = d[i] XOR rem[0]
;     For j = 0 to n_ec-2:
;       rem[j] = rem[j+1] XOR GF_MUL(fb, genpoly[n_ec-1-j])
;     rem[n_ec-1] = GF_MUL(fb, genpoly[0])
;
; ZP register usage:
;   ZP_CBIT ($FA)  = n_data       (not touched by GF_MUL)
;   ZP_TMP  ($FB)  = GF_MUL scratch (clobbered)
;   ZP_TMP2 ($FC)  = n_ec         (not touched by GF_MUL)
;   ZP_BITPOS ($FD) = feedback byte (not touched by GF_MUL)
;   ZP_PTR ($06)   = pointer to data block
;   Y = inner loop index (not touched by GF_MUL)
;
; Input:
;   ZP_PTR  → data codewords (ZP_TMP bytes)
;   ZP_TMP  = n_data
;   ZP_TMP2 = n_ec  (RS_GENPOLY pre-built for this degree)
; Output:
;   RS_REM[0..n_ec-1] = EC codewords
; Clobbers: A, X, Y, ZP_CBIT, ZP_TMP, ZP_BITPOS

RS_ENCODE_BLOCK:
        ; Save n_data to safe ZP location before GF_MUL can clobber ZP_TMP:
        LDA     ZP_TMP
        STA     ZP_CBIT         ; n_data

        ; Zero RS_REM[0..n_ec-1]:
        LDX     ZP_TMP2         ; n_ec
        LDA     #0
.reb_zero:
        STA     RS_REM-1,X
        DEX
        BNE     .reb_zero

        ; Outer loop: Y = data byte index (0..n_data-1)
        LDY     #0
.reb_outer:
        CPY     ZP_CBIT
        BEQ     .reb_done

        ; feedback = data[Y] XOR rem[0]
        LDA     (ZP_PTR),Y
        EOR     RS_REM
        STA     ZP_BITPOS       ; save feedback (ZP_BITPOS not touched by GF_MUL)
        INY                     ; advance outer index (Y preserved by GF_MUL)

        ; Inner loop: process each EC position
        ; Use a secondary Y saved on stack; inner loop uses Y for its own index.
        TYA
        PHA                     ; save outer data index

        LDY     #0              ; inner j = 0
.reb_inner:
        ; Compute genpoly index k = n_ec - 1 - j:
        LDA     ZP_TMP2         ; n_ec  (not touched by GF_MUL — safe ✓)
        SEC
        SBC     #1              ; n_ec - 1
        STY     ZP_TMP          ; ZP_TMP = j  (GF_MUL will clobber, but Y has j)
        SEC
        SBC     ZP_TMP          ; A = n_ec - 1 - j = k
        TAX                     ; X = k = genpoly index
        LDA     RS_GENPOLY,X    ; genpoly[k]
        TAX                     ; X = genpoly[k]  (second arg for GF_MUL)
        LDA     ZP_BITPOS       ; A = feedback  (first arg for GF_MUL)
        JSR     GF_MUL          ; A = fb * genpoly[n_ec-1-j]
        ; Y preserved by GF_MUL ✓. ZP_TMP clobbered (was j copy; we have Y).

        INY                     ; j → j+1 (Y = j+1)
        CPY     ZP_TMP2         ; compare (j+1) with n_ec
        BCS     .reb_last       ; j was n_ec-1 → BCS fires when Y = n_ec

        ; General case: rem[j] = rem[j+1] XOR product
        ; With Y = j+1: rem[j] = RS_REM[Y-1], rem[j+1] = RS_REM[Y]
        EOR     RS_REM,Y        ; A = product XOR rem[j+1]
        STA     RS_REM-1,Y      ; rem[j] = result
        JMP     .reb_inner

.reb_last:
        ; Last inner iteration: rem[n_ec-1] = product (no XOR with next element)
        ; Y = n_ec now, so RS_REM-1 + Y = RS_REM[n_ec-1]
        STA     RS_REM-1,Y

        PLA                     ; restore outer data index
        TAY
        JMP     .reb_outer

.reb_done:
        RTS

; ── RS_COPY_EC ───────────────────────────────────────────────────
; Copy RS_REM[0..n_ec-1] to memory pointed by ZP_PTR2.
; Input: ZP_PTR2 → destination, A = n_ec
; Clobbers: A, X, Y

RS_COPY_EC:
        TAX                     ; X = n_ec (count)
        LDY     #0
.rce:
        LDA     RS_REM,Y
        STA     (ZP_PTR2),Y
        INY
        DEX
        BNE     .rce
        RTS
