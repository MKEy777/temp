`timescale 1ns / 1ps

/*
 * 模块: ArgMax_Unit
 * 功能: 找出 N 个电位中的最大值索引。
 * 修正:
 * 1. VEC_LEN = 3 (来自 train.py)
 * 2. DATA_W = 32 (匹配 PE_GALS_Wrapper 的 32-bit 累加器)
 */
module ArgMax_Unit #(
    parameter VEC_LEN = 3,  // 类别数 (来自 train.py)
    parameter DATA_W  = 32  // 关键: 32-bit (匹配 PE 累加器) 
) (
    input wire                        clk,
    input wire                        rst_n,
    input wire                        i_valid, // 来自 SNN_Engine
    input wire signed [VEC_LEN*DATA_W-1:0] i_potentials_flat,

    output reg                        o_valid,
    output reg [$clog2(VEC_LEN)-1:0]  o_predicted_class
);

    // 内部寄存器，用于保存当前最大值及其索引 (组合逻辑)
    reg signed [DATA_W-1:0]     max_val;
    reg [$clog2(VEC_LEN)-1:0] max_idx;
    
    integer i;
    wire signed [DATA_W-1:0] potentials [0:VEC_LEN-1];

    // 解包输入电位
    genvar j;
    generate
        for (j = 0; j < VEC_LEN; j = j + 1) begin : unpack_potentials
            assign potentials[j] = i_potentials_flat[(j+1)*DATA_W-1 -: DATA_W];
        end
    endgenerate

    // 组合逻辑: 寻找最大值
    always @(*) begin
        max_val = potentials[0];
        max_idx = 0;
        
        for (i = 1; i < VEC_LEN; i = i + 1) begin
            if (potentials[i] > max_val) begin
                max_val = potentials[i];
                max_idx = i;
            end
        end
    end

    // 时序逻辑: 寄存结果
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_valid <= 1'b0;
            o_predicted_class <= 0;
        end else begin
            o_valid <= i_valid;
            if (i_valid) begin
                o_predicted_class <= max_idx;
            end
        end
    end

endmodule