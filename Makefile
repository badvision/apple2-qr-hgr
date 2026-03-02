# QR Code Generator for Apple II HGR
# Assemble with ACME cross-assembler

ACME    = acme
SRC     = qr.asm
BIN     = qr.bin
PC      = 6000

DEPS    = qr.asm zp.asm hgr.asm rs.asm matrix.asm encode.asm \
          place.asm format.asm tables.asm

DISK    = qrdemo.po
VOLUME  = /QRDEMO
STARTUP = STARTUP\#FC0801

.PHONY: all demo clean labels

all: $(BIN) demo

$(BIN): $(DEPS)
	$(ACME) -f plain -o $(BIN) --setpc $(PC) $(SRC)

labels: $(DEPS)
	$(ACME) -f plain -o $(BIN) --setpc $(PC) --labeldump labels.txt $(SRC)

demo: $(DISK)
	python3 tokenize_bas.py
	cadius DELETEFILE $(DISK) $(VOLUME)/STARTUP
	cadius ADDFILE $(DISK) $(VOLUME) $(STARTUP)

clean:
	rm -f $(BIN) labels.txt $(STARTUP)
