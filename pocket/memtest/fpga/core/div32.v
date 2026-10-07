// Serial restoring divider, 32 cycles. q = num / den (den = 0 gives all ones).
module div32 (
    input  wire        clk,
    input  wire        start,
    input  wire [31:0] num,
    input  wire [31:0] den,
    output reg         done,
    output reg  [31:0] q
);
    reg [31:0] n, d;
    reg [32:0] r;
    reg [5:0]  cnt;
    reg        run;
    wire [32:0] r_sh = {r[31:0], n[31]};
    wire        ge   = r_sh >= {1'b0, d};

    always @(posedge clk) begin
        done <= 1'b0;
        if (start) begin
            n <= num; d <= den; r <= 33'd0; q <= 32'd0; cnt <= 6'd0; run <= 1'b1;
        end else if (run) begin
            r <= ge ? r_sh - {1'b0, d} : r_sh;
            q <= {q[30:0], ge};
            n <= {n[30:0], 1'b0};
            cnt <= cnt + 1'b1;
            if (cnt == 6'd31) begin run <= 1'b0; done <= 1'b1; end
        end
    end
endmodule
