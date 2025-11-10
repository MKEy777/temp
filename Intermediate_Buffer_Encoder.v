`timescale 1ns / 1ps

/*
 * 模块: Intermediate_Buffer_Encoder
 * 功能: SNN 层间编码器 (V_j -> t_k)。
 * 职责:
 * 1. 缓存 32-bit 电位。
 * 2. 将电位 (V_j) 缩放并转换为 8-bit 时间 (t_k)。
 * 3. 作为 AER 广播者，将 t_k 广播给下一层。
 */
module Intermediate_Buffer_Encoder #(
    parameter MAX_NEURONS = 64,
    parameter POTENTIAL_W = 32,
    parameter TIME_W      = 8,   // 8-bit Q1.7
    parameter ADDR_W      = 6,   // $clog2(MAX_NEURONS)
    parameter THRESHOLD_W = 8,   // 8-bit D_i (阈值)
    parameter VJ_SHIFT_BITS = 16 // 32-bit 电位右移位数
)(
    input  wire                      local_clk,
    input  wire                      rst_n,
    input  wire                      i_clk_en, // 时钟使能

    // 1. 加载阶段 (写入电位)
    input  wire                      i_potential_wr_en,
    input  wire [ADDR_W-1:0]         i_potential_wr_addr,
    input  wire signed [POTENTIAL_W-1:0] i_potential_wr_data,
    
    // 2. 广播阶段
    input  wire                      i_broadcast_start,
    input  wire signed [TIME_W-1:0]  i_t_max_layer, // (即 t_min_next)
    input  wire [ADDR_W-1:0]         i_neuron_count,
    output reg                       o_broadcast_done,

    // AER 广播总线
    output reg                       o_aer_req,
    input  wire                      i_aer_ack,
    output reg signed [TIME_W-1:0]   o_aer_time,
    output reg [ADDR_W-1:0]          o_aer_addr,
    
    // 阈值 ROM 接口 (从外部读取 D_i)
    output reg [ADDR_W-1:0]          o_threshold_rom_addr,
    input  wire signed [THRESHOLD_W-1:0] i_threshold_data
);

    // 内部存储 (仅电位)
    (* ram_style = "block" *)
    reg signed [POTENTIAL_W-1:0] potential_ram [0:MAX_NEURONS-1];

    // FSM 状态
    localparam S_IDLE        = 4'b0000;
    localparam S_READ_DATA   = 4'b0001; // C1: 读 V_j 和 D_i
    localparam S_CALC_TIME   = 4'b0010; // C2: 计算 t_k
    localparam S_SEND_SPIKE  = 4'b0011; // C3: 发送 AER Req
    localparam S_WAIT_ACK    = 4'b0100; // C4: 等待 AER Ack
    localparam S_CLEAR_REQ   = 4'b0101; // C5: 拉低 AER Req
    localparam S_FINISHING   = 4'b0110;

    reg [3:0] state, next_state;

    // 内部寄存器
    reg [ADDR_W-1:0] neuron_cnt;
    reg signed [POTENTIAL_W-1:0] v_j_reg; // 32b
    reg signed [TIME_W-1:0]      t_k_reg; // 8b
    reg o_broadcast_done_pulse;

    wire signed [TIME_W:0]   scaled_vj; // 9b
    wire signed [TIME_W+1:0] t_k_calc;  // 10b

    assign scaled_vj = $signed(v_j_reg >>> VJ_SHIFT_BITS);
    assign t_k_calc  = scaled_vj + $signed(i_t_max_layer) 
                                 - $signed(i_threshold_data);

    // 1. 内部电位 RAM (SNN_Engine 写入)
    always @(posedge local_clk) begin
        if (i_clk_en) begin
            if (i_potential_wr_en) begin
                potential_ram[i_potential_wr_addr] <= i_potential_wr_data;
            end
        end
    end

    // 2. 广播 FSM (组合逻辑)
    always @(*) begin
        next_state = state;
        o_broadcast_done = o_broadcast_done_pulse;
        
        case(state)
            S_IDLE: begin
                if (i_broadcast_start)
                    next_state = S_READ_DATA;
            end
            
            S_READ_DATA: begin
                next_state = S_CALC_TIME;
            end
            
            S_CALC_TIME: begin
                next_state = S_SEND_SPIKE;
            end

            S_SEND_SPIKE: begin
                if (t_k_reg < i_t_max_layer) // 过滤无效脉冲
                    next_state = S_WAIT_ACK;
                else
                    next_state = S_CLEAR_REQ; // 跳过无效脉冲
            end
            
            S_WAIT_ACK: begin
                if (i_aer_ack)
                    next_state = S_CLEAR_REQ;
            end

            S_CLEAR_REQ: begin
                if (neuron_cnt == i_neuron_count - 1)
                    next_state = S_FINISHING;
                else
                    next_state = S_READ_DATA;
            end

            S_FINISHING: begin
                next_state = S_IDLE;
            end
            
            default: next_state = S_IDLE;
        endcase
    end

    // 3. 广播 FSM (时序逻辑)
    always @(posedge local_clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            neuron_cnt <= 0;
            v_j_reg <= 0;
            t_k_reg <= 0;
            o_threshold_rom_addr <= 0;
            o_aer_time <= 0;
            o_aer_addr <= 0;
            o_aer_req  <= 1'b0;
            o_broadcast_done_pulse <= 1'b0;
        end else if (i_clk_en) begin
            state <= next_state;
            
            o_broadcast_done_pulse <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (i_broadcast_start)
                        neuron_cnt <= 0;
                end
                
                S_READ_DATA: begin
                    // C1: 读内部 V_j, 提交外部 D_i 地址
                    v_j_reg <= potential_ram[neuron_cnt];
                    o_threshold_rom_addr <= neuron_cnt;
                end
                
                S_CALC_TIME: begin
                    // C2: (i_threshold_data (D_i) 在此周期有效)
                    if (t_k_calc > 127)
                        t_k_reg <= 127;
                    else if (t_k_calc < -128)
                        t_k_reg <= -128;
                    else
                        t_k_reg <= t_k_calc[TIME_W-1:0];
                end

                S_SEND_SPIKE: begin
                    if (t_k_reg < i_t_max_layer) begin
                        o_aer_time <= t_k_reg;
                        o_aer_addr <= neuron_cnt;
                        o_aer_req  <= 1'b1;
                    end
                end
                
                S_WAIT_ACK: begin
                    o_aer_req  <= 1'b1;
                end
                
                S_CLEAR_REQ: begin
                    o_aer_req  <= 1'b0; // 拉低 req
                    neuron_cnt <= neuron_cnt + 1;
                end

                S_FINISHING: begin
                    o_broadcast_done_pulse <= 1'b1;
                    neuron_cnt <= 0;
                end
            endcase
        end
    end

endmodule