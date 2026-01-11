`timescale 1ns/1ps
`default_nettype wire

// MAC偏置处理单元模块
// 功能：完成偏置加法并输出最终结果
module mac_bias_unit #(
    parameter DATA_WIDTH = 16,    // MAC输出数据位宽
    parameter BIAS_WIDTH = 16,    // 偏置位宽
    parameter OUT_WIDTH = 18      // 输出位宽（考虑加法溢出）
)(
    input  wire                    clk,           // 时钟
    input  wire                    rst_n,         // 复位，低有效
    input  wire                    valid_in,      // 输入有效信号
    input  wire [DATA_WIDTH-1:0]   mac_data,      // MAC输出数据
    input  wire [BIAS_WIDTH-1:0]   bias_data,     // 偏置数据
    output wire [OUT_WIDTH-1:0]    result_data,   // 最终结果
    output wire                    valid_out      // 输出有效信号
);

// 内部信号定义
wire signed [OUT_WIDTH-1:0] bias_add_result;

// 偏置加法
// 使用 $signed() 显式告知综合器进行有符号加法
assign bias_add_result = $signed(mac_data) + $signed(bias_data);

// 流水线寄存器信号
reg [OUT_WIDTH-1:0] result_data_reg;
reg                 valid_out_reg;

// 主时序逻辑 - 单级流水线
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        result_data_reg <= 0;
        valid_out_reg <= 0;
    end else begin
        result_data_reg <= bias_add_result;
        valid_out_reg <= valid_in;
    end
end

// 输出连接
assign result_data = result_data_reg;
assign valid_out = valid_out_reg;

endmodule