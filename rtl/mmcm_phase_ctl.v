// mmcm_phase_ctl
// ==============
// Run-time fine phase shift of the MMCM that makes the trace sampling clock
// (see trace_capture_a7, CLK_BUF = "MMCM"), and the lock supervision it needs.
//
// The host writes a signed step count (`phase_tgt`); this block walks the MMCM
// there one PSEN pulse at a time. One step is 1/56 of the VCO period (about
// 25 ps for a 700 MHz VCO). A step takes 12 PSCLK cycles (PSDONE).
//
// An MMCM that loses its input clock loses lock, and comes back at phase 0
// when it relocks. So this block also
//   * resets the MMCM at start-up and whenever it has stayed unlocked for
//     UNLOCK_TIMEOUT clk cycles (the clock was gone or changed frequency),
//   * resets `cur` to 0 whenever lock is lost and walks to the target again
//     once the MMCM has locked,
//   * resets the MMCM on a `relock_tog` toggle (host request).
//
// `clk` is the PSCLK. `phase_tgt` and `relock_tog` come from another clock
// domain; they are quasi-static and are re-synchronised here (the target is
// taken once it has been stable for two samples).
//
// Outputs `locked_o`, `cur` and `busy` are in the `clk` domain.

`default_nettype none

module mmcm_phase_ctl #(
    parameter integer MAX_STEPS      = 255,       // |phase| limit, steps
    parameter integer UNLOCK_TIMEOUT = 1 << 20,   // clk cycles before a reset
    parameter integer RST_CYCLES     = 16,        // MMCM RST pulse length
    parameter integer DONE_TIMEOUT   = 64         // clk cycles to wait for PSDONE
) (
    input  wire               clk,
    input  wire               rst,           // active high, sync to clk

    // control (any domain, quasi-static)
    input  wire signed [9:0]  phase_tgt,
    input  wire               relock_tog,

    // MMCM
    input  wire               mmcm_locked,   // async
    input  wire               psdone,
    output reg                mmcm_rst,
    output reg                psen,
    output reg                psincdec,

    // status (clk domain)
    output wire               locked_o,
    output reg  signed [9:0]  cur,
    output wire               busy,
    output reg  [7:0]         lock_lost_cnt,  // saturating
    output reg                ps_timeout      // sticky: PSDONE never came
);

    // ---- input synchronisers ----
    reg [2:0] lk;                       // mmcm_locked
    reg signed [9:0] t1, t2, t3;        // phase_tgt
    reg [2:0] rl;                       // relock_tog
    always @(posedge clk) begin
        lk <= {lk[1:0], mmcm_locked};
        t1 <= phase_tgt; t2 <= t1; t3 <= t2;
        rl <= {rl[1:0], relock_tog};
    end
    wire locked = lk[2];
    assign locked_o = locked;
    wire relock = rl[2] ^ rl[1];

    // target: take a new value once stable, clamp to +-MAX_STEPS
    function signed [9:0] clamp(input signed [9:0] v);
        if      (v >  MAX_STEPS) clamp =  MAX_STEPS;
        else if (v < -MAX_STEPS) clamp = -MAX_STEPS;
        else                     clamp = v;
    endfunction
    reg signed [9:0] tgt;
    always @(posedge clk) begin
        if (rst)            tgt <= 10'sd0;
        else if (t2 == t3)  tgt <= clamp(t3);
    end
    // a new target is on its way through the synchroniser
    wire pending = (t1 != t2) || (t2 != t3) || (clamp(t3) != tgt);

    localparam [2:0] S_RESET = 3'd0, S_WAIT_LOCK = 3'd1, S_IDLE = 3'd2,
                     S_STEP  = 3'd3, S_WAIT_DONE = 3'd4;
    reg [2:0]  st;
    reg [4:0]  rcnt;
    reg [21:0] tcnt;
    reg [6:0]  dcnt;
    reg        locked_d;
    reg        stepping_up;

    assign busy = (st != S_IDLE) || (cur != tgt) || pending;

    always @(posedge clk) begin
        psen     <= 1'b0;
        locked_d <= locked;
        if (rst) begin
            st <= S_RESET; rcnt <= 0; tcnt <= 0; dcnt <= 0;
            mmcm_rst <= 1'b1; psincdec <= 1'b0; cur <= 10'sd0;
            lock_lost_cnt <= 8'd0; ps_timeout <= 1'b0; stepping_up <= 1'b0;
            locked_d <= 1'b0;
        end else begin
            // a lock that goes away takes the phase with it
            if (locked_d && !locked) begin
                cur <= 10'sd0;
                if (lock_lost_cnt != 8'hFF) lock_lost_cnt <= lock_lost_cnt + 8'd1;
            end
            case (st)
            S_RESET: begin
                mmcm_rst <= 1'b1;
                cur      <= 10'sd0;
                if (rcnt == RST_CYCLES - 1) begin
                    rcnt <= 0; tcnt <= 0; mmcm_rst <= 1'b0; st <= S_WAIT_LOCK;
                end else rcnt <= rcnt + 5'd1;
            end
            S_WAIT_LOCK: begin
                mmcm_rst <= 1'b0;
                cur      <= 10'sd0;
                if (relock) begin
                    st <= S_RESET; rcnt <= 0;
                end else if (locked) begin
                    st <= S_IDLE; tcnt <= 0;
                end else if (tcnt == UNLOCK_TIMEOUT - 1) begin
                    st <= S_RESET; rcnt <= 0;
                end else tcnt <= tcnt + 22'd1;
            end
            S_IDLE: begin
                if (relock) begin
                    st <= S_RESET; rcnt <= 0;
                end else if (!locked) begin
                    st <= S_WAIT_LOCK; tcnt <= 0;
                end else if (cur != tgt) begin
                    stepping_up <= (tgt > cur);
                    st <= S_STEP;
                end
            end
            S_STEP: begin
                psen     <= 1'b1;
                psincdec <= stepping_up;
                dcnt     <= 0;
                st       <= S_WAIT_DONE;
            end
            S_WAIT_DONE: begin
                if (psdone) begin
                    cur <= stepping_up ? cur + 10'sd1 : cur - 10'sd1;
                    st  <= S_IDLE;
                end else if (dcnt == DONE_TIMEOUT - 1) begin
                    ps_timeout <= 1'b1;
                    st <= S_RESET; rcnt <= 0;
                end else dcnt <= dcnt + 7'd1;
            end
            default: st <= S_RESET;
            endcase
        end
    end

    initial begin
        lk = 3'b000; rl = 3'b000;
        t1 = 0; t2 = 0; t3 = 0; tgt = 0;
        st = S_RESET; rcnt = 0; tcnt = 0; dcnt = 0;
        mmcm_rst = 1'b1; psen = 1'b0; psincdec = 1'b0; cur = 0;
        lock_lost_cnt = 0; ps_timeout = 1'b0; locked_d = 1'b0; stepping_up = 1'b0;
    end
endmodule

`default_nettype wire
