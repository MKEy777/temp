`timescale 1ns / 1ps

module GALS_Collector_Unit #(
    parameter OUT_NEURONS      = 64,
    parameter WATCHDOG_TIMEOUT = 10000 
) (
    input  wire                      local_clk,
    input  wire                      rst_n,
    input  wire                      i_aer_req,
    output reg                       o_aer_ack,
    input  wire [OUT_NEURONS-1:0]    i_pe_done_req_vec,
    output reg  [OUT_NEURONS-1:0]    o_pe_done_ack_vec,
    output reg                       o_error,
    output wire                      o_busy
);
    localparam NEURON_IDX_W = $clog2(OUT_NEURONS);

    localparam S_IDLE            = 4'b0000;
    localparam S_CHECK_PENDING   = 4'b0001;
    localparam S_ACK_HIGH        = 4'b0010;
    localparam S_WAIT_REQ_LOW    = 4'b0011;
    localparam S_ACK_LOW         = 4'b0100;
    localparam S_SEND_GLOBAL_ACK = 4'b0101;
    localparam S_TIMEOUT_ERROR   = 4'b1000;

    reg [3:0] state, next_state;
    reg [$clog2(OUT_NEURONS):0] n_done_cnt;
    reg [$clog2(WATCHDOG_TIMEOUT):0] watchdog_cnt;
    reg [OUT_NEURONS-1:0] pe_ack_done_reg;
    reg [NEURON_IDX_W-1:0] latched_index;

    reg [OUT_NEURONS-1:0] i_pe_done_req_s1;
    reg [OUT_NEURONS-1:0] i_pe_done_req_sync;

    wire [OUT_NEURONS-1:0] pending_reqs;
    wire has_pending_req;
    wire [NEURON_IDX_W-1:0] pe_index_to_ack;

    assign pending_reqs = i_pe_done_req_sync & (~pe_ack_done_reg);

    priority_encoder_std #(
        .N    (OUT_NEURONS),
        .IDXW (NEURON_IDX_W)
    ) enc_pending (
        .in   (pending_reqs),
        .has  (has_pending_req),
        .idx  (pe_index_to_ack)
    );

    always @(*) begin
        next_state        = state;
        o_aer_ack         = 1'b0;
        o_pe_done_ack_vec = {OUT_NEURONS{1'b0}};
        o_error           = 1'b0;
        
        case (state)
            S_IDLE: begin
                if (i_aer_req)
                    next_state = S_CHECK_PENDING;
            end
            
            S_CHECK_PENDING: begin
                if (watchdog_cnt >= WATCHDOG_TIMEOUT)
                    next_state = S_TIMEOUT_ERROR;
                else if (has_pending_req)
                    next_state = S_ACK_HIGH;
                else if (n_done_cnt == OUT_NEURONS)
                    next_state = S_SEND_GLOBAL_ACK;
            end
            
            S_ACK_HIGH: begin
                o_pe_done_ack_vec[latched_index] = 1'b1;
                next_state = S_WAIT_REQ_LOW;
            end
            
            S_WAIT_REQ_LOW: begin
                o_pe_done_ack_vec[latched_index] = 1'b1;
                if (!i_pe_done_req_sync[latched_index])
                    next_state = S_ACK_LOW;
            end
            
            S_ACK_LOW: begin
                next_state = S_CHECK_PENDING;
            end

            S_SEND_GLOBAL_ACK: begin
                o_aer_ack = 1'b1;
                next_state = S_IDLE;
            end
            
            S_TIMEOUT_ERROR: begin
                o_error = 1'b1;
                next_state = S_TIMEOUT_ERROR;
            end
            
            default: next_state = S_IDLE;
        endcase
    end
    
    always @(posedge local_clk or negedge rst_n) begin
        if (!rst_n) begin
            state               <= S_IDLE;
            n_done_cnt          <= 0;
            watchdog_cnt        <= 0;
            pe_ack_done_reg     <= {OUT_NEURONS{1'b0}};
            latched_index       <= {NEURON_IDX_W{1'b0}};
            i_pe_done_req_s1    <= {OUT_NEURONS{1'b0}};
            i_pe_done_req_sync  <= {OUT_NEURONS{1'b0}};
        end else begin
            state <= next_state;
            
            i_pe_done_req_s1 <= i_pe_done_req_vec;
            i_pe_done_req_sync <= i_pe_done_req_s1;
            
            case (state)
                S_IDLE: begin
                    if (next_state == S_CHECK_PENDING) begin
                        n_done_cnt      <= 0;
                        watchdog_cnt    <= 0;
                        pe_ack_done_reg <= {OUT_NEURONS{1'b0}};
                        latched_index   <= {NEURON_IDX_W{1'b0}};
                    end
                end
                
                S_CHECK_PENDING: begin
                    if (next_state == S_ACK_HIGH) begin
                        latched_index <= pe_index_to_ack;
                        watchdog_cnt  <= 0;
                    end 
                    else if (next_state == S_CHECK_PENDING)
                        watchdog_cnt <= watchdog_cnt + 1;
                end
                
                S_ACK_HIGH: begin
                    n_done_cnt <= n_done_cnt + 1;
                    pe_ack_done_reg[latched_index] <= 1'b1;
                end
            endcase
        end
    end
    
    assign o_busy = (state != S_IDLE);

endmodule
