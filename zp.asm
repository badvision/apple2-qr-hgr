; zp.asm — Zero Page equates for QR code generator
; All locations verified safe per kreativekorp + fadden zero-page.txt

; ── Caller sets these before JSR QR_GENERATE ──────────────────────
ZP_SRC    = $EB  ; (2B) lo/hi of input data address
ZP_LEN    = $ED  ; (2B) lo/hi of input data length
ZP_PAGE   = $EF  ; (1B) 0=HGR page1 / 1=HGR page2

; ── Free when Sweet-16 not active (we never call it) ──────────────
ZP_PTR    = $06  ; (2B) general pointer — inner loops LDA (ZP_PTR),Y
ZP_PTR2   = $08  ; (2B) second pointer

; ── Integer BASIC only — safe since we never invoke it ────────────
ZP_ROW    = $CE  ; (1B) current QR row
ZP_COL    = $CF  ; (1B) current QR column

; ── Integer BASIC scratch — same safety argument ──────────────────
ZP_SIZE   = $D7  ; (1B) modules/side = 4*VER+17

; ── Kreativekorp "Free Space" ─────────────────────────────────────
ZP_VER    = $E3  ; (1B) QR version 1-40

; ── Applesoft math temp — safe: Applesoft not running during us ───
ZP_CBIT   = $FA  ; (1B) current data bit being placed (0-7)
ZP_TMP    = $FB  ; (1B) scratch byte
ZP_TMP2   = $FC  ; (1B) scratch byte
ZP_BITPOS = $FD  ; (2B) bit index into interleaved codeword stream

; ── HGR firmware sets this: $20 after HGR, $40 after HGR2 ────────
HPAG      = $E6  ; HGR page base hi-byte (firmware-managed)

; ── Firmware entry points ─────────────────────────────────────────
HGR_ROM   = $F3E2  ; HPLOT warm entry (not used — too slow)
HGR1_INIT = $F3E2  ; firmware: clear & show HGR page 1 ($F3E2 = HGR)
HGR2_INIT = $F3D8  ; firmware: clear & show HGR page 2

; actual ROM vectors
FW_HGR    = $F3E2  ; JSR here to init HGR page 1
FW_HGR2   = $F3D8  ; JSR here to init HGR page 2
