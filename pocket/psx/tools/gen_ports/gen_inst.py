# Run from this directory after ports.py: python3 ports.py && python3 gen_stub.py && python3 gen_inst.py && python3 gen_flat.py
# ports.py reads the entity of rtl/psx_top_pocket.vhd; gen_stub.py writes psx_top_stub.v, gen_flat.py psx_top_pocket_flat.vhd,
# gen_inst.py the stub instance and glue wiring that core_top.v carries (copy the output by hand).
import json
exec(open('gen_stub.py').read().split("clk={")[0])  # P, dom
clkn={'clk1x','clk2x','clk3x','clkvid'}
over={ # stub input -> expression (core_top / glue wires)
 'clk1x':'clk1x','clk2x':'clk2x','clk3x':'clk3x','clkvid':'clk_vid',
 'reset':'rst_1x',
 'ddr3_BUSY':'g_ddr3_busy','ddr3_DOUT':'g_ddr3_dout','ddr3_DOUT_READY':'g_ddr3_dout_ready',
 'ram_dataRead32':'g_ram_data_read','ram_done':'g_ram_done',
 'spuram_dataRead':'g_spuram_data_read','spuram_done':'g_spuram_done',
 'memcard1_ack':'g_memcard1_ack','memcard1_dataIn':'g_memcard1_data_in',
 'cd_hps_ack':'cd_ack_1x','cd_hps_write':'win_wr_1x','cd_hps_data':'win_data_1x[15:0]',
 'trackinfo_write':'win_wr_1x','trackinfo_data':'win_data_1x','trackinfo_addr':'win_addr_1x[8:0]',
 'joypad1':'{cfg_1x[11:0], pad_1x[47:0]}','joypad2':'{cfg_1x[23:12], pad_1x[95:48]}',
 'joypad3':'{cfg_1x[11:0] ^ cfg_1x[23:12], pad_1x[143:96]}','joypad4':'{cfg_1x[31:20], pad_1x[191:144]}',
}
# glue consumes these outputs
consumed={'ram_ena','ram_rnw','ram_Adr','ram_dataWrite','ram_be','ddr3_WE','ddr3_RD','ddr3_ADDR','ddr3_DIN','ddr3_BE',
 'spuram_ena','spuram_Adr','memcard1_rd','memcard1_wr','memcard1_lba','memcard1_dataOut','cd_hps_req','cd_hps_lba',
 'sound_out_left','sound_out_right','video_r','video_g','video_b','hsync','vsync','hblank','vblank'}
o=[]
for n,d,w in P:
    if n in clkn: continue
    r=f"[{w-1}:0] " if w>1 else ""
    o.append(f"wire {r}psx_{n};")
o.append("")
pool={'1x':282,'3x':96}
off={'1x':0,'3x':0}
for n,d,w in P:
    if d!='input' or n in clkn: continue
    k=dom(n,d)
    if n in over:
        o.append(f"assign psx_{n} = {over[n]};")
    else:
        sz=pool[k]; s=off[k]
        # wrap-around slice built from concatenation
        parts=[]
        rem=w; pos=s
        while rem>0:
            take=min(rem,sz-pos%sz) if False else min(rem, sz-(pos%sz))
            hi=pos%sz+take-1; lo=pos%sz
            parts.append(f"pool_{k}[{hi}:{lo}]")
            rem-=take; pos+=take
        off[k]=pos%sz
        o.append(f"assign psx_{n} = {{{', '.join(reversed(parts))}}};" if len(parts)>1 else f"assign psx_{n} = {parts[0]};")
o.append("")
for k in ['1x','2x','3x','vid']:
    lst=[f"psx_{n}" for n,d,w in P if d=='output' and dom(n,d)==k and n not in consumed]
    o.append(f"wire left_{k}_i = ^{{{', '.join(lst)}}};" if lst else f"wire left_{k}_i = 1'b0;")
o.append("")
o.append("psx_top_pocket_flat stub (")
conn=[]
for n,d,w in P:
    conn.append(f"    .{n}( {'psx_'+n if n not in clkn else over[n]} )")
o.append(",\n".join(conn))
o.append(");")
open('stub_inst.v','w').write("\n".join(o)+"\n")
