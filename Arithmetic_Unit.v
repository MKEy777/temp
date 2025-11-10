`timescale 1ns / 1ps

/*
 * 模块: arithmetic_unit
 * 功能: 同步流水线乘法器 (Q1.7 * Q1.7 => Q1.7)
 * 行为: 1. (Stage 1) A * B
 * 2. (Stage 2) (A*B) >>> 7 (重定点) + 饱和
 * 用于: ULG_Coordinator (C2) 实现 (A*B)*C 融合
 */
module arithmetic_unit #(
    parameter DATA_W     = 8,   // int8 (Q1.7)
    parameter MULT_W     = 16,  // DATA_W * 2
    parameter SHIFT_BITS = 7    // Q2.14 -> Q1.7 (14-7=7)
) (
    input wire                      clk,
    input wire                      rst_n,
    input wire                      i_valid,
    input wire signed [DATA_W-1:0]  i_data_a,
    input wire signed [DATA_W-1:0]  i_data_b,
    
    output reg signed [DATA_W-1:0] o_data,
    output reg                      o_valid
);

    // int8 饱和范围
    localparam Q_MIN = -(2**(DATA_W-1));      // -128
    localparam Q_MAX = (2**(DATA_W-1)) - 1;  //  127

    // --- 流水线寄存器定义 ---

    // Pipeline Stage 1: 乘法结果
    reg p1_valid;
    reg signed [MULT_W-1:0] p1_mult_result; // 8b * 8b = 16b

    // Stage 2: 组合逻辑
    wire signed [MULT_W-1:0] shifted_result;
    
    // Q2.14 (16b) -> Qx.7 (16b)
    assign shifted_result = p1_mult_result >>> SHIFT_BITS;


    // --- 流水线逻辑 ---

    // Stage 1: 乘法
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p1_valid       <= 1'b0;
            p1_mult_result <= {MULT_W{1'b0}};
        end else begin
            p1_valid <= i_valid;
            if (i_valid) begin
                // 使用 DSP 资源执行有符号乘法
                p1_mult_result <= $signed(i_data_a) * $signed(i_data_b);
            end
        end
    end

    // Stage 2: 重定点(移位) 和 饱和
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_valid <= 1'b0;
            o_data  <= {DATA_W{1'b0}};
        end else begin
            o_valid <= p1_valid;
            
            if (p1_valid) begin
                // 1. 饱和检查 (Saturation)
                if (shifted_result < Q_MIN) begin
                    o_data <= Q_MIN;
                end else if (shifted_result > Q_MAX) begin
                    o_data <= Q_MAX;
                // 2. 赋值
                end else begin
                    // 截取低8位 (Qx.7 -> Q1.7)
                    o_data <= shifted_result[DATA_W-1:0];
                end
            end else begin
                o_data <= {DATA_W{1'b0}};
            end
        end
    end

endmodule