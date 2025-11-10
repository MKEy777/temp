`timescale 1ns / 1ps

/*
 * 模块: PE_GALS_Wrapper (SNN 处理单元)
 * 功能: GALS FSM，实现SNN的O(1)事件处理。
 * 行为:
 * 1. 异步唤醒 (i_aer_req)
 * 2. 锁存AER总线 (i_aer_addr, i_aer_time)
 * 3. 同步读 BRAM (o_bram_addr <- i_aer_addr)
 * 4. 同步计算 (V_j_reg <= V_j_reg + (i_aer_time * W[i,j]))
 * 5. 异步握手 (o_done_req -> i_done_ack)
 */
module PE_GALS_Wrapper #(
    parameter TIME_W   = 32, // 脉冲时间位宽 (来自 GALS_Encoder)
    parameter WEIGHT_W = 8,  // 权重位宽 (int8)
    parameter ADDR_W   = 9,  // BRAM 地址位宽 (e.g., clog2(320))
    parameter ACC_W    = 48  // 累加器位宽 (匹配 ArgMax_Unit)
)(
    input  wire                      local_clk,
    input  wire                      rst_n,

    // --- 全局异步事件总线 (来自 Encoder) ---
    input  wire                      i_aer_req,
    input  wire signed [TIME_W-1:0]  i_aer_time,
    input  wire [ADDR_W-1:0]         i_aer_addr,
    
    // --- PE完成握手 (-> Collector) ---
    output reg                       o_done_req,
    input  wire                      i_done_ack,

    // --- 专属 BRAM 接口 (-> SEE_Weight_BRAM_j) ---
    output reg                       o_bram_en,
    output reg [ADDR_W-1:0]          o_bram_addr,
    input  wire signed [WEIGHT_W-1:0] i_bram_data, // W[i, j]

    // --- 电位复位与输出 (-> SNN_Engine / ArgMax_Unit) ---
    input  wire                      i_reset_potential, // 由SNN_Engine控制
    output wire signed [ACC_W-1:0]   o_potential_j
);

    // --- FSM 状态定义 ---
    localparam S_IDLE       = 3'b000;
    localparam S_LATCH_AER  = 3'b001;
    localparam S_READ_BRAM  = 3'b010;
    localparam S_COMPUTE    = 3'b011;
    localparam S_SEND_DONE  = 3'b100;
    localparam S_WAIT_ACK   = 3'b101;

    reg [2:0] state, next_state;

    // --- 内部寄存器 ---
    reg signed [ACC_W-1:0]   V_j_reg;
    reg signed [TIME_W-1:0]  latched_aer_time;
    reg [ADDR_W-1:0]         latched_aer_addr;
    reg signed [ACC_W-1:0]   mult_result;
    
    assign o_potential_j = V_j_reg;

    // --- 状态机 (组合逻辑) ---
    always @(*) begin
        next_state  = state;
        o_done_req  = 1'b0;
        o_bram_en   = 1'b0;
        o_bram_addr = latched_aer_addr;
        
        case (state)
            S_IDLE: begin
                if (i_aer_req) begin
                    next_state = S_LATCH_AER;
                end
            end
            
            S_LATCH_AER: begin
                // 锁存总线数据
                next_state = S_READ_BRAM;
            end

            S_READ_BRAM: begin
                // 发起 BRAM 读
                o_bram_en = 1'b1;
                next_state = S_COMPUTE;
            end

            S_COMPUTE: begin
                // BRAM 数据 (W[i,j]) 在此时钟周期有效
                // 计算贡献并累加
                next_state = S_SEND_DONE;
            end
            
            S_SEND_DONE: begin
                o_done_req = 1'b1;
                next_state = S_WAIT_ACK;
            end
            
            S_WAIT_ACK: begin
                o_done_req = 1'b1;
                if (i_done_ack) begin
                    next_state = S_IDLE;
                end
            end

            default: begin
                next_state = S_IDLE;
            end
        endcase
    end

    // --- 状态机与数据路径 (时序逻辑) ---
    always @(posedge local_clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= S_IDLE;
            V_j_reg          <= {ACC_W{1'b0}};
            latched_aer_time <= {TIME_W{1'b0}};
            latched_aer_addr <= {ADDR_W{1'b0}};
            mult_result      <= {ACC_W{1'b0}};
        end else begin
            state <= next_state;

            if (i_reset_potential) begin
                V_j_reg <= {ACC_W{1'b0}};
            end

            case (state)
                S_LATCH_AER: begin
                    latched_aer_time <= i_aer_time;
                    latched_aer_addr <= i_aer_addr;
                end

                S_COMPUTE: begin
                    // 执行: t_i * W[i, j]
                    mult_result <= $signed(latched_aer_time) * $signed(i_bram_data);
                end
                
                S_SEND_DONE: begin
                    if (!i_reset_potential) begin // 避免复位时误加
                        V_j_reg <= V_j_reg + mult_result;
                    end
                end
            endcase
        end
    end

endmodule