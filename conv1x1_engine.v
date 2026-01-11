`timescale 1ns/1ps
module conv1x1_engine #(
    parameter DATA_WIDTH = 8,   
    parameter WGT_WIDTH  = 8,
    parameter BIAS_WIDTH = 16,
    parameter OUT_WIDTH  = 18
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire [DATA_WIDTH-1:0]    din, 
    input  wire                     din_valid,
    output wire                     din_ready,
    
    output wire [OUT_WIDTH-1:0]     dout,
    output wire                     dout_valid,
    input  wire                     dout_ready,
    
    // 配置
    input  wire [WGT_WIDTH-1:0]     weight_config,
    input  wire [BIAS_WIDTH-1:0]    bias_config,
    input  wire                     config_en
);

    // 1. 锁存权重和偏置
    reg signed [WGT_WIDTH-1:0]  weight_reg;
    reg signed [BIAS_WIDTH-1:0] bias_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            weight_reg <= 0;
            bias_reg   <= 0;
        end else if (config_en) begin
            weight_reg <= $signed(weight_config);
            bias_reg   <= $signed(bias_config);
        end
    end

    // 2. 流水线控制
    wire pipeline_en;
    assign pipeline_en = dout_ready || !dout_valid;
    assign din_ready   = pipeline_en;

    // ------------------------------------------------------
    // Stage 1: 乘法 
    // ------------------------------------------------------
    reg signed [DATA_WIDTH+WGT_WIDTH:0] mult_reg;
    reg                                 valid_stage1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mult_reg     <= 0;
            valid_stage1 <= 0;
        end else if (pipeline_en) begin
            mult_reg     <= $signed({1'b0, din}) * weight_reg;
            valid_stage1 <= din_valid;
        end
    end

    // ------------------------------------------------------
    // Stage 2: 加偏置与输出
    // ------------------------------------------------------
    reg signed [OUT_WIDTH-1:0] out_reg; 
    reg                        out_valid_reg;
    
    wire signed [OUT_WIDTH-1:0] add_result;

    // 显式符号扩展并相加
    assign add_result = $signed(mult_reg) + $signed(bias_reg);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_reg       <= 0;
            out_valid_reg <= 0;
        end else if (pipeline_en) begin
            out_reg       <= add_result;
            out_valid_reg <= valid_stage1;
        end
    end

    assign dout       = out_reg;
    assign dout_valid = out_valid_reg;

endmodule