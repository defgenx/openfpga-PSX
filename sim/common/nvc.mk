# Shared nvc (VHDL-2008) build pieces for the sim/*_diff harnesses and sim/common/Makefile.
#
# Set BUILD (build directory) and optionally NVC (default below) before including. Provides:
#   COMMON RTL MEMD         absolute paths of sim/common, rtl, and the simulation memory models
#   NVC                     nvc command line (--std=2008)
#   MEM_SRCS                the `mem` library sources (simulation dpram/RamMLAB/SyncFifo models + rtl fifos);
#                           compile into library work too (entities work.dpram, work.dpram_dif): NVC_MEM_WORK
#   $(BUILD)/mem/stamp      library mem (sim models; the dpram models use shared variables: --relaxed)
#   $(BUILD)/altera_mf/stamp  library altera_mf: behavioural altsyncram/altdpram (altera_mf_stub.vhd)
#   $(BUILD)/NAME_dbg.vhd   rtl/NAME.vhd with concurrent statements added after the architecture's first begin
#                           (dbg_insert.awk); AWKFLAGS per target, e.g. -v poly=1
#   NVC_MEM_WORK(DIR)       recipe line: analyse MEM_SRCS into work library DIR
#   $(COMMON)summarize.py, selftest_lib.py, diffsum.py, trace_cmp_pkg.vhd: see their headers

COMMON := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
RTL    ?= $(abspath $(COMMON)../../rtl)
MEMD   ?= $(abspath $(COMMON)../system/src/mem)
NVC    ?= nvc --std=2008
BUILD  ?= $(COMMON)build

MEM_SRCS := $(MEMD)/dpram.vhd $(MEMD)/RamMLAB.vhd $(MEMD)/SyncFifo.vhd $(RTL)/SyncFifoFallThrough.vhd $(RTL)/SyncFifoFallThroughMLAB.vhd

NVC_MEM_WORK = $(NVC) -H 256m --work=work:$(1) -L $(BUILD) -a --relaxed $(MEM_SRCS)

$(BUILD)/mem/stamp: $(MEM_SRCS)
	rm -rf $(BUILD)/mem; mkdir -p $(BUILD)
	$(NVC) -H 256m --work=mem:$(BUILD)/mem -a --relaxed $(MEM_SRCS)
	touch $@

$(BUILD)/altera_mf/stamp: $(COMMON)altera_mf_stub.vhd
	rm -rf $(BUILD)/altera_mf; mkdir -p $(BUILD)
	$(NVC) --work=altera_mf:$(BUILD)/altera_mf -a $<
	touch $@

# AWKFLAGS: -v poly=1 for gpu_poly (see dbg_insert.awk)
$(BUILD)/%_dbg.vhd: $(RTL)/%.vhd $(COMMON)dbg_insert.awk
	mkdir -p $(BUILD)
	awk $(AWKFLAGS) -f $(COMMON)dbg_insert.awk $< > $@
