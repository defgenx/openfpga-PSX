# CPU for the Pocket (`rtl/cpu_pocket.vhd`)

This document owns the CPU's size work: contract, what changed, how exactness is argued, results and the
harness. The RTL comments point here. Project context and gates: [ROADMAP.md](ROADMAP.md). Reference format:
[GPU.md](GPU.md).

## Contract

The golden model is `cpu.vhd` with `divider.vhd` and `datacache.vhd`, frozen. `cpu_pocket` has the golden's exact
port list and retires the same instruction stream with the same bus transactions, COP0 behaviour and GTE interface
as the golden with `TURBO`, `TURBO_CACHE` and `TURBO_CACHE50` tied low (as `core_top.v` does) and the savestate
ports unused. Kept as in the golden: the clk2x scratchpad port, forwarding, the load-use stalls and the odd
back-to-back-read stalls. The tag RAM and the register file read at clk2x (see [Tag RAM and register file](#tag-ram-and-register-file)).

Not part of the contract (unused inputs, constant outputs): `TURBO*`, `ram_done`, `ram_rnw`, `ram_dataRead`,
`dma_cache_*` (they only drive the golden's data cache, dead with `TURBO_CACHE = '0'`), every `SS_*` input,
`SS_DataRead_*` (0), `debug_firstGTE`. `SS_idle` is kept exactly.

Differences from the golden, all unobservable at the consumer or documented cuts:

| Where | Difference | Why it is safe |
|---|---|---|
| `gte_readAddr` | equals the golden only while `gte_readEna = '1'` | `gte_serial` samples it only then (`gte_serial.vhd:387-398`) |
| `gte_writeAddr`, `gte_writeData` | equal only while `gte_writeEna = '1'` | the GTE writes only then |
| `gte_cmdData` | equal only while `gte_cmdEna = '1'`; bits 31:25 are the constant `0100101` | every GTE command has them |
| `mem_addressData` | equals the golden only while `mem_request = '1'` and `mem_isData = '1'` | the memory mux reads it only then (the adder is shared, so it holds a sum for other instructions) |
| `cop0` registers 3, 5, 7, 9, 11 (BPC, BDA, DCIC, BDAM, BPCM) | **only with `NO_COP0_DEBUG = true`**: write ignored, read 0, no breakpoint exception | the contract exception in the plan (`cpu.vhd:1928-1932`); debuggers and anti-debug checks only |
| `cache_wr` | the golden's four per-word enables are served one word per cycle (the adapter drives one-hot) | `ram_adapter.v` writes one word per clk3x cycle |
| `PRID` | constant 2 from power-up (golden: 0 until the first reset) | the top resets the CPU before it runs |
| Icache tag compare | 18-bit key `{a31, a28:12}`, exact (see [Tag compare](#tag-compare)) | bits 30:29 are 0 in every cached fetch |
| `TURBO` | tied low in the entity | as `core_top.v` ties it |

Gate: **<= 1,900 ALMs for `cpu_pocket:icpu` in the `psx_top_pocket` in-context fit** (`sizing/psx_pocket_a6_cpu.qsf`,
see [ROADMAP.md](ROADMAP.md#phase-4--rewrites-area-and-the-core-gate)). The standalone fit
(`sizing/cpu_pocket.qsf`) stays a diagnostic.

Entity generic (the Pocket top instantiates through a component and takes the default):

| Generic | Default | Meaning |
|---|---|---|
| `NO_COP0_DEBUG` | `false` | `true` is the cut in the table above (-131.7 ALMs standalone); `false` is bit-exact on every COP0 register |
