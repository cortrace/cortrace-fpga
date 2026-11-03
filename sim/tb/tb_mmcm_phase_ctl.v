// tb_mmcm_phase_ctl
// =================
// mmcm_phase_ctl against a behavioural MMCM (lock after a delay once RST is
// low and the input clock runs; PSDONE 12 PSCLK cycles after PSEN; the shift
// is lost when lock is lost). Checks:
//   A) start-up: the block resets the MMCM and reaches idle once it locks
//   B) a target of +7 then -4 is reached, with exactly |delta| PSEN pulses,
//      the right direction for each and the model's phase equal to `cur`
//   C) targets beyond +-MAX_STEPS are clamped
//   D) lock loss (input clock stops) clears `cur`; after the clock returns
//      and the MMCM locks again the block walks to the target again
//   E) a clock that stays away longer than UNLOCK_TIMEOUT gets an MMCM reset
//   F) a relock toggle resets the MMCM and the phase comes back
`timescale 1ns/1ps
`default_nettype none
module tb_mmcm_phase_ctl;
    reg clk = 0;
    always #2.5 clk = ~clk;                 // PSCLK, 200 MHz

    reg rst = 1;
    reg signed [9:0] tgt = 0;
    reg relock_tog = 0;

    // ---- behavioural MMCM ----
    reg  in_clk_run = 1;                    // TRACECLK present
    wire mm_rst, psen, psincdec;
    reg  locked = 0, psdone = 0;
    integer mm_phase = 0;
    integer lock_cnt = 0, ps_cnt = -1, rst_pulses = 0, inc_cnt = 0, dec_cnt = 0;
    reg  ps_dir = 0;
    localparam LOCK_CLKS = 40;
    reg mm_rst_d = 0;
    always @(posedge clk) begin
        psdone <= 1'b0;
        mm_rst_d <= mm_rst;
        if (mm_rst && !mm_rst_d) rst_pulses = rst_pulses + 1;
        if (mm_rst || !in_clk_run) begin
            locked <= 1'b0; lock_cnt = 0; mm_phase = 0; ps_cnt = -1;
        end else begin
            if (lock_cnt < LOCK_CLKS) lock_cnt = lock_cnt + 1;
            else locked <= 1'b1;
        end
        if (locked && psen && ps_cnt < 0) begin
            ps_cnt = 0; ps_dir = psincdec;
            if (psincdec) inc_cnt = inc_cnt + 1; else dec_cnt = dec_cnt + 1;
        end
        if (ps_cnt >= 0) begin
            ps_cnt = ps_cnt + 1;
            if (ps_cnt == 12) begin
                psdone <= 1'b1;
                mm_phase = mm_phase + (ps_dir ? 1 : -1);
                ps_cnt = -1;
            end
        end
    end

    wire locked_o, busy, ps_timeout;
    wire signed [9:0] cur;
    wire [7:0] lost;
    mmcm_phase_ctl #(.MAX_STEPS(20), .UNLOCK_TIMEOUT(2000), .RST_CYCLES(8)) dut (
        .clk(clk), .rst(rst), .phase_tgt(tgt), .relock_tog(relock_tog),
        .mmcm_locked(locked), .psdone(psdone), .mmcm_rst(mm_rst), .psen(psen),
        .psincdec(psincdec), .locked_o(locked_o), .cur(cur), .busy(busy),
        .lock_lost_cnt(lost), .ps_timeout(ps_timeout)
    );

    integer fails = 0;
    task check(input cond, input [255:0] what);
        if (!cond) begin fails = fails + 1; $display("FAIL: %0s", what); end
    endtask
    task wait_idle(input integer max);
        integer n;
        begin
            n = 0;
            repeat (6) @(posedge clk);   // a new target needs a few cycles to arrive
            while ((busy || !locked_o) && n < max) begin @(posedge clk); n = n + 1; end
            repeat (8) @(posedge clk);
        end
    endtask

    initial begin
        repeat (10) @(posedge clk);
        rst = 0;
        // A
        wait_idle(1000);
        check(locked_o, "A: locked after start-up");
        check(cur == 0, "A: phase 0 after start-up");
        check(rst_pulses >= 1, "A: MMCM was reset at start-up");
        // B
        inc_cnt = 0; dec_cnt = 0;
        tgt = 7; wait_idle(3000);
        check(cur == 7, "B: reached +7");
        check(mm_phase == 7, "B: model phase +7");
        check(inc_cnt == 7 && dec_cnt == 0, "B: 7 increments");
        tgt = -4; wait_idle(5000);
        check(cur == -4, "B: reached -4");
        check(mm_phase == -4, "B: model phase -4");
        check(inc_cnt == 7 && dec_cnt == 11, "B: 11 decrements");
        // C
        tgt = 100; wait_idle(10000);
        check(cur == 20 && mm_phase == 20, "C: clamped to +20");
        tgt = -100; wait_idle(10000);
        check(cur == -20 && mm_phase == -20, "C: clamped to -20");
        tgt = 5; wait_idle(10000);
        // D
        in_clk_run = 0;
        repeat (50) @(posedge clk);
        check(!locked_o, "D: unlocked while the clock is away");
        check(cur == 0, "D: phase cleared by lock loss");
        check(lost >= 1, "D: lock loss counted");
        in_clk_run = 1;
        wait_idle(3000);
        check(locked_o, "D: locked again");
        check(cur == 5 && mm_phase == 5, "D: walked back to +5");
        // E: stay away longer than the timeout
        rst_pulses = 0;
        in_clk_run = 0;
        repeat (5000) @(posedge clk);
        check(rst_pulses >= 1, "E: MMCM reset after the unlock timeout");
        in_clk_run = 1;
        wait_idle(3000);
        check(locked_o && cur == 5 && mm_phase == 5, "E: recovered to +5");
        // F
        rst_pulses = 0;
        relock_tog = ~relock_tog;
        repeat (20) @(posedge clk);
        check(rst_pulses == 1, "F: relock request resets the MMCM");
        wait_idle(3000);
        check(locked_o && cur == 5 && mm_phase == 5, "F: phase back at +5");
        check(!ps_timeout, "no PSDONE timeout");
        if (fails == 0) $display("RESULT=ALL_PASS");
        else            $display("RESULT=FAIL fails=%0d", fails);
        $finish;
    end
    initial begin #50000000; $display("RESULT=FAIL timeout"); $finish; end
endmodule
`default_nettype wire
