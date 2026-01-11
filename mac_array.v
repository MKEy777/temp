`timescale 1ns/1ps
module mac_array #(
    parameter DATA_WIDTH = 8,
    parameter WGT_WIDTH  = 8,
    parameter OUT_WIDTH  = 20,
    parameter INPUT_IS_SIGNED = 0 // [新增] 0:无符号(图像), 1:有符号(中间层)
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    valid_in,
    input  wire [DATA_WIDTH*9-1:0] window_data,
    input  wire [WGT_WIDTH*9-1:0]  weights,
    output wire [OUT_WIDTH-1:0]    mac_out,
    output wire                    valid_out
);

    wire [DATA_WIDTH-1:0]   window_data_unpacked [8:0];
    wire [WGT_WIDTH-1:0]    weights_unpacked [8:0];
    
    // 寄存器位宽 +1 以容纳符号扩展
    reg  signed [DATA_WIDTH:0]   window_data_reg [8:0]; 
    reg  signed [WGT_WIDTH-1:0]  weights_reg [8:0];
    reg                          valid_in_reg;
    
    // 乘积位宽
    wire signed [DATA_WIDTH+WGT_WIDTH:0] products [8:0];

    // 解包
    genvar g;
    generate
        for (g = 0; g < 9; g = g + 1) begin : unpack
            assign window_data_unpacked[g] = window_data[g*DATA_WIDTH +: DATA_WIDTH];
            assign weights_unpacked[g]     = weights[g*WGT_WIDTH +: WGT_WIDTH];
        end
    endgenerate

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 9; i = i + 1) begin
                window_data_reg[i] <= 0;
                weights_reg[i]     <= 0;
            end
            valid_in_reg <= 0;
        end else begin
            for (i = 0; i < 9; i = i + 1) begin
                // [核心修改逻辑]
                if (INPUT_IS_SIGNED) begin
                    // 符号扩展: 复制最高位
                    window_data_reg[i] <= {window_data_unpacked[i][DATA_WIDTH-1], window_data_unpacked[i]};
                end else begin
                    // 零扩展: 补0 (适用于原始图像)
                    window_data_reg[i] <= {1'b0, window_data_unpacked[i]};
                end
                
                weights_reg[i] <= weights_unpacked[i];
            end
            valid_in_reg <= valid_in;
        end
    end

    // 后续乘加逻辑保持不变
    genvar k;
    generate
        for (k = 0; k < 9; k = k + 1) begin : gen_mult
            (* use_dsp = "yes" *)
            assign products[k] = $signed(window_data_reg[k]) * $signed(weights_reg[k]);
        end
    endgenerate

    // 加法树 (Stage 1)
    wire signed [OUT_WIDTH-1:0] sum_stage1 [3:0];
    assign sum_stage1[0] = products[0] + products[1];
    assign sum_stage1[1] = products[2] + products[3];
    assign sum_stage1[2] = products[4] + products[5];
    assign sum_stage1[3] = products[6] + products[7];

    // 加法树 (Stage 2)
    wire signed [OUT_WIDTH-1:0] sum_stage2 [1:0];
    assign sum_stage2[0] = sum_stage1[0] + sum_stage1[1];
    assign sum_stage2[1] = sum_stage1[2] + sum_stage1[3];

    // 输出级
    reg [OUT_WIDTH-1:0] final_sum_reg;
    reg                 valid_out_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            final_sum_reg <= 0;
            valid_out_reg <= 0;
        end else begin
            final_sum_reg <= (sum_stage2[0] + sum_stage2[1]) + products[8];
            valid_out_reg <= valid_in_reg;
        end
    end

    assign mac_out   = final_sum_reg;
    assign valid_out = valid_out_reg;

endmodule