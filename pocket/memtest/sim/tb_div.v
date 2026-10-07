`timescale 1ns/1ps
// div32 against the Verilog divider on random operands.
module tb_div;
    reg clk = 0;
    always #5 clk = ~clk;
    reg start = 0;
    reg [31:0] num = 0, den = 1;
    wire done; wire [31:0] q;
    div32 dut (.clk(clk), .start(start), .num(num), .den(den), .done(done), .q(q));
    integer i, bad = 0;
    reg [31:0] n, d, want;
    initial begin
        for (i = 0; i < 2000; i = i + 1) begin
            n = $random; d = $random;
            if (i % 4 == 0) d = d >> ($random & 31);
            if (i % 7 == 0) n = n >> ($random & 31);
            if (d == 0) d = 1;
            @(posedge clk); num <= n; den <= d; start <= 1;
            @(posedge clk); start <= 0;
            @(posedge clk); while (!done) @(posedge clk);
            want = n / d;
            if (q !== want) begin bad = bad + 1; $display("div %0d / %0d = %0d, want %0d", n, d, q, want); end
        end
        // divide by zero returns all ones, never hangs
        @(posedge clk); num <= 32'd5; den <= 32'd0; start <= 1;
        @(posedge clk); start <= 0;
        @(posedge clk); while (!done) @(posedge clk);
        if (q !== 32'hFFFFFFFF) begin bad = bad + 1; $display("div by zero gave %h", q); end
        if (bad == 0) $display("PASS"); else $display("FAIL (%0d)", bad);
        $finish;
    end
endmodule
