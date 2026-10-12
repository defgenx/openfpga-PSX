`timescale 1ns/1ps
// cd_loader against an APF host model and a replica of cd_top's sector fetch states (cd_top.vhd:2575-2690).
// Host: a read lands as big-endian 32-bit bridge writes at the bridge address with random gaps, after a random latency up to the
// 6.67 ms deadline, then done; modes: normal, error code, short, trailing writes. Run: iverilog -g2005 -o out/cd_loader.vvp
// sim/tb_cd_loader.v fpga/core/cd_loader.v && vvp out/cd_loader.vvp
module tb_cd_loader;
    reg clk_a = 0, clk_s = 0, rst = 1;
    always #6.734 clk_a = ~clk_a;           // 74.25 MHz
    always #14.76 clk_s = ~clk_s;           // 33.87 MHz

    // bridge and target interface
    reg         bridge_wr = 0;
    reg  [31:0] bridge_addr = 0, bridge_wr_data = 0;
    wire        tgt_read;
    wire [15:0] tgt_id;
    wire [31:0] tgt_off, tgt_baddr, tgt_len;
    reg         tgt_done = 0;
    reg  [2:0]  tgt_err = 0;

    // core side
    reg         cd_hps_req = 0;
    reg  [31:0] cd_hps_lba = 32'hFFFFFFFF;
    wire        cd_hps_ack, cd_hps_write;
    wire [15:0] cd_hps_data;
    wire [31:0] trackinfo_data;
    wire [8:0]  trackinfo_addr;
    wire        trackinfo_write, trk_done, err;

    cd_loader dut (
        .rst(rst), .clk_74a(clk_a), .clk_sys(clk_s),
        .bridge_wr(bridge_wr), .bridge_addr(bridge_addr), .bridge_wr_data(bridge_wr_data),
        .tgt_read(tgt_read), .tgt_id(tgt_id), .tgt_off(tgt_off), .tgt_baddr(tgt_baddr), .tgt_len(tgt_len),
        .tgt_done(tgt_done), .tgt_err(tgt_err),
        .cd_hps_req(cd_hps_req), .cd_hps_lba(cd_hps_lba), .cd_hps_ack(cd_hps_ack), .cd_hps_write(cd_hps_write),
        .cd_hps_data(cd_hps_data), .trackinfo_data(trackinfo_data), .trackinfo_addr(trackinfo_addr),
        .trackinfo_write(trackinfo_write), .trk_done(trk_done), .err(err)
    );

    integer fails = 0;
    integer seed = 32'h1badcafe;
    function [7:0] img_byte(input [31:0] p);       // synthetic image content
        reg [31:0] h;
        begin h = (p ^ (p >> 7)) * 32'h9E3779B1; img_byte = h[31:24]; end
    endfunction

    // ---------------------------------------------------------------- host model, clk_74a
    integer mode = 0;                  // 0 normal, 1 error code, 2 short (one word missing), 3 trailing writes after done
    integer max_lat = 1000;            // clk_74a cycles of latency before the data
    integer n_reads = 0;
    reg [31:0] last_off;
    reg [15:0] last_id;
    reg [31:0] last_baddr, last_len;
    reg        prev_read = 0;
    integer    i, lat, gap, nw;
    reg [31:0] w;
    reg        busy_h = 0;
    always @(posedge clk_a) begin
        prev_read <= tgt_read;
        if (tgt_read && !prev_read && !busy_h) begin
            busy_h = 1;
            last_off = tgt_off; last_id = tgt_id; last_baddr = tgt_baddr; last_len = tgt_len;
            n_reads = n_reads + 1;
            repeat (3) @(posedge clk_a);
            tgt_done <= 0; tgt_err <= 0;           // stale done is cleared a few cycles after the command
            lat = $urandom(seed) % (max_lat + 1);
            repeat (lat) @(posedge clk_a);
            nw = (mode == 1) ? 0 : (mode == 2) ? (last_len / 4 - 1) : (mode == 3) ? (last_len / 4 - 2) : (last_len / 4);
            for (i = 0; i < nw; i = i + 1) begin
                w = {img_byte(last_off + 4*i), img_byte(last_off + 4*i + 1), img_byte(last_off + 4*i + 2), img_byte(last_off + 4*i + 3)};
                bridge_wr <= 1; bridge_addr <= last_baddr + 4*i; bridge_wr_data <= w;
                @(posedge clk_a);
                bridge_wr <= 0;
                gap = $urandom(seed) % 4;
                repeat (gap) @(posedge clk_a);
            end
            tgt_done <= 1; tgt_err <= (mode == 1) ? 3'd2 : 3'd0;
            @(posedge clk_a);
            if (mode == 3) begin                   // the last two words trail done
                for (i = nw; i < nw + 2; i = i + 1) begin
                    w = {img_byte(last_off + 4*i), img_byte(last_off + 4*i + 1), img_byte(last_off + 4*i + 2), img_byte(last_off + 4*i + 3)};
                    bridge_wr <= 1; bridge_addr <= last_baddr + 4*i; bridge_wr_data <= w;
                    @(posedge clk_a); bridge_wr <= 0; @(posedge clk_a); @(posedge clk_a);
                end
            end
            busy_h = 0;
        end
    end

    // ---------------------------------------------------------------- core model, clk_s: cd_top's SFETCH states
    localparam [1:0] F_IDLE = 0, F_ACK = 1, F_WORD = 2, F_DATA = 3;
    reg [1:0]  fst = F_IDLE;
    integer    fcount = 0, nwrites = 0;
    reg [31:0] sbuf [0:587];
    reg [31:0] cur;
    reg        got_all = 0, ack_seen = 0;
    always @(posedge clk_s) begin
        case (fst)
            F_ACK: if (cd_hps_ack) begin fst <= F_WORD; cd_hps_req <= 0; ack_seen = 1; end
            F_WORD: if (cd_hps_write) begin cur[15:0] = cd_hps_data; fst <= F_DATA; nwrites = nwrites + 1; end
            F_DATA: if (cd_hps_write) begin
                cur[31:16] = cd_hps_data; sbuf[fcount] = cur; nwrites = nwrites + 1;
                if (fcount == 587) begin fst <= F_IDLE; got_all = 1; end
                else begin fcount = fcount + 1; fst <= F_WORD; end
            end
            default: ;
        endcase
    end

    // one fetch: returns after the sector was received; the core waits for ack = 0 before the next request
    integer t0, t1, tdone;
    integer worst_ovh = 0;
    reg [31:0] exp_w;
    integer errs_here;
    task fetch(input [31:0] lba, input expect_zero);
        integer k, nb;
        begin
            @(posedge clk_s);
            while (cd_hps_ack) @(posedge clk_s);
            fcount = 0; nwrites = 0; got_all = 0; ack_seen = 0;
            cd_hps_lba <= lba; cd_hps_req <= 1; fst <= F_ACK;
            t0 = $time;
            fork : wd
                begin wait (got_all); disable wd; end
                begin #(30_000_000); $display("  fetch of %0d timed out (ack_seen=%0d nwrites=%0d)", lba, ack_seen, nwrites); fails = fails + 1; disable wd; end
            join
            t1 = $time;
            if (!got_all) begin fst <= F_IDLE; cd_hps_req <= 0; end
            else begin
                errs_here = 0;
                for (k = 0; k < 588; k = k + 1) begin
                    nb = (lba - 150) * 2352 + 4*k;
                    exp_w = expect_zero ? 32'd0 : {img_byte(nb+3), img_byte(nb+2), img_byte(nb+1), img_byte(nb)};
                    if (sbuf[k] !== exp_w) begin
                        if (errs_here < 3) $display("  lba %0d word %0d: got %h want %h", lba, k, sbuf[k], exp_w);
                        errs_here = errs_here + 1;
                    end
                end
                if (nwrites != 1176) begin $display("  lba %0d: %0d writes, want 1176", lba, nwrites); errs_here = errs_here + 1; end
                if (errs_here) fails = fails + 1;
            end
            // ack must fall again
            repeat (20) @(posedge clk_s);
            if (cd_hps_ack) begin $display("  ack still high after the sector"); fails = fails + 1; end
        end
    endtask

    // overhead: from done on the bridge to the last word at the core
    time done_t, last_w_t;
    always @(posedge tgt_done) done_t = $time;
    always @(posedge clk_s) if (cd_hps_write) last_w_t = $time;

    // ---------------------------------------------------------------- track table check
    integer tn = 0, terr = 0;
    reg [31:0] tx_data [0:511];
    reg [8:0]  tx_addr [0:511];
    always @(posedge clk_s) if (trackinfo_write) begin tx_data[tn] = trackinfo_data; tx_addr[tn] = trackinfo_addr; tn = tn + 1; end

    integer rises = 0, rises0;
    always @(posedge trk_done) rises = rises + 1;
    reg [31:0] tw [0:511];
    task load_trk(input integer n, input integer gapmax);
        integer k, g;
        reg [31:0] v;
        begin
            tn = 0; rises0 = rises;
            for (k = 0; k < n; k = k + 1) tw[k] = $urandom(seed);
            for (k = 0; k < n; k = k + 1) begin
                v = tw[k];                                   // little-endian file word: first byte is v[7:0]
                @(posedge clk_a);
                bridge_wr <= 1; bridge_addr <= 32'h30000000 + 4*k; bridge_wr_data <= {v[7:0], v[15:8], v[23:16], v[31:24]};
                @(posedge clk_a); bridge_wr <= 0;
                g = $urandom(seed) % (gapmax + 1);
                repeat (g) @(posedge clk_a);
            end
            wait (rises != rises0);
            repeat (10) @(posedge clk_s);
            terr = 0;
            if (tn != n) begin $display("  track table: %0d words delivered, want %0d", tn, n); terr = terr + 1; end
            for (k = 0; k < n && k < tn; k = k + 1)
                if (tx_addr[k] !== k || tx_data[k] !== tw[k]) begin
                    if (terr < 4) $display("  track word %0d: addr %0d data %h want %h", k, tx_addr[k], tx_data[k], tw[k]);
                    terr = terr + 1;
                end
            if (terr) fails = fails + 1;
        end
    endtask

    integer r, nl;
    reg [31:0] lbas [0:15];
    initial begin
        repeat (6) @(posedge clk_s);
        rst = 0;
        repeat (10) @(posedge clk_s);

        $display("track table");
        load_trk(40, 3);
        load_trk(512, 0);              // full 2,048 bytes: complete on word 511
        load_trk(8, 0);                // reload while the core is idle

        $display("sectors, latency to the 6.67 ms deadline");
        max_lat = 495000;
        lbas[0] = 150; lbas[1] = 151; lbas[2] = 150 + 333000; lbas[3] = 524287; lbas[4] = 150;
        for (r = 0; r < 5; r = r + 1) begin
            fetch(lbas[r], 0);
            if (tgt_off !== (lbas[r] - 150) * 2352 || last_id !== 16'd1 || last_baddr !== 32'h50000000 || last_len !== 32'd2352) begin
                $display("  command: off %0d id %0d baddr %h len %0d", last_off, last_id, last_baddr, last_len); fails = fails + 1;
            end
            if (last_off !== (lbas[r] - 150) * 2352) begin $display("  offset %0d for lba %0d", last_off, lbas[r]); fails = fails + 1; end
        end
        if (err) begin $display("  err set after good reads"); fails = fails + 1; end

        $display("random LBAs, random latency");
        for (r = 0; r < 12; r = r + 1) begin
            nl = 150 + ($urandom(seed) % 500000);
            max_lat = 100 + ($urandom(seed) % 495000);
            fetch(nl, 0);
            if (last_off !== (nl - 150) * 2352) begin $display("  offset %0d for lba %0d", last_off, nl); fails = fails + 1; end
        end
        $display("worst done-to-last-word overhead %0d ns", worst_ovh);

        $display("lba below 150 reads nothing and delivers zeros");
        max_lat = 100;
        r = n_reads;
        fetch(0, 1); fetch(149, 1);
        if (n_reads != r) begin $display("  APF read issued for the pregap"); fails = fails + 1; end
        if (err) begin $display("  err set by pregap"); fails = fails + 1; end

        $display("error code: zeros and err");
        mode = 1; fetch(1000, 1);
        if (!err) begin $display("  err not set"); fails = fails + 1; end
        mode = 0;
        $display("short read: zeros");
        mode = 2; fetch(2000, 1); mode = 0;
        $display("words trailing done");
        mode = 3; fetch(2500, 0); mode = 0;
        $display("good read after errors");
        fetch(3000, 0);

        if (fails == 0) $display("PASS");
        else $display("FAIL (%0d)", fails);
        $finish;
    end

    // measure the overhead after each done
    always @(posedge clk_s) if (got_all && $time > done_t && (last_w_t - done_t) > worst_ovh && (last_w_t - done_t) < 1000000000) worst_ovh = last_w_t - done_t;

    initial begin #4_000_000_000; $display("FAIL (global timeout)"); $finish; end
endmodule
