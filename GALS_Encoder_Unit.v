`timescale 1ns / 1ps

/*
 * 模块: GALS_Encoder_Unit
 * 功能: GALS 桥接器。将 ANN 激活值 (Q1.7) 转换为 SNN 脉冲时间 (Q1.7)。
 * 算法: t_i = T_MAX - ((x - K_MIN) >> K_SHIFT)
 */
module GALS_Encoder_Unit #(
    // 架构参数
    parameter VEC_LEN       = 160, // SNN 输入维度 (8x4x5)
    parameter PIXEL_VEC_LEN = 8,   // ANN 融合 FSM 每次发送的通道数
    parameter NUM_PIXELS    = 20,  // VEC_LEN / PIXEL_VEC_LEN
    parameter DATA_W        = 8,   // Q1.7 激活值 (来自 ANN)
    parameter TIME_W        = 8,   // Q1.7 脉冲时间 (发往 SNN)
    
    // Q1.7 编码常量 (来自软件训练)
    parameter signed [DATA_W-1:0] T_MAX_Q17 = 127,
    parameter signed [DATA_W-1:0] K_MIN_Q17 = -128,
    parameter SHIFT_BITS    = 2    // 示例值
)(
    input  wire                      local_clk,
    input  wire                      rst_n,

    // GALS 握手 (来自 ULG_Coordinator)
    input  wire                      i_data_req,
    output reg                       o_data_ack,
    input  wire signed [PIXEL_VEC_LEN*DATA_W-1:0] i_data_bus, 

    // AER 广播总线 (-> SNN_Engine)
    output reg                       o_aer_req,
    input  wire                      i_aer_ack,
    output reg signed [TIME_W-1:0]   o_aer_time,
    output reg [$clog2(VEC_LEN)-1:0] o_aer_addr,
    
    output wire                      o_busy,
    output wire                      o_encoder_done
);

    // FSM 状态
    localparam S_IDLE       = 3'b000;
    localparam S_CALC_LOAD  = 3'b001; 
    localparam S_SEND_SPIKE = 3'b010;
    localparam S_FINISHING  = 3'b011;
    reg [2:0] state, next_state;

    // 计数器
    reg [$clog2(NUM_PIXELS)-1:0]    pixel_receive_cnt; // 0-19
    reg [$clog2(PIXEL_VEC_LEN)-1:0] channel_send_cnt;  // 0-7
    
    // 内部寄存器
    reg signed [TIME_W-1:0] current_pixel_spikes [0:PIXEL_VEC_LEN-1];
    wire signed [TIME_W-1:0] calculated_spikes [0:PIXEL_VEC_LEN-1];

    // Q1.7 编码算法 (组合逻辑)
    genvar i;
    generate
        for (i = 0; i < PIXEL_VEC_LEN; i = i + 1) begin : PIXEL_ENCODE_LOGIC
            wire signed [DATA_W-1:0] x_q;
            wire signed [DATA_W:0]   x_sub;     // (x - K_MIN) -> 9b
            wire signed [DATA_W:0]   x_shift;   // (x_sub >> K_SHIFT)
            wire signed [DATA_W-1:0] x_clamped; // clamp(x_shift, 0, 127)
            
            assign x_q = i_data_bus[(i+1)*DATA_W-1 -: DATA_W];
            
            // 算法 1: (x - K_MIN_Q17)
            assign x_sub = $signed(x_q) - $signed(K_MIN_Q17);
            
            // 算法 2: (x_sub >>> K_SHIFT) (算术右移)
            assign x_shift = x_sub >>> SHIFT_BITS;
            
            // 算法 3: clamp(..., 0, T_MAX_Q17)
            assign x_clamped = (x_shift < 0) ? 0 : 
                               (x_shift > T_MAX_Q17) ? T_MAX_Q17 : 
                               x_shift[DATA_W-1:0];
                               
            // 算法 4: t_i = T_MAX - clamped_norm_x
            assign calculated_spikes[i] = T_MAX_Q17 - x_clamped;
        end
    endgenerate

    // 1. FSM (组合逻辑)
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
                // 检查脉冲是否有效 (过滤无效脉冲)
                if (current_pixel_spikes[channel_send_cnt] < T_MAX_Q17) begin
                    o_aer_req  = 1'b1;
                    o_aer_time = current_pixel_spikes[channel_send_cnt];
                    o_aer_addr = (pixel_receive_cnt * PIXEL_VEC_LEN) + channel_send_cnt;
                    
                    if (i_aer_ack) begin // 握手成功, 准备下一个
                        if (channel_send_cnt == PIXEL_VEC_LEN - 1)
                            next_state = (pixel_receive_cnt == NUM_PIXELS - 1) ?
                                         S_FINISHING : S_IDLE;
                        else
                            next_state = S_SEND_SPIKE;
                    end else
                        next_state = S_SEND_SPIKE; // 保持 req, 等待 ack
                end else begin
                    // 跳过无效脉冲 (>= T_MAX_Q17)
                    if (channel_send_cnt == PIXEL_VEC_LEN - 1)
                        next_state = (pixel_receive_cnt == NUM_PIXELS - 1) ?
                                     S_FINISHING : S_IDLE;
                    else
                        next_state = S_SEND_SPIKE;
                end
            end

            S_FINISHING: next_state = S_IDLE;
            default:     next_state = S_IDLE;
        endcase
    end
    
    // 2. FSM (时序逻辑)
    integer ch;
    always @(posedge local_clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            pixel_receive_cnt <= 0;
            channel_send_cnt <= 0;
            for (ch = 0; ch < PIXEL_VEC_LEN; ch = ch + 1)
                current_pixel_spikes[ch] <= T_MAX_Q17; // 复位为 "无效"
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
                    // 仅当 (脉冲被跳过) 或 (脉冲发送成功) 时，才递增计数器
                    if (current_pixel_spikes[channel_send_cnt] >= T_MAX_Q17 || (o_aer_req && i_aer_ack)) begin
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
    assign o_encoder_done = (state == S_FINISHING); 

endmodule