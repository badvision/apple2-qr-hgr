#!/usr/bin/env python3
"""
Applesoft BASIC tokenizer - correct ROM token table.
Produces a valid tokenized binary suitable for loading at $0801.

Format per line: [lo next][hi next][lo linenum][hi linenum][tokens+literals...][00]
End of program: [00][00]

Token table verified from actual Applesoft II ROM ($D0D0-$D25F area).
ProDOS extensions (BLOAD, BSAVE, CATALOG, etc.) are NOT tokens - stored as ASCII.
"""

import sys
import os

# CORRECT Applesoft token table verified from ROM dumps
# Tokens start at $80. Each keyword: last char has high bit set in ROM.
# Keywords NOT in ROM (ProDOS extensions) are stored as plain ASCII text.
#
# IMPORTANT: Operators +, -, *, /, ^ ARE tokens ($C8-$CC).
# AND, OR, NOT are also tokens.
# Comparison operators >, =, < ARE tokens ($CF-$D1).
#
# Source: ROM at $D0D0-$D25F (Apple IIe Applesoft)

APPLESOFT_TOKENS = [
    # Statement keywords
    (0x80, 'END'),
    (0x81, 'FOR'),
    (0x82, 'NEXT'),
    (0x83, 'DATA'),
    (0x84, 'INPUT'),
    (0x85, 'DEL'),
    (0x86, 'DIM'),
    (0x87, 'READ'),
    (0x88, 'GR'),
    (0x89, 'TEXT'),
    (0x8A, 'PR#'),
    (0x8B, 'IN#'),
    (0x8C, 'CALL'),
    (0x8D, 'PLOT'),
    (0x8E, 'HLIN'),
    (0x8F, 'VLIN'),
    (0x90, 'HGR2'),
    (0x91, 'HGR'),
    (0x92, 'HCOLOR='),
    (0x93, 'HPLOT'),
    (0x94, 'DRAW'),
    (0x95, 'XDRAW'),
    (0x96, 'HTAB'),
    (0x97, 'HOME'),
    (0x98, 'ROT='),
    (0x99, 'SCALE='),
    (0x9A, 'SHLOAD'),
    (0x9B, 'TRACE'),
    (0x9C, 'NOTRACE'),
    (0x9D, 'NORMAL'),
    (0x9E, 'INVERSE'),
    (0x9F, 'FLASH'),
    (0xA0, 'COLOR='),
    (0xA1, 'POP'),
    (0xA2, 'VTAB'),
    (0xA3, 'HIMEM:'),
    (0xA4, 'LOMEM:'),
    (0xA5, 'ONERR'),
    (0xA6, 'RESUME'),
    (0xA7, 'RECALL'),
    (0xA8, 'STORE'),
    (0xA9, 'SPEED='),
    (0xAA, 'LET'),
    (0xAB, 'GOTO'),
    (0xAC, 'RUN'),
    (0xAD, 'IF'),
    (0xAE, 'RESTORE'),
    (0xAF, '&'),
    (0xB0, 'GOSUB'),
    (0xB1, 'RETURN'),
    (0xB2, 'REM'),
    (0xB3, 'STOP'),
    (0xB4, 'ON'),
    (0xB5, 'WAIT'),
    (0xB6, 'LOAD'),
    (0xB7, 'SAVE'),
    (0xB8, 'DEF'),
    (0xB9, 'POKE'),
    (0xBA, 'PRINT'),
    (0xBB, 'CONT'),
    (0xBC, 'LIST'),
    (0xBD, 'CLEAR'),
    (0xBE, 'GET'),
    (0xBF, 'NEW'),
    (0xC0, 'TAB('),
    (0xC1, 'TO'),
    (0xC2, 'FN'),
    (0xC3, 'SPC('),
    (0xC4, 'THEN'),
    (0xC5, 'AT'),
    (0xC6, 'NOT'),
    (0xC7, 'STEP'),
    # Operators (verified from ROM: + - * / ^ AND OR > = <)
    (0xC8, '+'),
    (0xC9, '-'),
    (0xCA, '*'),
    (0xCB, '/'),
    (0xCC, '^'),
    (0xCD, 'AND'),
    (0xCE, 'OR'),
    (0xCF, '>'),
    (0xD0, '='),
    (0xD1, '<'),
    # Functions (verified from ROM)
    (0xD2, 'SGN'),
    (0xD3, 'INT'),
    (0xD4, 'ABS'),
    (0xD5, 'USR'),
    (0xD6, 'FRE'),
    (0xD7, 'SCRN('),
    (0xD8, 'PDL'),
    (0xD9, 'POS'),
    (0xDA, 'SQR'),
    (0xDB, 'RND'),
    (0xDC, 'LOG'),
    (0xDD, 'EXP'),
    (0xDE, 'COS'),
    (0xDF, 'SIN'),
    (0xE0, 'TAN'),
    (0xE1, 'ATN'),
    (0xE2, 'PEEK'),
    (0xE3, 'LEN'),
    (0xE4, 'STR$'),
    (0xE5, 'VAL'),
    (0xE6, 'ASC'),
    (0xE7, 'CHR$'),
    (0xE8, 'LEFT$'),
    (0xE9, 'RIGHT$'),
    (0xEA, 'MID$'),
    # $EB onward: NOT in standard Applesoft ROM token table
    # ProDOS BASIC extensions are stored as plain ASCII text
]

# Sort by keyword length descending for greedy matching
APPLESOFT_TOKENS.sort(key=lambda x: -len(x[1]))


# ProDOS BASIC extensions: stored as plain ASCII (not tokens)
# These keywords must be checked BEFORE token matching to prevent
# partial matches like BLOAD -> B + LOAD-token.
PRODOS_EXTENSIONS = [
    'BLOAD', 'BSAVE', 'CATALOG', 'PREFIX',
    # Note: OPEN, CLOSE, READ, WRITE, DELETE are also ProDOS extensions
    # but DELETE conflicts with DEL token. READ conflicts with READ token.
    # For our program we only need BLOAD.
]
# Sort longest first
PRODOS_EXTENSIONS.sort(key=lambda x: -len(x))


def tokenize_line_content(text):
    """
    Tokenize the content part of a line (after line number).
    Returns bytearray of tokenized content (without leading/trailing null).

    ProDOS BASIC extensions (BLOAD, BSAVE, CATALOG, etc.) are stored as
    plain ASCII since they are not in the standard ROM token table.

    Spaces outside of string literals are stripped (not emitted as $20 bytes).
    The Apple II LIST routine reconstructs spacing from token context, so
    stripped spaces display correctly but are not stored in the token stream.
    Spaces INSIDE quoted strings are preserved verbatim.
    """
    result = bytearray()
    i = 0
    in_string = False

    while i < len(text):
        ch = text[i]

        if in_string:
            result.append(ord(ch))
            if ch == '"':
                in_string = False
            i += 1
            continue

        if ch == '"':
            in_string = True
            result.append(ord(ch))
            i += 1
            continue

        # Strip spaces outside of string literals.
        # Applesoft LIST reconstructs spacing from token context, so programs
        # that contain no space bytes still LIST with correct spacing. Storing
        # space bytes outside strings causes SYNTAX ERROR at RUN time in some
        # cases (e.g. around operators in expressions, after POKE token, etc.)
        if ch == ' ':
            i += 1
            continue

        # Check for REM - rest of line is literal
        if text[i:i+3] == 'REM':
            result.append(0xB2)  # REM token
            i += 3
            # Everything after REM is literal
            while i < len(text):
                result.append(ord(text[i]))
                i += 1
            break

        # Check ProDOS extensions FIRST (emit as plain ASCII)
        prodos_matched = False
        for ext in PRODOS_EXTENSIONS:
            elen = len(ext)
            if text[i:i+elen] == ext:
                for c in ext:
                    result.append(ord(c))
                i += elen
                prodos_matched = True
                break

        if prodos_matched:
            continue

        # Try to match a keyword token (greedy, longest first)
        matched = False
        for tok, kw in APPLESOFT_TOKENS:
            klen = len(kw)
            if text[i:i+klen] == kw:
                result.append(tok)
                i += klen
                matched = True
                break

        if not matched:
            result.append(ord(ch))
            i += 1

    return bytes(result)


def tokenize_program(program_lines, load_addr=0x0801):
    """
    Tokenize a full Applesoft BASIC program.

    program_lines: list of strings like "10 PRINT \"HELLO\""
    load_addr: where the program loads in memory (default $0801)

    Returns bytes of the complete tokenized program.
    """
    # Parse and sort lines
    parsed = []
    for line in program_lines:
        line = line.strip()
        if not line:
            continue
        # Split line number from rest
        space_idx = 0
        while space_idx < len(line) and line[space_idx].isdigit():
            space_idx += 1
        linenum = int(line[:space_idx])
        content = line[space_idx:].lstrip(' ')
        parsed.append((linenum, content))

    parsed.sort(key=lambda x: x[0])

    # Tokenize each line's content
    tokenized_lines = []
    for linenum, content in parsed:
        tokens = tokenize_line_content(content)
        tokenized_lines.append((linenum, tokens))

    # Calculate addresses and build binary
    # Each line: 2 (next ptr) + 2 (linenum) + len(tokens) + 1 (null)
    result = bytearray()
    addr = load_addr

    # Pre-calculate all line sizes
    line_sizes = [2 + 2 + len(tokens) + 1 for _, tokens in tokenized_lines]

    for i, (linenum, tokens) in enumerate(tokenized_lines):
        next_addr = addr + line_sizes[i]
        # next-line pointer (little-endian)
        result.append(next_addr & 0xFF)
        result.append((next_addr >> 8) & 0xFF)
        # line number (little-endian)
        result.append(linenum & 0xFF)
        result.append((linenum >> 8) & 0xFF)
        # tokenized content
        result.extend(tokens)
        # line terminator
        result.append(0x00)
        addr = next_addr

    # End of program
    result.append(0x00)
    result.append(0x00)

    return bytes(result)


# The QR demo program
# Notes on BLOAD syntax for ProDOS BASIC:
#   BLOAD "QR.BIN",A$6000 -- A$ is NOT a string variable, it's address param.
#   ProDOS BASIC handles this as plain text command, not a token.
#   Spaces matter less, but the A$6000 format specifies hex load address.
#
# Notes on self-encode (test 4):
#   PEEK(175)+PEEK(176)*256 = VARTAB (end of program + 2)
#   Subtract 2048 ($0800 = start of program area) to get program length
#   ZP_SRC = $0800: POKE 235,0 : POKE 236,8
#   ZP_LEN = program size in bytes
#   ZP_PAGE = 0 (HGR page 1)
#
# Notes on QR subroutine (GOSUB 9000):
#   Stores string in page 3 ($0300): POKE 767+I = $02FF+I -> $0300-$03xx
#   ZP_SRC = $0300: POKE 235,0 : POKE 236,3
#
# IMPORTANT: BLOAD is stored as plain ASCII (no token byte).
# INT, ASC, MID$, PEEK, LEN use correct ROM token values.

DEMO_PROGRAM_LINES = [
    # QR Code Demo for Apple II
    # Uses a ML trampoline at $7000 (safe from ProDOS page-3 IRQ vectors)
    # Trampoline reads params from $7020-$7024 and sets ZP_SRC/LEN/PAGE then JSR $6000
    # String data stored at $7025+
    # Parameters: $7020=SRC_LO, $7021=SRC_HI, $7022=LEN_LO, $7023=LEN_HI, $7024=PAGE
    # Decimal: 28704=SRC_LO, 28705=SRC_HI, 28706=LEN_LO, 28707=LEN_HI, 28708=PAGE
    # CALL address: 28672 ($7000)
    "1 REM QR CODE DEMO",
    "2 REM GITHUB.COM/BADVISION/APPLE2-QR-HGR",
    "10 HOME",
    # Install ML trampoline at $7000 via direct POKE - ONE POKE PER LINE
    # (Multi-POKE on same line causes SYNTAX ERROR in ProDOS BASIC.SYSTEM auto-run)
    # Trampoline: AD2070 85EB AD2170 85EC AD2270 85ED AD2370 85EE AD2470 85EF 200060 60
    # $7000: AD  LDA abs
    "20 POKE 28672,173",
    # $7001: 20  low byte of $7020
    "21 POKE 28673,32",
    # $7002: 70  high byte of $7020
    "22 POKE 28674,112",
    # $7003: 85  STA zp
    "23 POKE 28675,133",
    # $7004: EB  ZP_SRC lo
    "24 POKE 28676,235",
    # $7005: AD  LDA abs
    "25 POKE 28677,173",
    # $7006: 21  low byte of $7021
    "26 POKE 28678,33",
    # $7007: 70  high byte of $7021
    "27 POKE 28679,112",
    # $7008: 85  STA zp
    "28 POKE 28680,133",
    # $7009: EC  ZP_SRC hi
    "29 POKE 28681,236",
    # $700A: AD  LDA abs
    "30 POKE 28682,173",
    # $700B: 22  low byte of $7022
    "31 POKE 28683,34",
    # $700C: 70  high byte of $7022
    "32 POKE 28684,112",
    # $700D: 85  STA zp
    "33 POKE 28685,133",
    # $700E: ED  ZP_LEN lo
    "34 POKE 28686,237",
    # $700F: AD  LDA abs
    "35 POKE 28687,173",
    # $7010: 23  low byte of $7023
    "36 POKE 28688,35",
    # $7011: 70  high byte of $7023
    "37 POKE 28689,112",
    # $7012: 85  STA zp
    "38 POKE 28690,133",
    # $7013: EE  ZP_LEN hi
    "39 POKE 28691,238",
    # $7014: AD  LDA abs
    "40 POKE 28692,173",
    # $7015: 24  low byte of $7024
    "41 POKE 28693,36",
    # $7016: 70  high byte of $7024
    "42 POKE 28694,112",
    # $7017: 85  STA zp
    "43 POKE 28695,133",
    # $7018: EF  ZP_PAGE
    "44 POKE 28696,239",
    # $7019: 78  SEI (disable interrupts during QR generation)
    "45 POKE 28697,120",
    # $701A: 20  JSR
    "46 POKE 28698,32",
    # $701B: 00  low byte of $6000
    "47 POKE 28699,0",
    # $701C: 60  high byte of $6000
    "48 POKE 28700,96",
    # $701D: 58  CLI (re-enable interrupts)
    "49 POKE 28701,88",
    # $701E: 60  RTS
    "50 POKE 28702,96",
    # BLOAD QR.BIN after trampoline installed
    "95 PRINT \"LOADING QR.BIN...\"",
    "96 PRINT CHR$(4);\"BLOAD QR.BIN\"",
    "100 HOME",
    "110 PRINT \"QR CODE DEMO - PRESS A KEY FOR EACH\"",
    "120 PRINT \"--------------------------------------\"",
    "130 REM EACH QR HAS ITS OWN KEYPRESS GATE",
    "200 REM --- TEST 1: SHORT STRING",
    "210 A$ = \"HELLO WORLD\"",
    "220 GOSUB 9000",
    "300 REM --- TEST 2: URL",
    "310 A$ = \"HTTPS://GITHUB.COM/BADVISION/APPLE2-QR-HGR\"",
    "320 GOSUB 9000",
    "400 REM --- TEST 3: APPLE II STRING",
    "410 A$ = \"APPLE II 6502 QR GENERATOR BY BADVISION\"",
    "420 GOSUB 9000",
    "500 REM --- TEST 4: SELF-ENCODE PROGRAM",
    "510 HOME : PRINT \"SELF-ENCODING BASIC PROGRAM...\"",
    "511 PRINT \"PRESS ANY KEY\":GOSUB 8000",
    "512 PRINT \"GENERATING...\"",
    # L = program end - program start = VARTAB - $0800
    "520 L = PEEK(105) + PEEK(106) * 256 - 2048",
    # Store program bytes: SRC = $0800, LEN = L, PAGE = 0
    # Params at $7020-$7024 (28704-28708): SRC_LO,SRC_HI,LEN_LO,LEN_HI,PAGE
    "530 POKE 28704,0",
    "531 POKE 28705,8",
    "540 POKE 28706, L - INT(L / 256) * 256",
    "550 POKE 28707, INT(L / 256)",
    "560 POKE 28708,0",
    "570 CALL 28672",
    "580 GOSUB 8000",
    "590 TEXT : HOME",
    "600 PRINT \"SELF-ENCODED: \";L;\" BYTES\"",
    "610 PRINT \"(BINARY DATA - NOT SCANNABLE)\"",
    "620 PRINT \"PRESS ANY KEY\":GOSUB 8000",
    "630 TEXT : HOME : PRINT \"DEMO COMPLETE.\"",
    "650 END",
    "8000 POKE 49168,0:GET K$:RETURN",
    "9000 REM QR SUBROUTINE",
    "9010 L = LEN(A$)",
    "9020 FOR I = 1 TO L",
    # Store string data at $7025+ (28709+): POKE 28708+I = $7024+I -> $7025..$70xx
    "9030 POKE 28708 + I, ASC( MID$(A$,I,1) )",
    "9040 NEXT I",
    # Params at $7020-$7024 (28704-28708): SRC=$7025=28709, SRC_LO=37=$25, SRC_HI=112=$70
    "9050 POKE 28704,37",
    "9051 POKE 28705,112",
    "9060 POKE 28706,L",
    "9061 POKE 28707,0",
    "9070 POKE 28708,0",
    "9075 TEXT : HOME : PRINT A$",
    "9076 PRINT \"PRESS ANY KEY\":GOSUB 8000",
    "9077 PRINT \"GENERATING...\"",
    "9080 CALL 28672",
    "9090 GOSUB 8000",
    "9100 TEXT : HOME",
    "9110 RETURN",
]


if __name__ == '__main__':
    output_file = sys.argv[1] if len(sys.argv) > 1 else '/tmp/prodos_disk/STARTUP'
    os.makedirs(os.path.dirname(os.path.abspath(output_file)), exist_ok=True)

    print(f"Tokenizing {len(DEMO_PROGRAM_LINES)} lines...")
    result = tokenize_program(DEMO_PROGRAM_LINES, load_addr=0x0801)

    print(f"Tokenized size: {len(result)} bytes")

    # Verify by decoding
    tok_map = {tok: kw for tok, kw in APPLESOFT_TOKENS}
    tok_map[0xB2] = 'REM'

    def decode_tokens(data):
        out = []
        for b in data:
            if b == 0:
                break
            if b >= 0x80:
                out.append(tok_map.get(b, f'<${b:02X}>'))
            else:
                out.append(chr(b))
        return ''.join(out)

    print("\nProgram listing (verify):")
    i = 0
    while i < len(result) - 1:
        next_ptr = result[i] | (result[i+1] << 8)
        if next_ptr == 0:
            print("End of program")
            break
        linenum = result[i+2] | (result[i+3] << 8)
        i += 4
        tokens = bytearray()
        while i < len(result) and result[i] != 0:
            tokens.append(result[i])
            i += 1
        line = decode_tokens(tokens)
        print(f"  {linenum} {line}")
        i += 1

    with open(output_file, 'wb') as f:
        f.write(result)

    print(f"\nWritten: {output_file} ({len(result)} bytes)")
