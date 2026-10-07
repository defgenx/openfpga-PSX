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
