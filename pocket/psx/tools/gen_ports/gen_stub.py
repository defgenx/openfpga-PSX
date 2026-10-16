# Run from this directory after ports.py: python3 ports.py && python3 gen_stub.py && python3 gen_inst.py && python3 gen_flat.py
# ports.py reads the entity of rtl/psx_top_pocket.vhd; gen_stub.py writes psx_top_stub.v, gen_flat.py psx_top_pocket_flat.vhd,
# gen_inst.py the stub instance and glue wiring that core_top.v carries (copy the output by hand).
import json
P=json.load(open('ports.json'))
def dom(n,d):
    if n.startswith(('ram_','cache_','dma_','ddr3_','Cheats_Bus')): return '3x'
    if n.startswith(('spuram_','sound_out_')): return '2x'
    if d=='output' and (n in('hsync','vsync','hblank','vblank','video_ce','video_interlace') or n.startswith(('Display','video_'))): return 'vid'
    return '1x'
clk={'1x':'clk1x','2x':'clk2x','3x':'clk3x','vid':'clkvid'}
order=['1x','2x','3x','vid']
out=[]
o=out.append
o("""// Black-box stand-in for rtl/psx_top_pocket.vhd: the ports of psx_top_pocket_flat.vhd, driven by registered pseudo-random sources.
// Every input is XOR-folded into the source of its clock domain, so nothing behind the ports can be pruned.
// Replaced by psx_top_pocket_flat.vhd and the rtl files through the qsf. Mapping and the joypad packing: docs/pocket/POCKET_TOP.md.
// Domains: clk3x ram_* ddr3_* cache_* dma_* Cheats_Bus*; clk2x spuram_* sound_out_*; clkvid video outputs; clk1x the rest.
// joypadN is the joypad_t record flattened, first field in the MSB: PadPort{Enable,Digital,Analog,Mouse,GunCon,NeGcon,
// Justif,DS,Stick,Popn}, WheelMap, ToggleDS, Key{Triangle,Circle,Cross,Square,Select,Start,Right,Left,Up,Down,R1,R2,R3,L1,L2,L3},
// Analog1X, Analog1Y, Analog2X, Analog2Y (signed 8 bit each, [31:0]).
`default_nettype none

module psx_top_pocket_flat #(
    parameter [0:0] is_simu        = 1'b0,
    parameter       NO_MDEC        = 0,
    parameter       G_GPU_IMPL     = "pocket",
    parameter       G_CPU_IMPL     = "golden",
    parameter       G_SPU_IMPL     = "golden",
    parameter       G_CD_IMPL      = "golden",
    parameter       G_DMA_IMPL     = "golden",
    parameter       G_BUS_IMPL     = "golden",
    parameter       G_JOYPAD_IMPL  = "golden",
    parameter       G_MEMCARD_IMPL = "golden",
    parameter       G_MDEC_IMPL    = "golden",
    parameter       G_CD_NO_LIBCRYPT    = 0,
    parameter       G_CD_FIXED_TIMING   = 0,
    parameter       G_CD_NO_PEAK        = 0,
    parameter       G_CPU_NO_COP0_DEBUG = 0
) (""")
decl=[]
for n,d,w in P:
    r=f" [{w-1}:0]" if w>1 else ""
    if n in clk.values(): pass
    decl.append(f"    {d} wire{r} {n}")
o(",\n".join(decl))
o(");\n")
# width per domain
W={k:0 for k in order}
for n,d,w in P:
    if d=='output': W[dom(n,d)]+=w
alloc={k:0 for k in order}
for k in order:
    o(f"// ---- {clk[k]} domain")
    w=max(W[k],16)
    ins=[(n,wd) for n,d,wd in P if d=='input' and dom(n,d)==k and n not in clk.values()]
    cat=", ".join(n for n,wd in ins)
    o(f"reg [{w-1}:0] s_{k} = {w}'d0;")
    o(f"reg        f_{k} = 1'b0;")
    if ins:
        o(f"always @(posedge {clk[k]}) f_{k} <= ^{{{cat}}};")
    else:
        o(f"always @(posedge {clk[k]}) f_{k} <= 1'b0;")
    o(f"always @(posedge {clk[k]}) s_{k} <= {{s_{k}[{w-2}:0], s_{k}[{w-1}]}} ^ {{s_{k}[{w//3-1}:0], s_{k}[{w-1}:{w//3}]}} ^ {{{{{w-1}{{1'b0}}}}, f_{k} ^ ~s_{k}[{w-1}]}};")
    for n,d,wd in P:
        if d=='output' and dom(n,d)==k:
            o(f"assign {n} = s_{k}[{alloc[k]} +: {wd}];")
            alloc[k]+=wd
    o("")
# clock inputs are used by the always blocks; 'reset' folds in the 1x domain
o("endmodule")
open('psx_top_stub.v','w').write("\n".join(out)+"\n")
print(W)
