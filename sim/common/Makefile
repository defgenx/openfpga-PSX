# Shared simulation scaffold: nvc.mk (build pieces the *_diff harnesses include), the altera_mf stub library,
# the cycle-trace compare package, and smoke runs of the frozen goldens.
#
#   make goldens              analyse, elaborate and run every golden (spu cd cpu dma memorymux joypad) with inputs
#                             tied off: once on the simulation memory models (sim), once on the rtl/ memories
#                             through the altera_mf stub (rtl); fails on any simulator error or assertion
#   make golden-spu           one golden (GOLDEN_FLAVOURS="sim rtl" selects the memory flavours, CYCLES the run length)
#   make selftest             altera_mf stub behaviour check and trace_cmp_pkg check
#   make clean
#
# Add a golden: SRC_<name> (rtl/ files in analysis order, from sizing/*.qsf), TOP_<name> (entity), and the name to GOLDENS.

HERE  := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
BUILD := $(HERE)build
NVC   := nvc --std=2008 --ieee-warnings=off
include $(HERE)nvc.mk

CYCLES ?= 3000
GOLDEN_FLAVOURS ?= sim rtl

GOLDENS     := spu cd cpu dma memorymux joypad
SRC_spu     := spu_ram spu_gauss spu
TOP_spu     := spu
SRC_cd      := cd_xa_zigzag cd_xa $(BUILD)/cd_top_init.vhd
TOP_cd      := cd_top
SRC_cpu     := export divider datacache cpu
TOP_cpu     := cpu
SRC_dma     := dma
TOP_dma     := dma
SRC_memorymux := memorymux
TOP_memorymux := memorymux
SRC_joypad  := pJoypad joypad_pad joypad_mem joypad
TOP_joypad  := joypad

# An entry of SRC_<name> is an rtl/ basename or an absolute path (a patched copy under build/).
SRCPATH = $(if $(filter /%,$(1)),$(1),$(RTL)/$(1).vhd)

# cd_top: positionInIndex has no initial value; to_unsigned of its leftmost value (-524288) in the ss_out
# assignment is a fatal error at time 0 under nvc. The copy initialises it to 0.
$(BUILD)/cd_top_init.vhd: $(RTL)/cd_top.vhd
	mkdir -p $(BUILD)
	sed 's/\(signal positionInIndex  *: integer range -524288 to 524287\);/\1 := 0;/' $< > $@
	cmp -s $< $@ && { echo "cd_top_init: pattern not found"; exit 1; } || true

# memory flavours: sim = simulation models (MEM_SRCS); rtl = the synthesised wrappers over the altera_mf stub
RTLMEM_SRCS  := $(addprefix $(RTL)/,dpram.vhd RamMLAB.vhd SyncFifo.vhd SyncFifoFallThrough.vhd SyncFifoFallThroughMLAB.vhd)
MEMSRC_sim   := $(MEM_SRCS)
MEMSRC_rtl   := $(RTLMEM_SRCS)
LIBS_sim     := -L $(BUILD)
LIBS_rtl     := -L $(BUILD)/rtlmem -L $(BUILD)
MEMSTAMP_sim := $(BUILD)/mem/stamp
MEMSTAMP_rtl := $(BUILD)/rtlmem/mem/stamp

.PHONY: goldens selftest clean
.DEFAULT_GOAL := goldens

$(BUILD)/rtlmem/mem/stamp: $(RTLMEM_SRCS) $(BUILD)/altera_mf/stamp
	rm -rf $(BUILD)/rtlmem/mem; mkdir -p $(BUILD)/rtlmem
	$(NVC) -H 256m --work=mem:$(BUILD)/rtlmem/mem -L $(BUILD) -a --relaxed $(RTLMEM_SRCS)
	touch $@

$(BUILD)/tb_smoke_%.vhd: $(HERE)mksmoke.py $(RTL)/%.vhd
	mkdir -p $(BUILD)
	python3 $(HERE)mksmoke.py $* $(RTL)/$*.vhd > $@

# the entity file of a golden is its last source; the testbench is named after the entity
# $(1) flavour, $(2) golden
define GOLDEN
$(BUILD)/$(1)/$(2)/stamp: $(foreach f,$(SRC_$(2)),$(call SRCPATH,$(f))) $(BUILD)/tb_smoke_$(TOP_$(2)).vhd \
                          $(MEMSTAMP_$(1)) $(BUILD)/altera_mf/stamp $(MEMSRC_$(1))
	rm -rf $$(dir $$@); mkdir -p $$(dir $$@)
	$(NVC) -H 256m --work=work:$$(dir $$@)work $(LIBS_$(1)) -a --relaxed $(MEMSRC_$(1))
	$(NVC) -H 256m --work=work:$$(dir $$@)work $(LIBS_$(1)) -a $(foreach f,$(SRC_$(2)),$(call SRCPATH,$(f))) \
	       $(BUILD)/tb_smoke_$(TOP_$(2)).vhd
	touch $$@

.PHONY: smoke-$(1)-$(2)
smoke-$(1)-$(2): $(BUILD)/$(1)/$(2)/stamp
	@d=$(BUILD)/$(1)/$(2)/run; rm -rf $$$$d; mkdir -p $$$$d; cd $$$$d; \
	$(NVC) -H 256m --work=work:../work $(LIBS_$(1)) -e --no-save tb_smoke_$(TOP_$(2)) -g G_CYCLES=$(CYCLES) \
	       -r --exit-severity=error > run.log 2>&1; rc=$$$$?; \
	if [ $$$$rc -eq 0 ] && grep -q 'SMOKE $(TOP_$(2)) PASS' run.log && ! grep -Eq '^\*\* (Error|Failure|Fatal)' run.log; \
	then echo "smoke $(1) $(2): `grep -o 'SMOKE .*' run.log`"; \
	else echo "smoke $(1) $(2): FAIL (exit $$$$rc)"; grep -E -m5 -B1 -A3 '^\*\* (Error|Failure|Fatal)' run.log; tail -5 run.log; exit 1; fi
SMOKES_$(1) += smoke-$(1)-$(2)
endef

$(foreach fl,sim rtl,$(foreach g,$(GOLDENS),$(eval $(call GOLDEN,$(fl),$(g)))))

goldens: $(foreach fl,$(GOLDEN_FLAVOURS),$(SMOKES_$(fl)))
	@echo "goldens: $(words $(GOLDENS)) x [$(GOLDEN_FLAVOURS)] PASS"

golden-%: $(foreach fl,$(GOLDEN_FLAVOURS),smoke-$(fl)-%)
	@true

# altera_mf stub behaviour (through the rtl wrappers) and trace_cmp_pkg
selftest: $(BUILD)/altera_mf/stamp $(BUILD)/rtlmem/mem/stamp
	@rm -rf $(BUILD)/stubcheck $(BUILD)/cmpcheck; mkdir -p $(BUILD)/stubcheck $(BUILD)/cmpcheck
	@$(NVC) --work=work:$(BUILD)/stubcheck/work -L $(BUILD) -a $(RTL)/dpram.vhd $(RTL)/RamMLAB.vhd $(HERE)altera_mf_tb.vhd
	@cd $(BUILD)/stubcheck && $(NVC) --work=work:work -L $(BUILD) -e --no-save altera_mf_tb -r 2>&1 | tee run.log | grep -E 'STUBCHECK|\*\*'; \
	grep -q 'STUBCHECK PASS' run.log
	@$(NVC) --work=work:$(BUILD)/cmpcheck/work -a $(HERE)trace_cmp_pkg.vhd $(HERE)trace_cmp_tb.vhd
	@cd $(BUILD)/cmpcheck && $(NVC) --work=work:work -e --no-save trace_cmp_tb -r > run.log 2>&1; cat run.log; \
	grep -q 'SELFCHECK PASS' run.log && test `grep -c '^MISMATCH' run.log` -eq 2
	@echo "SELFTEST PASS"

clean:
	rm -rf $(BUILD)
