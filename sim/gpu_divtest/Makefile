# gpu_pocket_div against the golden divider.vhd. `make` runs every operand class, sharded over
# parallel nvc processes, and prints PASS or FAIL. `make narrow` repeats it with G_DIVIDEND_BITS
# 43 (edge) and 31 (gradient). `make quick` runs 20000 cases per class.
HERE    := $(dir $(lastword $(MAKEFILE_LIST)))
RTL     := $(HERE)../../rtl
BUILD   := $(HERE)build
NVC     := /opt/homebrew/bin/nvc --std=2008
SRC     := $(RTL)/divider.vhd $(RTL)/pGPU_pocket.vhd $(RTL)/gpu_pocket_div.vhd $(HERE)tb_divtest.vhd

# class:shards
RUNS    := edge:2 line:4 col:1 ppr:2 grad:2 rand:2
MAXCASES ?= 0
EDGE_DW  ?= 45
GRAD_DW  ?= 45
TAG      ?= full

# log names: <tag>_<class>_<shard>of<shards>.log
JOBS := $(foreach r,$(RUNS),$(foreach s,$(shell seq 0 $$(( $(word 2,$(subst :, ,$(r))) - 1 ))),$(BUILD)/$(TAG)_$(word 1,$(subst :, ,$(r)))_$(s)of$(word 2,$(subst :, ,$(r))).log))

.PHONY: all quick narrow clean check
all: check

$(BUILD)/analysed: $(SRC)
	@mkdir -p $(BUILD)
	rm -rf $(BUILD)/work
	$(NVC) --work=work:$(BUILD)/work -a $(SRC)
	@touch $@

# each run elaborates in its own copy of the library
$(BUILD)/$(TAG)_%.log: $(BUILD)/analysed
	@spec=$*; cls=$${spec%%_*}; rest=$${spec#*_}; sh=$${rest%%of*}; n=$${rest#*of}; \
	 rm -rf $(BUILD)/w_$(TAG)_$*; cp -R $(BUILD)/work $(BUILD)/w_$(TAG)_$*; \
	 $(NVC) --work=work:$(BUILD)/w_$(TAG)_$* -e -gCLASS_NAME=$$cls -gSHARD=$$sh -gNSHARDS=$$n \
	    -gEDGE_DW=$(EDGE_DW) -gGRAD_DW=$(GRAD_DW) -gMAXCASES=$(MAXCASES) tb_divtest -r > $@ 2>&1; \
	 rm -rf $(BUILD)/w_$(TAG)_$*

check: $(JOBS)
	@cat $(JOBS) | grep -E "RESULT|MISMATCH|Error|Fatal|assert" | sed 's/^\*\* [A-Za-z]*: //' ; \
	 echo "--- latency (clk edges from the start-sampling edge to done; all qbits in build/*.log) ---"; \
	 cat $(JOBS) | grep "LATENCY" | sed 's/.*LATENCY/LATENCY/' | grep -E "qbits=(11|21|31|43) |golden" | sort -u ; \
	 tot=$$(cat $(JOBS) | grep -o "cases=[0-9]*" | cut -d= -f2 | paste -sd+ - | bc); \
	 bad=$$(cat $(JOBS) | grep -o "mismatches=[0-9]*" | cut -d= -f2 | paste -sd+ - | bc); \
	 nres=$$(cat $(JOBS) | grep -c "RESULT"); \
	 errs=$$(cat $(JOBS) | grep -cE "\*\* (Error|Fatal)|MISMATCH"); \
	 echo "shards=$$nres cases=$$tot mismatches=$$bad errors=$$errs"; \
	 if [ "$$nres" = "$(words $(JOBS))" ] && [ "$$bad" = "0" ] && [ "$$errs" = "0" ]; then echo PASS; else echo FAIL; exit 1; fi

quick:
	$(MAKE) -f $(lastword $(MAKEFILE_LIST)) MAXCASES=20000 TAG=quick check

narrow:
	$(MAKE) -f $(lastword $(MAKEFILE_LIST)) EDGE_DW=43 GRAD_DW=31 TAG=narrow check

clean:
	rm -rf $(BUILD)
