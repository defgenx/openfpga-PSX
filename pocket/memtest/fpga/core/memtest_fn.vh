// Pattern functions shared by the engines; include inside a module. See memtest_defs.vh.
`include "memtest_defs.vh"

// Xorshift32. The same function seeds addresses and builds the test data.
function [31:0] xs32;
    input [31:0] x;
    reg [31:0] y;
    begin
        y = x ^ (x << 13);
        y = y ^ (y >> 17);
        y = y ^ (y << 5);
        xs32 = y;
    end
endfunction

// Data of 32-bit word a (PSRAM word address or SDRAM word address / 2).
function [31:0] pat32;
    input [31:0] a;
    input [31:0] seed;
    begin
        pat32 = xs32(a ^ seed) ^ 32'h9E3779B9;
    end
endfunction

// Data of the 64-bit SDRAM burst starting at 16-bit word address w (multiple of 4).
function [63:0] pat64;
    input [31:0] w;
    input [31:0] seed;
    begin
        pat64 = {pat32((w >> 1) + 32'd1, seed), pat32(w >> 1, seed)};
    end
endfunction

// Byte-enable test (docs/pocket/MEMTEST.md): the region is first filled with pat64; the masked
// writes then carry ~pat64 under a per-address mask, so every byte of a read-back burst is
// either the old (fill) byte or the new one and needs no shadow memory.
// Mask bit 2k+j enables byte j of 16-bit word k of the burst; w is the burst's word address.
function [7:0] be_mask;
    input [31:0] w;
    input [31:0] seed;
    reg [31:0] h;
    begin
        h = xs32((w >> 2) ^ seed ^ 32'h5BD1E995);
        be_mask = h[15:8];
    end
endfunction

function [63:0] be_merge;       // result of writing new under mask m over old
    input [63:0] new_d;
    input [63:0] old_d;
    input [7:0]  m;
    integer j;
    begin
        for (j = 0; j < 8; j = j + 1)
            be_merge[j*8 +: 8] = m[j] ? new_d[j*8 +: 8] : old_d[j*8 +: 8];
    end
endfunction
