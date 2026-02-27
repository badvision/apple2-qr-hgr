; tables.asm — ROM-resident lookup tables for QR code generator
; Assembled at $A200 (included by qr.asm, not standalone)
; GF(256) log/antilog are RAM-generated at startup — 0 bytes here.

; ── HGR row address partial table ────────────────────────────────
; 24 entries for Y where (Y & 7) = 0, i.e., Y = 0,8,16,...,184
; Stored as page-relative offsets (add HPAG to hi-byte at runtime).
; For any Y: y_hi = Y>>3, y_lo = Y&7
;   lo = ROW_LO[y_hi]
;   hi = ROW_HI[y_hi] + y_lo * 4 + HPAG
; Formula: offset = $80*(y_hi & 7) + $28*(y_hi >> 3)

ROW_OFS_LO:
;        0     1     2     3     4     5     6     7
!byte $00, $80, $00, $80, $00, $80, $00, $80   ; y_hi 0-7
!byte $28, $A8, $28, $A8, $28, $A8, $28, $A8   ; y_hi 8-15
!byte $50, $D0, $50, $D0, $50, $D0, $50, $D0   ; y_hi 16-23

ROW_OFS_HI:
;        0     1     2     3     4     5     6     7
!byte $00, $00, $01, $01, $02, $02, $03, $03   ; y_hi 0-7
!byte $00, $00, $01, $01, $02, $02, $03, $03   ; y_hi 8-15
!byte $00, $00, $01, $01, $02, $02, $03, $03   ; y_hi 16-23

; ── L-level byte capacity (2 bytes/version as !word, 40 entries = 80B) ──────
; Values = max data bytes in byte mode at EC level L (ISO 18004:2015 Table 7).
; Accessed via CAP_TABLE + (version-1)*2. Verify V20+ against spec.

CAP_TABLE:
; V1-V10
!word  17,  32,  53,  78, 106, 134, 154, 192, 230, 271
; V11-V20
!word 321, 367, 425, 458, 520, 586, 644, 718, 792, 858
; V21-V30
!word 929,1003,1091,1171,1273,1367,1465,1528,1628,1732
; V31-V40
!word 1840,1952,2068,2188,2303,2431,2563,2699,2809,2953

; ── L-level RS block parameters (5B/version × 40 = 200B) ─────────
; Format per entry: ecpb, b1, d1, b2, d2
;   ecpb = EC codewords per block
;   b1   = number of blocks in group 1
;   d1   = data codewords per block in group 1
;   b2   = number of blocks in group 2 (0 = no group 2)
;   d2   = data codewords per block in group 2
; Source: ISO 18004:2015 Table 9. Verify V21+ against spec.

BLK_PARAMS:
; V1
!byte  7, 1, 19, 0,  0
; V2
!byte 10, 1, 34, 0,  0
; V3
!byte 15, 1, 55, 0,  0
; V4
!byte 20, 1, 80, 0,  0
; V5
!byte 26, 1,108, 0,  0
; V6
!byte 18, 2, 68, 0,  0
; V7
!byte 20, 2, 78, 0,  0
; V8
!byte 24, 2, 97, 0,  0
; V9
!byte 30, 2,116, 0,  0
; V10
!byte 18, 2, 68, 2, 69
; V11
!byte 20, 4, 81, 0,  0
; V12
!byte 24, 2, 92, 2, 93
; V13
!byte 26, 4,107, 0,  0
; V14
!byte 30, 3,115, 1,116
; V15
!byte 22, 5, 87, 1, 88
; V16
!byte 24, 5, 98, 1, 99
; V17
!byte 28, 1,107, 5,108
; V18
!byte 30, 5,120, 1,121
; V19
!byte 28, 3,113, 4,114
; V20
!byte 28, 3,107, 5,108
; V21
!byte 28, 4,116, 4,117
; V22
!byte 28, 2,111, 7,112
; V23
!byte 30, 4,121, 5,122
; V24
!byte 30, 6,117, 4,118
; V25
!byte 26, 8,106, 4,107
; V26
!byte 28,10,114, 2,115
; V27
!byte 30, 8,122, 4,123
; V28
!byte 30, 3,117,10,118
; V29
!byte 30, 7,116, 7,117
; V30
!byte 30, 5,115,10,116
; V31
!byte 30,13,115, 3,116
; V32
!byte 30,17,115, 0,  0
; V33
!byte 30,17,115, 1,116
; V34
!byte 30,13,115, 6,116
; V35
!byte 30,12,121, 7,122
; V36
!byte 30, 6,121,14,122
; V37
!byte 30,17,122, 4,123
; V38
!byte 30, 4,122,18,123
; V39
!byte 30,20,117, 4,118
; V40
!byte 30,19,118, 6,119

; ── Alignment pattern position lists (length-prefixed) ───────────
; For version v, use ALN_IDX[v-1] as byte offset into ALN_DATA.
; ALN_DATA[offset] = count, followed by count position values.
; Patterns at every (row_i, col_j) intersection, except those
; that overlap finder patterns (where row or col = 6 AND other = 6).
; Source: ISO 18004:2015 Table E.1.

ALN_IDX:
; Index (lo byte) into ALN_DATA for versions 1-40
; (ALN_IDX is relative to ALN_DATA base)
!byte   0   ; V1:  offset 0
!byte   1   ; V2:  offset 1
!byte   4   ; V3:  offset 4
!byte   7   ; V4
!byte  10   ; V5
!byte  13   ; V6
!byte  16   ; V7
!byte  20   ; V8
!byte  24   ; V9
!byte  28   ; V10
!byte  32   ; V11
!byte  36   ; V12
!byte  40   ; V13
!byte  44   ; V14
!byte  49   ; V15
!byte  54   ; V16
!byte  59   ; V17
!byte  64   ; V18
!byte  69   ; V19
!byte  74   ; V20
!byte  79   ; V21
!byte  85   ; V22
!byte  91   ; V23
!byte  97   ; V24
!byte 103   ; V25
!byte 109   ; V26
!byte 115   ; V27
!byte 121   ; V28
!byte 128   ; V29
!byte 135   ; V30
!byte 142   ; V31
!byte 149   ; V32
!byte 156   ; V33
!byte 163   ; V34
!byte 170   ; V35
!byte 178   ; V36
!byte 186   ; V37
!byte 194   ; V38
!byte 202   ; V39
!byte 210   ; V40

ALN_DATA:
; V1:  0 positions
!byte 0
; V2:  [6,18]
!byte 2, 6,18
; V3:  [6,22]
!byte 2, 6,22
; V4:  [6,26]
!byte 2, 6,26
; V5:  [6,30]
!byte 2, 6,30
; V6:  [6,34]
!byte 2, 6,34
; V7:  [6,22,38]
!byte 3, 6,22,38
; V8:  [6,24,42]
!byte 3, 6,24,42
; V9:  [6,26,46]
!byte 3, 6,26,46
; V10: [6,28,50]
!byte 3, 6,28,50
; V11: [6,30,54]
!byte 3, 6,30,54
; V12: [6,32,58]
!byte 3, 6,32,58
; V13: [6,34,62]
!byte 3, 6,34,62
; V14: [6,26,46,66]
!byte 4, 6,26,46,66
; V15: [6,26,48,70]
!byte 4, 6,26,48,70
; V16: [6,26,50,74]
!byte 4, 6,26,50,74
; V17: [6,30,54,78]
!byte 4, 6,30,54,78
; V18: [6,30,56,82]
!byte 4, 6,30,56,82
; V19: [6,30,58,86]
!byte 4, 6,30,58,86
; V20: [6,34,62,90]
!byte 4, 6,34,62,90
; V21: [6,28,50,72,94]
!byte 5, 6,28,50,72,94
; V22: [6,26,50,74,98]
!byte 5, 6,26,50,74,98
; V23: [6,30,54,78,102]
!byte 5, 6,30,54,78,102
; V24: [6,28,54,80,106]
!byte 5, 6,28,54,80,106
; V25: [6,32,58,84,110]
!byte 5, 6,32,58,84,110
; V26: [6,30,58,86,114]
!byte 5, 6,30,58,86,114
; V27: [6,34,62,90,118]
!byte 5, 6,34,62,90,118
; V28: [6,26,50,74,98,122]
!byte 6, 6,26,50,74,98,122
; V29: [6,30,54,78,102,126]
!byte 6, 6,30,54,78,102,126
; V30: [6,26,52,78,104,130]
!byte 6, 6,26,52,78,104,130
; V31: [6,30,56,82,108,134]
!byte 6, 6,30,56,82,108,134
; V32: [6,34,60,86,112,138]
!byte 6, 6,34,60,86,112,138
; V33: [6,30,58,86,114,142]
!byte 6, 6,30,58,86,114,142
; V34: [6,34,62,90,118,146]
!byte 6, 6,34,62,90,118,146
; V35: [6,30,54,78,102,126,150]
!byte 7, 6,30,54,78,102,126,150
; V36: [6,24,50,76,102,128,154]
!byte 7, 6,24,50,76,102,128,154
; V37: [6,28,54,80,106,132,158]
!byte 7, 6,28,54,80,106,132,158
; V38: [6,32,58,84,110,136,162]
!byte 7, 6,32,58,84,110,136,162
; V39: [6,26,54,82,110,138,166]
!byte 7, 6,26,54,82,110,138,166
; V40: [6,30,58,86,114,142,170]
!byte 7, 6,30,58,86,114,142,170

; ── Version info words for V7-V40 (18-bit, 3 bytes each: lo,mid,hi) ─────────
; word = (version << 12) | BCH12(version)
; BCH generator: x^12+x^11+x^10+x^9+x^8+x^5+x^2+1 = 0x1F25
; Indexed: VER_INFO_WORDS + (version-7)*3
; Byte order: lo (bits 7..0), mid (bits 15..8), hi (bits 17..16)
; Computed via: d = version << 12; for i=5..0: if d & (1<<(12+i)): d ^= (0x1F25<<i)

VER_INFO_WORDS:
; V7:  0x07C94
!byte $94,$7C,$00
; V8:  0x085BC
!byte $BC,$85,$00
; V9:  0x09A99
!byte $99,$9A,$00
; V10: 0x0A4D3
!byte $D3,$A4,$00
; V11: 0x0BBF6
!byte $F6,$BB,$00
; V12: 0x0C762
!byte $62,$C7,$00
; V13: 0x0D847
!byte $47,$D8,$00
; V14: 0x0E60D
!byte $0D,$E6,$00
; V15: 0x0F928
!byte $28,$F9,$00
; V16: 0x10B78
!byte $78,$0B,$01
; V17: 0x1145D
!byte $5D,$14,$01
; V18: 0x12A17
!byte $17,$2A,$01
; V19: 0x13532
!byte $32,$35,$01
; V20: 0x149A6
!byte $A6,$49,$01
; V21: 0x15683
!byte $83,$56,$01
; V22: 0x168C9
!byte $C9,$68,$01
; V23: 0x177EC
!byte $EC,$77,$01
; V24: 0x18EC4
!byte $C4,$8E,$01
; V25: 0x191E1
!byte $E1,$91,$01
; V26: 0x1AFAB
!byte $AB,$AF,$01
; V27: 0x1B08E
!byte $8E,$B0,$01
; V28: 0x1CC1A
!byte $1A,$CC,$01
; V29: 0x1D33F
!byte $3F,$D3,$01
; V30: 0x1ED75
!byte $75,$ED,$01
; V31: 0x1F250
!byte $50,$F2,$01
; V32: 0x209D5
!byte $D5,$09,$02
; V33: 0x216F0
!byte $F0,$16,$02
; V34: 0x228BA
!byte $BA,$28,$02
; V35: 0x2379F
!byte $9F,$37,$02
; V36: 0x24B0B
!byte $0B,$4B,$02
; V37: 0x2542E
!byte $2E,$54,$02
; V38: 0x26A64
!byte $64,$6A,$02
; V39: 0x27541
!byte $41,$75,$02
; V40: 0x28C69
!byte $69,$8C,$02

; ── Format info words for EC level L, masks 0-7 ──────────────────
; 15-bit values stored as lo/hi pairs (hi byte uses bits 14-8 only).
; Pre-computed: BCH(15,5) with generator 0x537, XOR mask 0x5412 applied.
; These are the final values written to the matrix (post-XOR).
; mask 0 = 0x77C4 (= 0x23D6 XOR 0x5412, verified by BCH calculation)

FMT_INFO_L:
; mask 0
!byte $C4,$77
; mask 1
!byte $F3,$72
; mask 2
!byte $AA,$7D
; mask 3
!byte $9D,$78
; mask 4
!byte $2F,$66
; mask 5
!byte $18,$63
; mask 6
!byte $41,$6C
; mask 7
!byte $76,$69
