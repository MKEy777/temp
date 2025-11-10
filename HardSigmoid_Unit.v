`timescale 1ns / 1ps

module hardsigmoid_unit #(
    parameter DATA_W = 8
) (
    input wire                      clk,
    input wire                      rst_n,
    input wire                      i_valid,
    input wire signed [DATA_W-1:0]  i_data,
    
    output reg signed [DATA_W-1:0] o_data,
    output reg                      o_valid
);

    // Q1.7 格式 (1符号, 7小数) 的常量
    localparam Q_FORMAT_FRAC_BITS = DATA_W - 1;
    
    // 0.5 in Q1.7 format = 0.5 * 2^7 = 64
    localparam Q_CONST_0_5 = (1 << (Q_FORMAT_FRAC_BITS - 1)); 
    
    // 0.0 in Q1.7 format = 0
    localparam Q_MIN = {DATA_W{1'b0}};
    
    // 1.0 (approx) in Q1.7 format = 127
    localparam Q_MAX = (1 << (Q_FORMAT_FRAC_BITS)) - 1;


    // --- 流水线 ---
    reg signed [DATA_W-1:0] d1_data;
    reg                     d1_valid;

    reg signed [DATA_W+1:0] shifted_data; // 暂存移位结果
    reg signed [DATA_W+1:0] added_data;   // 暂存加法结果 (扩展1位防止溢出)
    
    // -- Stage 1: 寄存器输入 --
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d1_data  <= {DATA_W{1'b0}};
            d1_valid <= 1'b0;
        end else begin
            d1_data  <= i_data;
            d1_valid <= i_valid;
        end
    end

    // -- Stage 2: 逻辑实现 (x >> 3) + 0.5, clamp(0, 1) --
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_data  <= {DATA_W{1'b0}};
            o_valid <= 1'b0;
        end else begin
            o_valid <= d1_valid;
            
            if (d1_valid) begin
                // 1. 实现 x * 0.125, 即 (x >>> 3)
                // 使用算术右移 (>>>) 来保持符号
                shifted_data = $signed(d1_data) >>> 3;
                
                // 2. 实现 + 0.5
                // 加上 Q1.7 格式的 0.5
                added_data = shifted_data + Q_CONST_0_5;
                
                // 3. 实现 clamp(..., 0.0, 1.0)
                if (added_data < Q_MIN) begin
                    o_data <= Q_MIN;
                end else if (added_data > Q_MAX) begin
                    o_data <= Q_MAX;
                end else begin
                    o_data <= added_data[DATA_W-1:0];
                end
                
            end else begin
                o_data <= {DATA_W{1'b0}};
            end
        end
    end

endmodule