# GTE serial (`rtl/gte_serial*.vhd`)

`gte_serial` replaces `rtl/gte.vhd` for the Pocket build. This document owns its design: the RTL
comments point here. Phase 1 gate and project context: [ROADMAP.md](ROADMAP.md).

The golden model is `gte.vhd` and everything it instantiates (`pGTE`, `gte_mac0`, `gte_mac123`,
`gte_UNRDivide`), frozen. `gte_serial` must be bit-exact on all 64 COP2 registers (FLAG included)
and take exactly the golden's busy cycles, proven by `sim/gte_diff` (see [Verification](#verification)).

## Contract

- Same entity ports as `gte`. `WIDESCREEN`, `TURBO`, `loading_savestate` and the `SS_*` inputs are
  ignored: `gte_serial` behaves as `gte` with `WIDESCREEN="00"`, `TURBO='0'`, no savestates.
  `SS_DataRead` is tied to 0 and `debug_firstGTE` to '0'. `SS_idle` keeps the golden's logic
  (`gte.vhd:1525-1532`), since psx_top ANDs it into `SS_idle`/`Pause_Idle`.
- **Only state at busy-fall is architectural.** The CPU never writes the GTE while it is busy and
  never reads it while busy (`cpu.vhd:1503-1545` and `:1688-1697`: MTC2/CTC2/COP2 stall on `gte_busy`, MFC2/CFC2/SWC2
  stall on `gte_busy`, `gte_cmdEna` and `gte_writeEna`). So `gte_serial` may compute in any order
  as long as every register holds the golden's value by the edge where the golden's FSM returns to
  IDLE. Intermediate values inside a command are not compared.
- **`gte_writeEna` and `gte_cmdEna` are never high on the same clk1x edge.** MTC2/CTC2 and COP2
  strobes come from the one instruction in execute (`cpu.vhd:2453-2460`), and an LWC2 whose load
  completes late holds the pipeline until its GTE write is issued (`:2137-2147`, `:2485`). The RAM
  copies rely on it: on the edge a command is accepted, the prefetch reads them with old-data
  semantics, where the golden would see a same-edge write at calcStep 0. The harness's same-edge
  vectors (`17`/`18`) pair a write with a read, never with a command.
- **`ce = '0'` freezes everything**: port sampling, `gte_readData`, the sequencer, the busy
  counter, the datapath, the divider and every architectural write. `SS_idle` is registered from
  the previous clk1x edge, so psx_top can drop `ce` one clk1x after a command was accepted, with the
  GTE busy (the race). The CPU clears `gte_writeEna`/`gte_cmdEna` only under `ce` (`cpu.vhd:2268-2271`),
  so a strobe stays high across a pause and must act exactly once.
  The golden's MAC units and divider are not under `ce`. During the race pause they re-process the
  step-0 request on every clk2x edge, which is idempotent for every step-0 request (none uses
  `useResult`), so freezing gives the same results.
- **Reset** is a one-clk1x pulse (`savestates.vhd:213`, `:276-278`) applied while the GTE is idle.
  The golden does not reset its MAC units, request triggers or side-effect strobes, so a reset that
  lands mid-command leaves partly applied results. That case is outside the contract.
- `gte_readData` holds its value between reads, through busy and through reset, exactly like the
  golden's register (`gte.vhd:392-464`, not reset).

## Clocking

Everything runs on **clk2x (67.7376 MHz)**, gated by `ce`, as in the golden; `SS_idle` is on clk1x.
There is no clk4x domain. Two lanes at clk2x give the same issue rate as one lane at clk4x (two
products per clk2x), with the same DSP count (see [DSP allocation](#dsp-allocation)). They also
avoid a clk2x/clk4x crossing for the register file and the 7.38 ns paths it would put on every
architectural register. The cost is a second lane's operand muxes. Why clk4x was not used, with
measured slack: [Datapath slice](#datapath-slice).

## Register file

| Storage | Registers |
|---|---|
| RAM (written only by the CPU) | V0–V2 (0–5), RES1 (23), RT (32–36), TR (37–39), LLM (40–44), BK (45–47), LCM (48–52), FC (53–55), OFX/OFY (56–57), H (58), DQA (59), DQB (60), ZSF3/ZSF4 (61–62) |
| Flip-flops | RGBC (6), OTZ (7), IR0–IR3 (8–11), SXY FIFO (12–15), SZ FIFO (16–19), RGB FIFO (20–22), MAC0–MAC3 (24–27), IRGB/ORGB (28–29, read computed from IR1–3), LZCS (30), LZCR (31, 6 bits), FLAG (63, bits 31..12) |

- No command writes a RAM register, so during a command the RAM is read-only.
- **Sign extension at write.** The golden sign-extends these 16-bit registers on read
  (`gte.vhd:395-460`): 1, 3, 5, 36, 44, 52, 58, 59, 61, 62. They are stored as `resize(data(15
  downto 0), 32)`. Every other RAM address stores the 32-bit word as written. No RAM word reads
  zero-extended.
- **Valid bits.** The golden zeroes every register in one reset edge (`gte.vhd:288-377`). The RAM
  cannot be swept in a one-clk1x reset, so each RAM word has a valid bit: 64 FFs, cleared by reset,
  set by a write. A read of an invalid word returns 0.
- **Three copies.** One copy per read port, all written identically by the CPU (inferred simple
  dual-port M10K, 64×32 each). The CPU read copy has a read enable (`ce and not reset and readEna`), so its
  output register holds between reads like the golden's `gte_readData`. The two engine copies are
  read by the sequencer during a command. `gte_readData` is the CPU copy's output (masked by its
  captured valid bit) or a captured FF value, selected by a bit captured with the read.

## MAC rules

The golden accumulates in `gte_mac123` (MAC1–3) and `gte_mac0` (MAC0). The two differ, and
`gte_serial` follows each exactly:

- **MAC1–3** (`gte_mac123.vhd`): 45-bit. The product is `resize(mul1*mul2, 45)`. The addend is
  `add`, or with `useResult` the previous result sign-extended from bit 43 (`resize(acc(43 downto
  0), 45)`, `:41-42`). The combination is `X − a` (sub and swap), `a − X` (sub) or `a + X`, in
  45-bit two's complement. Overflow (`< −2^43`, `> 2^43−1`) is checked after **every** request
  (`:62`, `:30-31`). `macLast` is the full 45-bit result of the request *before* the latest one,
  latched on every trigger (`:56`), and it is fed back unwrapped through `add` (e.g. DPCS step 4,
  `gte.vhd:756`).
- **MAC0** (`gte_mac0.vhd`): 35-bit. `useResult` adds the full previous result with no wrap
  (`:55-58`). Overflow is checked against the 32-bit range only when the request sets `checkOvf`
  (`:72-74`). `mac0Last` is the previous 35-bit MAC0 result, latched on every trigger (`:51`).
- **IR** from MAC1–3 (`gte_mac123.vhd:96-145`): the value from `IRshift` and `satIR`, and the flag
  from `IRshiftFlag` and `satIRFlag`, each selecting `res(43..12)` or `res(31..0)`. RTPS/RTPT MAC3
  computes IR3's flag differently from its value (`gte.vhd:632`). IR0 from MAC0 clamps to
  0..0x1000 (`gte_mac0.vhd:96-115`).
- **FLAG**: MACn UF/OF → 27/30, 26/29, 25/28; MAC0 → 15/16; IR1–3 → 24/23/22; IR0 → 12;
  RGB → 21/20/19; OTZ and SZ3 → 18; SX2/SY2 → 14/13; divide → 17. Bit 31 is set with every one of
  them except 22, 21–19 and 12 (`gte.vhd:1243-1364`). FLAG only accumulates during a command, so
  order does not matter.

Every golden request maps to exactly one serial lane operation. Partial sums are issued in the
golden's per-row order, so the wrap, the per-step overflow and `macLast` match.

**Multiply widths.** Every 32-bit `mul1` operand (TR/BK/FC, `translate`, `mac*_result`, `REG_MAC*`)
is multiplied only by a power of two (`x"1000"`, `x"10"`, `shiftvalue` ∈ {1, 0x1000}). Every real
product is 16×16 (IR, V, matrices), 16×9 (RGBC byte), 9×17 (color × 0x10000) or 17×18 (MAC0). So a
lane has one signed **18×19** multiplier and a **shifter** for the power-of-two terms. Sign-extended
`x·2^k` is the product, so the shifter is exact. `sim/gte_diff` checks the invariant on every golden
request.

## Datapath

Two identical **lanes**, each `res = combine(X, a)`:

- `X` = `A × B` (18×19 signed) or `sext45(S) << k`, k ∈ {0, 4, 12, sf ? 12 : 0}.
- `a` = 0, the row's accumulator (MAC1–3: sext from bit 43; MAC0: the full 35 bits), the row's
  `macLast`, `sext(S)` (MAC0 OFX/OFY/DQB) or `sext(S) << 12` (TR as the addend of RTPS/RTPT's first
  term). With `a` taken from `S`, `X` is the product.
- `combine` = `X − a`, `a − X` or `a + X`, 45-bit.

**Stages** (G_L = 1, the golden's own timing):

| Cycle | Stage | Action |
|---|---|---|
| c | issue | `opA`, `opB` and the 45-bit `opS` registered from their sources (read as of the end of cycle c−1). `opS` is S shifted by k for X, or S / S<<12 for the addend. The controls are registered and decoded: X select, addend select, the two negations |
| c+1 | execute | product; `res = (X ^ nx) + (a ^ na) + (nx or na)`, one 45-bit adder → `res_q`, the row's accumulator, its `macLast` (old accumulator), the MACn register; MAC0 → `acc0`, `mac0Last`, MAC0 |
| c+2 | writeback | from `res_q`: IRn (saturation), FLAG bits |

Write times, as "value visible after edge": accumulators and MACn at c+2, IRn and FLAG at c+3.
These are the golden's: request register, then `macResult_1` and `mac_result` at +1, then `REG_IR*`
at +2. MACn is written with `mac_result` rather than with `REG_MAC*` (one edge later), because the
golden's consumers (`×0x10`, pushRGB) read `mac_result`. Without that, DPCL misses its IDLE edge
with two lanes. A `useResult` chain on one row issues back to back. An op reading MACn issues 2
cycles after its producer, one reading IRn 3 cycles after. With G_L = 2 the product is registered
(execute takes two cycles) and every offset after issue grows by one. That misses the IDLE edge on
DPCT, CDP, DPCL and AVSZ3, so the gate design is G_L = 1.

The MAC unit state per row: accumulator (45), `macLast` (45). MAC0: `acc0` (35), `mac0Last` (35).
`mac3Shifted` is `acc3(43..12)`; `mac*_result` is the MACn register.

### DSP allocation

| Block | Multipliers | Mode |
|---|---|---|
| 1 | lane A 18×19 | 18×18 (half used) |
| 2 | lane B 18×19 | 18×18 (half used) |
| 3 | divider, shared by stages 4, 5 and 6: `:166` 17×11, `:175` 11×18, `:182` 19×20 unsigned | 27×27 |

3 blocks against the gate's 4. MAC0 runs on the lanes, so it has no multiplier of its own.
Quartus 21.1 does not pack two inferred multipliers into one block, so each lane takes a block of
its own, and a divider with one multiplier per stage would take three. For reference, the
golden divider alone takes 5 DSP and each `gte_mac123` 3 in the stripped build.

### Divider (`rtl/gte_serial_div.vhd`)

`gte_UNRDivide` with two narrowings, one multiplier shared by stages 4–6, plus a `ce` input.
Sharing requires divides to start at least 3 cycles apart. The golden's RTPT starts them 3 steps
apart, the generator enforces it, and a simulation assertion checks it. The narrowings:
- The 32×20 multiply (`gte_UNRDivide.vhd:182`) becomes `(lhs_5 << (shiftcount_5 mod 4)) ·
  calc_val_r` (19×20 unsigned), and its product is shifted by `4·(shiftcount_5 div 4)`. The rounding
  order is kept: shift, then `+ 0x8000`, then `>> 16`, then the same resize to 32 bits and clamp.
  This is exact because the two shifts compose to `shiftcount_5`, and `calc_lhs = lhs_5 ·
  2^shiftcount_5` never loses a bit (`lhs_5 < 2^16`, shift ≤ 15). Splitting the shift leaves a
  4-way mux after the multiply, where a 16-way shifter would be.
- `calc_val_d` becomes 18-bit signed: `var_d20(17 downto 0)`, fed straight to the shared multiplier.

`make divtest` sweeps all 65,536 `rhs` values with up to 13 `lhs` values each (out-of-range ones dropped): 0, 0xFFFF, the
`rhs·2 ≤ lhs` edge, the `> 0x1FFFF` clamp edge and random values. It runs two passes, one with
triggers 3 cycles apart and the inputs held, the other with random extra gaps and garbage inputs
in between: 1,245,186 divides, 0 mismatches. `calc_val_d` and `calc_val_r` depend only on `rhs`,
so the sweep is a proof, not a sample. Measured over it:

| | min | max |
|---|---|---|
| `calc_val_d` | 65,281 | 65,724 |
| `calc_val_r` | | 131,072 (0x20000, 18 bits unsigned) |
| `lhs_5 · 2^shiftcount_5` | | 2,147,450,880 (< 2^31) |

The golden-side range assertion never fires. `calc_val_r ≤ 2^17` would allow a narrower multiply;
the gate does not need it.

Latency: trigger to result is 7 clk2x, the same as the golden. Divide error sets FLAG 17 one edge
after the result.

## Sequencer and micro-op format

A command runs a **program**: a sequence of horizontal micro-words in a ROM (M10K, registered
address), one word per clk2x cycle. Word c is fetched at the edge that accepts the command (c = 0)
or at the previous word's edge, and it acts at the edge where the golden runs `calcStep = c`.
Programs are generated by `rtl/gen/gte_ucode.py` from a transcription of the golden's per-step
request tuples. The generator checks every value read against the golden's
[version model](#schedule) and emits `rtl/gte_serial_ucode.vhd` (ROM, program table, prefetch
table).

**Program select** at acceptance: the opcode, and for MVMVA (`mx`=3?, `v`=3?, `cv` ∈ {0/1, 2, 3}),
12 programs. Undefined opcodes have no program: the golden clears FLAG, latches the fields and
takes no busy (`gte.vhd:576-607`). The word's `halt` bit stops issuing. Ops in flight drain.

**Busy** is a counter from a per-opcode table of the golden's CALC-state edges. It is independent of
the program:

| Op | edges | hw | Op | edges | hw | Op | edges | hw |
|---|---|---|---|---|---|---|---|---|
| RTPS 01 | 26 | 15 | NCDT 16 | 84 | 44 | SQR 28 | 6 | 5 |
| NCLIP 06 | 12 | 8 | NCCS 1B | 30 | 17 | DPCL 29 | 11 | 8 |
| OP 0C | 8 | 6 | CC 1C | 17 | 11 | DPCT 2A | 29 | 17 |
| DPCS 10 | 11 | 8 | NCS 1E | 23 | 14 | AVSZ3 2D | 6 | 5 |
| INTPL 11 | 11 | 8 | NCT 20 | 55 | 30 | AVSZ4 2E | 8 | 6 |
| MVMVA 12 | 11 | 8 | RTPT 30 | 42 | 23 | GPF 3D | 5 | 5 |
| NCDS 13 | 34 | 19 | NCCT 3F | 74 | 39 | GPL 3E | 6 | 5 |
| CDP 14 | 21 | 13 | | | | | | |

"edges" are clk2x edges in a CALC state, the cycle count `gte_serial` must reproduce. "hw" is the
real console's count in CPU cycles, as listed by psx-spx, for reference only.

The batch commands are `2·(R+1) + (N+1)`, from their restart step R and IDLE step N
(`gte.vhd:762-773`, `:930-941`, `:1040-1051`, `:1132-1142`). The golden's IDLE-state busy
release on `clk2xIndex = '0'` (`gte.vhd:615-617`) is kept as is.

**RAM reads.** Two engine read ports. Word c's read is addressed at edge c+1, and its masked data
lands in a **staging** register (4 × 32-bit, `s0`–`s3`) at edge c+2. `base + off` addresses the
RAM: base ABS = 0, MAT = 32/40/48 (`mx`), VEC = 0/2/4 (`v`), TRV = 37/45/53 (`cv`). Each program
also has up to two **prefetch** reads, addressed at the acceptance edge from a table on the
command word, which land at edge 1.

### Word fields

Per word: two read ports, two lane ops, the side effects and `halt`. Bit positions are in
`rtl/gte_serial_pkg.vhd`; the generator mirrors them.

| Group | Field | Bits | Meaning |
|---|---|---|---|
| read port p | `en` | 1 | read this cycle |
| | `base` | 2 | ABS, MAT, VEC, TRV |
| | `off` | 6 | offset added to base |
| | `dst` | 3 | staging slot (2 bits used) |
| lane L | `v` | 1 | op valid |
| | `m0` | 1 | 1 = MAC0 op, 0 = MAC1–3 op |
| | `row` | 2 | 1–3 (MAC1–3) |
| | `asel` | 6 | A source (18-bit) |
| | `bsel` | 6 | B source (19-bit) |
| | `xs` | 1 | X = shift(S) instead of A×B |
| | `ssel` | 4 | S source (32-bit) |
| | `k` | 2 | shift: 0, 4, 12, sf ? 12 : 0 |
| | `add` | 3 | addend: 0, ACC, MACLAST, S, S<<12 |
| | `sub`, `swap` | 2 | as in the golden request |
| | `wb` | 3 | MAC1–3 writeback mode, or MAC0 {useIR, checkOvf} |
| side | `rgb`, `otz`, `sz`, `sxy` | 4 | the four side-effect ops |
| | `hslot` | 3 | staging slot holding H, for `sz` (2 bits used) |
| | `snap` | 2 | RTPT snapshot slot 0/1 (none = 0) |
| | `vsnap` | 1 | MVMVA `v`=3 vector snapshot |
| | `halt` | 1 | stop issuing |

**MAC1–3 writeback modes** (`saveShifted`, `useIR`, `IRshift`, `IRshiftFlag`, `satIR`, `satIRFlag`):

| wb | Tuple | Used by |
|---|---|---|
| 0 NONE | 0, 0, 0, 0, 0, 0 | every non-final partial sum |
| 1 STD | sf, 1, sf, sf, lm, lm | final terms |
| 2 RTP3 | sf, 1, sf, 1, lm, 0 | RTPS/RTPT MAC3 (`gte.vhd:632`) |
| 3 FC | sf, 1, sf, sf, 0, 0 | the FC − X step of DPCS/INTPL/DPCL/NCDS/CDP |
| 4 MVBUG | 0, 1, sf, sf, 0, 0 | MVMVA `cv`=2, first term (`gte.vhd:841-844`) |

MAC0 `wb` bit 0 = `useIR` (with `IRshift`), bit 1 = `checkOvf`.

**Sources.** In the tables below, `stg` lo/hi is the low/high half of a staging slot, code
`1 + 2·slot + half`. Codes 9–16 (A/B) and 5–8 (S) would address slots 4–7, which do not exist
(`NSTG` = 4); they read as zero.

| A (18-bit signed) | | B (19-bit signed) | | S (32-bit) | |
|---|---|---|---|---|---|
| 0 | zero | 0 | zero | 0 | zero |
| 1–8 | stg lo/hi, sext | 1–8 | stg lo/hi, sext | 1–4 | stg s0–s3 |
| 17–20 | IR1, IR2, IR3, IR0 | 17–20 | IR1, IR2, IR3, IR0 | 9–11 | MAC1, MAC2, MAC3 |
| 21–23 | SX0, SX1, SX2 | 21–23 | RGBC R, G, B (zext) | | |
| 24–27 | SZ0–SZ3 (zext) | 24–26 | vsnap 0–2 | | |
| 28–30 | RGBC R, G, B (zext) | 27 | div_result (zext 17) | | |
| 31–33 | RGB0 R, G, B (zext) | 28–30 | SY0, SY1, SY2 | | |
| 34, 35 | ±(RGBC R << 4) | 31 | 0x1000 | | |
| 36–39 | snap IR1[0], IR1[1], IR2[0], IR2[1] | 32 | 0x10000 | | |

### Side-effect ops

Each reads its operands as of the end of its cycle c and writes at edge c+1.

| Op | Operands | Effect | FLAG |
|---|---|---|---|
| `rgb` (pushRGBfromMAC) | MAC1–3, RGBC code byte | each `(31..4)` saturated to 0..255 into RGB2, code byte from RGBC, RGB FIFO shifts | 21, 20, 19 |
| `otz` (setOTZ) | `acc0` | `(34..12)` saturated to 0..0xFFFF into OTZ | 18 |
| `sz` (pushSZandDivide) | `acc3(43..12)`, H (`stg[hslot]` lo) | saturated to 0..0xFFFF into SZ3 and `div_rhs`; `div_lhs` = H, SZ FIFO shifts, divide starts | 18 |
| `sxy` (pushSXY) | `mac0Last` (SX2), `acc0` (SY2) | `(34..16)` saturated to ±1024, SXY FIFO shifts | 14, 13 |
| `snap` | IR1, IR2 | RTPT's `IR1aspect_1/2`, `REG_IR2_1/2` (`gte.vhd:676`, `:689`) | |
| `vsnap` | IR1–3 | MVMVA's `vector0..2` when `v` = 3 (`gte.vhd:824`) | |

A divide started at word c returns `div_result` at edge c+8, and divide error sets FLAG 17 at c+9.
RTPT keeps three divides in flight against one `div_result` register. The schedule reads each
vertex's quotient before the next one lands.

## Schedule

The generator is a list scheduler over a **version model** of the golden:

- For every golden action it records when each register is read and written, from the golden's
  timing. A request at step k reads its operands after edge k. The MAC unit writes `macResult_1`,
  `mac_result` and `macLast` at k+2, and `REG_*`/FLAG at k+3. Side effects flagged at step k
  execute at k+2. `IR1aspect` lags IR1 by one edge. A divide started by a side effect at edge e
  returns at e+7.
- Each read then names the version (writer) it must see. A serial action may read a register only
  after that writer's serial write and before the next version's serial write. Writes keep the
  golden's order, every program's last write lands no later than the golden's IDLE edge, and no
  command reads a MAC unit's state left over from a previous command.
- Resources per cycle: two lane ops (MAC0 on lane A), one op per row, two RAM reads, one of each
  side effect, four staging slots, and divides at least 3 cycles apart.

Per-opcode results, from `python3 rtl/gen/gte_ucode.py`. "Last write" is the edge of the program's
last architectural write, FLAG included; "slack" is the golden's IDLE edge minus it. Products count
lane ops through the multiplier (real) and through the shifter (power of two). Dependency stages
are the longest chain of true dependencies, not counting a row's own accumulation chain. The FIFO
pushes chain the vertices of NCDT/NCCT/NCT/DPCT.

| Program | golden edges | words | last write | slack | products (real / 2^k) | dependency stages | lane use | staging slots |
|---|---|---|---|---|---|---|---|---|
| AVSZ3 | 6 | 6 | 6 | 0 | 3 / 0 | 2 | 25% | 1 |
| AVSZ4 | 8 | 7 | 7 | 1 | 4 / 0 | 2 | 29% | 1 |
| CC | 17 | 14 | 14 | 3 | 12 / 6 | 4 | 64% | 2 |
| CDP | 21 | 19 | 19 | 2 | 15 / 9 | 5 | 63% | 2 |
| DPCL | 11 | 10 | 10 | 1 | 6 / 6 | 4 | 60% | 2 |
| DPCS | 11 | 8 | 8 | 3 | 6 / 3 | 3 | 56% | 2 |
| DPCT | 29 | 24 | 24 | 5 | 18 / 9 | 9 | 56% | 2 |
| GPF | 5 | 4 | 4 | 1 | 3 / 0 | 2 | 38% | 0 |
| GPL | 6 | 5 | 5 | 1 | 3 / 3 | 2 | 60% | 0 |
| INTPL | 11 | 8 | 8 | 3 | 6 / 3 | 3 | 56% | 2 |
| MVMVA (12 programs) | 11 | 6–8 | 8–10 | 1–3 | 9 / 3 | 1–2 | 75%–100% | 2–4 |
| NCCS | 30 | 20 | 20 | 10 | 21 / 6 | 5 | 68% | 4 |
| NCCT | 74 | 52 | 52 | 22 | 63 / 18 | 7 | 78% | 4 |
| NCDS | 34 | 24 | 24 | 10 | 24 / 9 | 6 | 69% | 4 |
| NCDT | 84 | 64 | 64 | 20 | 72 / 27 | 8 | 77% | 4 |
| NCLIP | 12 | 6 | 8 | 4 | 6 / 0 | 1 | 50% | 0 |
| NCS | 23 | 15 | 15 | 8 | 18 / 3 | 3 | 70% | 4 |
| NCT | 55 | 38 | 38 | 17 | 54 / 9 | 5 | 83% | 4 |
| OP | 8 | 4 | 6 | 2 | 6 / 0 | 1 | 75% | 2 |
| RTPS | 26 | 21 | 22 | 4 | 12 / 0 | 4 | 29% | 4 |
| RTPT | 42 | 35 | 36 | 6 | 34 / 0 | 6 | 49% | 4 |
| SQR | 6 | 2 | 4 | 2 | 3 / 0 | 1 | 75% | 0 |

The ROM holds 469 words × 97 bits (5 M10K). AVSZ3 has no slack: its ZSF3 operand needs the
acceptance-edge prefetch to land in time. With G_L = 2, DPCT, CDP, DPCL and AVSZ3 miss.
`--listing FILE` prints every program cycle by cycle.

## Datapath slice

`sizing/gte_slice.vhd` is one lane plus the divider's last stage, on 5CEBA4F23C8. The lane is a
RAM read, the operand mux, an 18×19 multiply, the shifter, the 45-bit accumulate with an addend mux,
overflow and IR saturation. The slice was placed and routed with `sizing/gte.sdc`. `G_L` counts the
stages from the operand mux to the accumulator. Each variant is a revision of `sizing/gte_slice.qpf`,
run from `sizing/` as in [Measurements](#measurements) with `gte_slice` in place of `gte_size`:
`quartus_sh --flow compile gte_slice -c <rev>`, then `quartus_sta -t report.tcl <rev>`, which writes
the worst setup path per clock to `output_files_<rev>/worst_<clock>.txt`.

| Variant | Revision | Clock | Setup slack, slow 85 °C | Worst path |
|---|---|---|---|---|
| lane, L = 2 | `slice4x_L2` | clk4x | −3.196 ns | M10K → operand mux → DSP → product |
| lane, L = 3 | `slice4x_L3` | clk4x | −1.967 ns | addend select → 45-bit carry chain → accumulator |
| lane, L = 3, pre-decoded addend | `slice4x_L3_acc` | clk4x | −1.491 ns | `macLast` → 45-bit add → accumulator loop |
| lane, L = 1 (mux, multiply, accumulate in one cycle) | `slice2x_L1` | clk2x | −2.818 ns | operand mux → DSP → 45-bit add |
| lane, L = 2 | `slice2x_L2` | clk2x | +1.582 ns | |
| divider last stage, 1 extra register | `slicediv4x` | clk4x | −1.961 ns | shift by 0–15 → +0x8000 → compare |
| divider last stage, 2 extra registers | `slicediv4x_r2` | clk4x | −0.135 ns | shift → round adder |

Hold is positive in all four corners (worst +0.044 ns, fast 0 °C). The 45-bit accumulate loop
(accumulator → addend mux → add → accumulator) does not close at 135 MHz on a C8 part, so the
clk4x design is out. At clk2x the operand mux must not share a cycle with the multiply and the
add. `gte_serial` registers the operands at issue: issue = operand mux, execute = multiply +
accumulate, which sits between the slice's L = 1 and L = 2. In the full design it closes with
margin (see [Measurements](#measurements)). The schedule needs that timing: with the product
registered (G_L = 2), DPCT, CDP, DPCL and AVSZ3 miss their IDLE edge.

## Verification

`sim/gte_diff` (nvc): golden and DUT on the same stimulus.
- `make golden`: golden against golden (smoke test).
- `make selftest`: proves the comparator catches injected faults.
- `make divtest`: the divider proof above.
- `make ucode-check`: the committed ROM is what `gte_ucode.py` generates, and every
  `gte_serial_pkg.vhd` constant matches the generator's copy.
- `make diff`: directed, edge, reset, cpu-timing (pauses and race pauses included), boundary and
  random (uniform and game-like) suites, by default one seed and 20,000 random commands
  (about 33k commands in all). Every coverage counter must be non-zero.
- `make -j8 gate`: the gate run, `ucode-check` then `diff` over seeds 21–28 with 125,000 random
  commands each (1,000,000), failing if any suite runs fewer commands than the gate run below.

Baseline, golden against golden (`make -j8 golden SEEDS="1 2 3 4 5 6 7 8" COUNT=125000`): 1,103,344
commands, 0 differences, 256 s on 8 jobs (about 4,300 commands/s, 540 per job).

Results on the gate build (`make -j8 gate`, 298 s on 8 jobs): 1,110,820 commands, 0
register/FLAG mismatches, 0 `gte_busy` differences at clk1x edges, 0 golden-side assertion
failures and 0 simulator errors. That is 24.5M multiply requests and 212,684 divides checked,
and 10,294 pauses, 3,636 of them on the race edge with the GTE busy. Every coverage
counter is non-zero summed over the suites. The game-like distribution alone never hits a
divide error or an SZ3/OTZ clamp, by design; the edge and uniform suites do. `make selftest`
reports exactly each injected fault, and each golden-side assertion fires on its injection.

`summarize.py` fails a run on any simulator error line, which covers the RTL's own assertions:
both lanes on one accumulator, and divides less than 3 cycles apart. It fails the total when
nothing ran (no runs, or no commands) and when the golden-side multiply or divide checks never
sampled. When the edge and random suites both run, it also fails if coverage lines are missing or
any counter is zero summed over all suites; `--min SUITE=N` sets a per-suite command floor. The
CPU-timing stream also puts write and read strobes on the same clk1x edge (a stalled MFC2
re-issues on `busy`/`cmdEna` only, `cpu.vhd:1163-1165`), resets while `ce` is low, writes the
read-only 29/31, and writes LZCS extremes read back through 31.

The boundary suite (914 commands per seed, every boundary on every seed) drives each saturation
point to limit−1, limit and limit+1 on both sides: IR1–3 with lm 0 and 1 and RGB through GPF,
MVMVA IR (cv 2 and 3) and MAC1–3 at ±2^43, and through RTPS IR0, MAC0 at ±2^31, SZ3, the divide
error and SX2/SY2. AVSZ3/AVSZ4 cover OTZ. It also writes FLAG (each single bit and its complement,
0, all ones) and reads it back before any command, since every command clears FLAG. Every
off-by-one compare mutant of those limits in `gte_serial.vhd`, and FLAG write mutants of the
bit-31 summary, fail it. The three that pass are equivalent: the IR value-path compares at
0, −32768 and 0x7FFF choose a branch that yields the same value.

Not constructible: an edge case with a `macLast` term near the 44-bit limit. In every command
`macLast` is a step-0 result (color << 16, IR × 0x1000) or a ×0x10 product, below 2^36, so the unwrapped feed
(`gte.vhd:756`) never carries a value that a 44-bit wrap would change.

## Gate metric

ALMs = the fitter's "Resource Utilization by Entity" **ALMs needed** for the `gte_serial` instance
alone, not the wrapper. `gte` is measured the same way in its own project. The map estimate and
"ALMs used in final placement" are reported alongside; they can differ by 18% on the same design
(`gte:igte` in the stripped build: 4,424.2 needed, 4,974.8 placed).

## Measurements

`sizing/gte_size.qpf`, revisions `gte_serial` and `gte_golden`: the GTE in `gte_size_wrap.vhd`,
every port registered on clk1x, virtual pins, `sizing/gte.sdc`. Quartus 21.1 Lite in
`raetro/quartus:21.1`, `NUM_PARALLEL_PROCESSORS 1`:
`docker run --rm --platform linux/amd64 -v "$PWD":/build -w /build/sizing raetro/quartus:21.1 quartus_sh --flow compile gte_size -c <rev>`,
then `quartus_sta -t report_gte.tcl <rev>` for the worst paths per clock and
`quartus_sta -t path_gte.tcl <rev>` for the full detail of the worst clk2x path in each slow corner.

These are default-settings, single-seed numbers: Balanced optimization, no physical synthesis,
fitter seed 1, clocks on ports with no PLL. The full build uses AGGRESSIVE PERFORMANCE with
physical-synthesis register duplication and retiming (`PSX.qsf:31-52`) and PLL clocks
(`derive_pll_clocks`, `PSX.sdc:1-2`). Register duplication can add ALMs and PLL jitter costs
slack, so both are re-measured inside the full build. The ROADMAP's ≥ +0.7 ns on a clk4x domain is
about 10% of its period; applied to clk2x that is +1.48 ns, which +2.025 ns (13.7%) also meets.

| | `gte_serial` | `gte` (golden) | Gate |
|---|---|---|---|
| ALMs needed, GTE instance (the gate metric) | **2,490.8** | 3,917.6 | ≤ 3,000 |
| ALMs used in final placement | 2,593.1 | 4,332.6 | |
| ALMs, map estimate (whole wrapper) | 2,640 | 3,951 | |
| Registers (whole wrapper) | 1,814 | 3,222 | |
| DSP blocks | **3** (two 18×18, one 27×27) | 15 | ≤ 4 |
| RAM blocks | 9 (3 register-file copies, 5 ROM, 1 divider shift taps) | 1 | |
| clk2x setup slack, slow 85 °C | **+2.025 ns** | +0.219 ns | > 0 |
| clk2x setup slack, slow 0 °C | +1.599 ns | −0.124 ns | |
| clk1x setup slack, slow 85 °C | +9.195 ns | +12.503 ns | > 0 |
| hold slack clk2x / clk1x, slow 85 °C | +0.393 / +0.495 ns | +0.322 / +0.532 ns | > 0 |
| hold slack clk2x / clk1x, slow 0 °C | +0.341 / +0.420 ns | +0.287 / +0.502 ns | > 0 |
| hold slack clk2x / clk1x, fast 85 °C | +0.174 / +0.177 ns | +0.148 / +0.170 ns | > 0 |
| hold slack clk2x / clk1x, fast 0 °C | +0.149 / +0.125 ns | +0.131 / +0.131 ns | > 0 |
| Fmax clk2x / clk1x, slow 85 °C | 78.5 / 311.9 MHz | 68.8 / 267.6 MHz | |

The worst clk2x paths are the divider's shared multiply into its round and compare, and a
lane's product into the 45-bit accumulate. Both execute stages need one carry chain: a sum written
as `x + a + 1` builds two chains in series, so the +1 of a negation enters as the carry of an
extra low bit.

**Gate: PASS.** Bit-exact and busy-exact on every suite (see [Verification](#verification)),
2,490.8 ≤ 3,000 ALMs, 3 ≤ 4 DSP, positive setup at slow 85 °C and positive hold in all four
corners. No clk4x domain exists, so the +0.7 ns clk4x criterion does not apply.
