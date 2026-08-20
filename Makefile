# Serial-Controlled VGA Display — Nandland Go Board (iCE40-HX1K, VQ100, 25 MHz)
#
# One project, so the variables live inline here instead of a project.mk.
# Everything generated goes in build/, which is gitignored.
#
#   make TOP=...            synthesize, place and route, pack the bitstream
#   make TOP=... prog       flash the board over USB
#   make TOP=... timing     icetime timing report
#   make sim TB=...         compile and run a testbench under Icarus Verilog
#   make wave TB=...        same, then open the VCD in the waveform viewer
#   make clean              remove build/
#
# Nothing is globbed: every module a design instantiates has to appear in that
# design's SRC list below, because yosys only sees the files it is handed.

DEVICE  = --hx1k --package vq100
PCF     = constraints/Go_Board_Constraints.pcf
BUILD   = build

# Waveform viewer. WaveTrace runs inside VS Code, so `code` opens the VCD there.
# Override for GTKWave: make wave TB=tb_UART_Loopback WAVE=gtkwave
WAVE   ?= code

# Bring-up designs, copied from the book projects. They exist to prove the
# build flow end to end before any new RTL is debugged on top of it.
SRC_UART_Loopback_Top = bringup/UART_Loopback_Top.v \
                        common/UART_RX.v \
                        common/UART_TX.v \
                        common/Binary_To_7Segment.v

SRC_VGA_Test_Patterns_Top = bringup/VGA_Test_Patterns_Top.v \
                            common/UART_RX.v \
                            common/UART_TX.v \
                            common/Binary_To_7Segment.v \
                            common/VGA/VGA_Sync_Pulses.v \
                            common/VGA/VGA_Sync_Porch.v \
                            common/VGA/Test_Pattern_Gen.v \
                            common/VGA/Sync_To_Count.v

TOP     ?= UART_Loopback_Top
SOURCES  = $(SRC_$(TOP))

# Testbench source lists. UART_TX serializes real byte streams into UART_RX in
# the parser testbench, so the actual receive path is what gets exercised.
SIM_SRC_tb_UART_Loopback     = $(SRC_UART_Loopback_Top)
SIM_SRC_tb_VGA_Test_Patterns = $(SRC_VGA_Test_Patterns_Top)
SIM_SRC_tb_Command_Parser    = rtl/Command_Parser.v \
                               common/UART_RX.v \
                               common/UART_TX.v
SIM_SRC_tb_Font_ROM          = rtl/Font_ROM.v

TB      ?= tb_Command_Parser
SIM_SRC  = sim/$(TB).v $(SIM_SRC_$(TB))

all: $(BUILD)/$(TOP).bin

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/$(TOP).json: $(SOURCES) | $(BUILD)
	yosys -p "synth_ice40 -top $(TOP) -json $@" $(SOURCES) 2>&1 | tee $(BUILD)/$(TOP)-yosys.log

$(BUILD)/$(TOP).asc: $(BUILD)/$(TOP).json $(PCF)
	nextpnr-ice40 $(DEVICE) --json $< --pcf $(PCF) --asc $@ 2>&1 | tee $(BUILD)/$(TOP)-nextpnr.log

$(BUILD)/$(TOP).bin: $(BUILD)/$(TOP).asc
	icepack $< $@

prog: $(BUILD)/$(TOP).bin
	iceprog $<

timing: $(BUILD)/$(TOP).asc
	icetime -d hx1k -mtr $(BUILD)/$(TOP).rpt $<

$(BUILD)/$(TB).vvp: $(SIM_SRC) | $(BUILD)
	iverilog -g2012 -o $@ $(SIM_SRC)

# vvp runs from inside build/, so the relative $dumpfile in each testbench
# puts dump.vcd there instead of in the source tree.
sim: $(BUILD)/$(TB).vvp
	cd $(BUILD) && vvp $(TB).vvp

wave: sim
	$(WAVE) $(BUILD)/dump.vcd

# rtl/Font_ROM.v is generated but committed, so a fresh clone builds without
# Python. Regenerate deliberately, never as a build prerequisite: a clone's file
# timestamps come out in checkout order, and a build should not start demanding
# Python because make decided the script looked newer than its output.
font:
	python3 tools/gen_font_rom.py rtl/Font_ROM.v

clean:
	rm -rf $(BUILD)

.PHONY: all prog timing sim wave font clean
