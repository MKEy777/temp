`timescale 1ns / 1ps

module GALS_Encoder_Unit #(
    parameter VEC_LEN       = 320,      
    parameter PIXEL_VEC_LEN = 16,       
    parameter NUM_PIXELS    = 20,      
    parameter DATA_W        = 8,        
    parameter TIME_W        = 32,   
    parameter signed [TIME_W-1:0] T_MAX       = 32'h7FFFFFFF,
    parameter signed [TIME_W-1:0] TIME_OFFSET = 32'h0000_0001,
    parameter signed [15:0] TIME_SCALE_MULT   = 16'h0160,
    parameter SHIFT_BITS    = 15
)(
    input  wire                      local_clk,
    input  wire                      rst_n,

    input  wire                      i_data_req,
    output reg                       o_data_ack,
    input  wire signed [PIXEL_VEC_LEN*DATA_W-1:0] i_data_bus,

    output reg                       o_aer_req,
    input  wire                      i_aer_ack,
    output reg signed [TIME_W-1:0]   o_aer_time,
    output reg [$clog2(VEC_LEN)-1:0] o_aer_addr,
    
    output wire                      o_busy,
    output wire                      o_last_pixel_sent 
);
    localparam S_IDLE       = 3'b000;
    localparam S_CALC_LOAD  = 3'b001; 
    localparam S_SEND_SPIKE = 3'b010; 
    localparam S_FINISHING  = 3'b011;
    reg [2:0] state, next_state;

    reg [$clog2(NUM_PIXELS)-1:0] pixel_receive_cnt; 
    reg [$clog2(PIXEL_VEC_LEN)-1:0] channel_send_cnt;
    reg signed [TIME_W-1:0] current_pixel_spikes [0:PIXEL_VEC_LEN-1];
    
    wire signed [TIME_W-1:0] calculated_spikes [0:PIXEL_VEC_LEN-1];
    genvar i;
    generate
        for (i = 0; i < PIXEL_VEC_LEN; i = i + 1) begin : PIXEL_ENCODE_LOGIC
            wire signed [DATA_W-1:0] x_q;
            wire signed [23:0]       product; 
            wire signed [TIME_W-1:0] scaled_val;
            assign x_q        = i_data_bus[(i+1)*DATA_W-1 -: DATA_W]; 
            assign product    = TIME_SCALE_MULT * x_q;
            assign scaled_val = product >>> SHIFT_BITS;
            assign calculated_spikes[i] = TIME_OFFSET - scaled_val;
        end
    endgenerate

    always @(*) begin
        next_state = state;
        o_aer_req  = 1'b0;
        o_aer_time = {TIME_W{1'bx}};
        o_aer_addr = {$clog2(VEC_LEN){1'bx}};
        o_data_ack = 1'b0;

        case (state)
            S_IDLE: begin
                if (i_data_req) begin
                    o_data_ack = 1'b1;
                    next_state = S_CALC_LOAD;
                end
            end
            
            S_CALC_LOAD: begin
                o_data_ack = 1'b1; 
                if (!i_data_req)
                    next_state = S_SEND_SPIKE;
            end

            S_SEND_SPIKE: begin
                if (current_pixel_spikes[channel_send_cnt] < T_MAX) begin
                    o_aer_req  = 1'b1; 
                    o_aer_time = current_pixel_spikes[channel_send_cnt];
                    o_aer_addr = pixel_receive_cnt * PIXEL_VEC_LEN + channel_send_cnt;
                    
                    if (i_aer_ack) begin 
                        if (channel_send_cnt == PIXEL_VEC_LEN - 1)
                            next_state = (pixel_receive_cnt == NUM_PIXELS - 1) ? S_FINISHING : S_IDLE;
                        else
                            next_state = S_SEND_SPIKE;
                    end else
                        next_state = S_SEND_SPIKE;
                end else begin
                    if (channel_send_cnt == PIXEL_VEC_LEN - 1)
                        next_state = (pixel_receive_cnt == NUM_PIXELS - 1) ? S_FINISHING : S_IDLE;
                    else
                        next_state = S_SEND_SPIKE;
                end
            end

            S_FINISHING: next_state = S_IDLE;
            default:     next_state = S_IDLE;
        endcase
    end
    
    integer ch;
    always @(posedge local_clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            pixel_receive_cnt <= 0;
            channel_send_cnt <= 0;
            for (ch = 0; ch < PIXEL_VEC_LEN; ch = ch + 1)
                current_pixel_spikes[ch] <= 0;
        end else begin
            state <= next_state; 
            case (state)
                S_IDLE: begin
                    if (next_state == S_CALC_LOAD) begin
                        if (pixel_receive_cnt == NUM_PIXELS - 1)
                            pixel_receive_cnt <= 0;
                        else
                            pixel_receive_cnt <= pixel_receive_cnt + 1;
                    end
                end

                S_CALC_LOAD: begin
                    if (next_state == S_SEND_SPIKE) begin
                        for (ch = 0; ch < PIXEL_VEC_LEN; ch = ch + 1)
                            current_pixel_spikes[ch] <= calculated_spikes[ch];
                        channel_send_cnt <= 0;
                    end
                end
                
                S_SEND_SPIKE: begin
                    if (current_pixel_spikes[channel_send_cnt] >= T_MAX || (o_aer_req && i_aer_ack)) begin
                        if (channel_send_cnt != PIXEL_VEC_LEN - 1)
                            channel_send_cnt <= channel_send_cnt + 1;
                    end
                end
                
                S_FINISHING: begin
                    pixel_receive_cnt <= 0;
                    channel_send_cnt  <= 0;
                end
            endcase
        end
    end
    
    assign o_busy = (state != S_IDLE);
    assign o_last_pixel_sent = (o_aer_req && i_aer_ack) && 
                               (channel_send_cnt == PIXEL_VEC_LEN - 1) && 
                               (pixel_receive_cnt == 0);

endmodule
