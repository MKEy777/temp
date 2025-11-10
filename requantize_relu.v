`timescale 1ns / 1ps

/*
 * 模块: requantize_relu_q17_2stage
 * 功能: 优化的2级流水线版本 (Add -> Shift/ReLU/Sat)
 */
module requantize_relu #(
    parameter IN_W       = 32,
    parameter BIAS_W     = 32,
    parameter OUT_W      = 8,
    parameter SHIFT_BITS = 14
) (
    input clk,
    input rst_n,
    input i_valid,
    input signed [IN_W-1:0]   i_acc,
    input signed [BIAS_W-1:0] i_bias,
    
    output reg signed [OUT_W-1:0] o_data,
    output reg o_valid
);
    localparam Q_MAX      = (2**(OUT_W-1)) - 1;
    localparam Q_MIN_RELU = {OUT_W{1'b0}};

    // --- 流水线寄存器定义 ---

    // Pipeline Stage 1: 偏置加法结果
    reg p1_valid;
    reg signed [IN_W:0] p1_acc_biased; // 扩展1位以防加法溢出

    // Stage 2: 组合逻辑
    wire signed [IN_W:0] shifted_acc;
    wire signed [IN_W:0] final_val;

    assign shifted_acc = p1_acc_biased >>> SHIFT_BITS;
    assign final_val   = shifted_acc;

    // --- 流水线逻辑 ---

    // Stage 1: 锁存输入并立即执行加法
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p1_valid <= 1'b0;
            p1_acc_biased <= {(IN_W+1){1'b0}};
        end else begin
            p1_valid <= i_valid;
            if (i_valid) begin
                // 加法在第一级的组合逻辑中完成
                p1_acc_biased <= $signed(i_acc) + $signed(i_bias);
            end
        end
    end

    // Stage 2: 移位, ReLU, 饱和, 和输出
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_valid <= 1'b0;
            o_data  <= {OUT_W{1'b0}};
        end else begin
            o_valid <= p1_valid;
            if (p1_valid) begin
                // 1. ReLU: 小于0的值钳位到0
                if (final_val < Q_MIN_RELU) begin
                    o_data <= Q_MIN_RELU; 
                // 2. 饱和: 大于Q1.7最大值(127)的值钳位到127
                end else if (final_val > Q_MAX) begin
                    o_data <= Q_MAX; 
                // 3. 有效值
                end else begin
                    o_data <= final_val[OUT_W-1:0];
                end
            end else begin
                o_data <= {OUT_W{1'b0}};
            end
        end
    end

endmodule