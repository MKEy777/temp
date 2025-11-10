`timescale 1ns / 1ps

/*
 * 模块: PE_GALS_Wrapper [重构版]
 * 功能: GALS FSM, 实现 SNN 的电位累加。
 * 重构: 移除了 o_bram_addr，添加了 i_clk_en (时钟使能)。
 */
module PE_GALS_Wrapper #(
    // Q1.7 协同设计参数
    parameter TIME_W   = 8,
    parameter WEIGHT_W = 8,
    
    // 架构参数
    parameter ADDR_W   = 10, // BRAM 地址位宽
    parameter ACC_W    = 32  // 32-bit 累加器 (防溢出)
)(
    input  wire                 local_clk,
    input  wire                 rst_n,
    input  wire                 i_clk_en, // ** 新增: 时钟使能 **

    // GALS 事件总线 (异步唤醒)
    input  wire                 i_aer_req,
    input  wire signed [TIME_W-1:0] i_aer_time, // 8-bit (t_i)
    input  wire [ADDR_W-1:0]        i_aer_addr,
    
    // SNN FSM 控制参数
    input  wire signed [TIME_W-1:0] i_t_min,    // 8-bit (t_min)
    input  wire                 i_reset_potential,

    // GALS 完成握手 (-> Collector)
    output reg                  o_done_req,
    input  wire                 i_done_ack,

    // 专属 BRAM 接口
    output reg                  o_bram_en,
    // [已移除] o_bram_addr 端口
    input  wire signed [WEIGHT_W-1:0] i_bram_data, // 8-bit (W_ij)

    // 电位输出 (-> SNN_Engine)
    output wire signed [ACC_W-1:0]  o_potential_j // 32-bit (V_j)
);

    // GALS FSM 状态定义
    localparam S_IDLE       = 4'b0000;
    localparam S_LATCH_AER  = 4'b0001; // C1: 锁存, 提交BRAM En
    localparam S_READ_BRAM  = 4'b0010; // C2: 读BRAM, 计算 (t_i - t_min)
    localparam S_COMPUTE    = 4'b0011; // C3: BRAM数据有效, 计算 (t_diff * W_ij)
    localparam S_ACCUMULATE = 4'b0100; // C4: 累加, 发送 o_done_req
    localparam S_WAIT_ACK   = 4'b0101; // C5: 等待 Collector 确认

    reg [3:0] state, next_state;

    // 内部数据路径寄存器
    reg signed [ACC_W-1:0]   V_j_reg;
    reg signed [TIME_W-1:0]  latched_aer_time;
    // [已移除] latched_aer_addr
    
    // 流水线阶段寄存器
    reg signed [TIME_W:0]    p2_time_diff;   // (t_i - t_min) -> 9b
    reg signed [ACC_W-1:0]   p3_mult_result; // (t_diff * W_ij) -> 17b (扩展)
    
    assign o_potential_j = V_j_reg;

    // 1. FSM 状态机 (组合逻辑)
    // (这部分不需要时钟使能，保持不变)
    always @(*) begin
        next_state  = state;
        o_done_req  = 1'b0;
        o_bram_en   = 1'b0;

        case (state)
            S_IDLE: begin
                if (i_aer_req)
                    next_state = S_LATCH_AER;
            end
            
            S_LATCH_AER: begin
                o_bram_en = 1'b1; // C1: 仅提交 BRAM 读使能
                next_state = S_READ_BRAM;
            end

            S_READ_BRAM: begin
                next_state = S_COMPUTE;
            end

            S_COMPUTE: begin
                next_state = S_ACCUMULATE;
            end
            
            S_ACCUMULATE: begin
                o_done_req = 1'b1;
                next_state = S_WAIT_ACK;
            end
            
            S_WAIT_ACK: begin
                o_done_req = 1'b1;
                if (i_done_ack)
                    next_state = S_IDLE;
            end

            default: begin
                next_state = S_IDLE;
            end
        endcase
    end

    // 2. FSM 与数据路径 (时序逻辑)
    // ** 关键: 整个时序逻辑块现在由 i_clk_en 控制 **
    always @(posedge local_clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= S_IDLE;
            V_j_reg          <= {ACC_W{1'b0}};
            latched_aer_time <= {TIME_W{1'b0}};
            p2_time_diff     <= 0;
            p3_mult_result   <= 0;
        end 
        // ** 只有在 rst_n 无效且 i_clk_en 有效时，才执行时钟逻辑 **
        else if (i_clk_en) begin 
            
            state <= next_state;
            
            if (i_reset_potential) begin
                V_j_reg <= {ACC_W{1'b0}};
            end

            // 数据路径流水线
            case (state)
                S_LATCH_AER: begin 
                    // C1: 锁存时间 (不再需要锁存地址)
                    latched_aer_time <= i_aer_time;
                end

                S_READ_BRAM: begin 
                    // C2: 计算 (t_i - t_min)
                    p2_time_diff <= $signed(latched_aer_time) - $signed(i_t_min);
                end
                
                S_COMPUTE: begin 
                    // C3: 计算 (t_diff * W_ij)
                    p3_mult_result <= $signed(p2_time_diff) * $signed(i_bram_data);
                end
                
                S_ACCUMULATE: begin 
                    // C4: 累加 (V_j_reg += product)
                    if (!i_reset_potential)
                        V_j_reg <= V_j_reg + p3_mult_result;
                end
            endcase
        end
    end

endmodule