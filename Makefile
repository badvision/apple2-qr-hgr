# QR Code Generator for Apple II HGR
# Assemble with ACME cross-assembler

ACME    = acme
SRC     = qr.asm
BIN     = qr.bin
PC      = 6000

DEPS    = qr.asm zp.asm hgr.asm rs.asm matrix.asm encode.asm \
          place.asm format.asm tables.asm

.PHONY: all clean labels

all: $(BIN)

$(BIN): $(DEPS)
	$(ACME) -f plain -o $(BIN) --setpc $(PC) $(SRC)

labels: $(DEPS)
	$(ACME) -f plain -o $(BIN) --setpc $(PC) --labeldump labels.txt $(SRC)

clean:
	rm -f $(BIN) labels.txt
