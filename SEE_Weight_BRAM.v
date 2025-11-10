`timescale 1ns / 1ps

/*
 * 模块: SEE_Weight_BRAM
 * 功能: 32-bit 宽双端口 BRAM (1R1W)。
 * 职责: 存储 SNN 权重，支持 32-bit 宽读取。
 */
module SEE_Weight_BRAM #(
    parameter DATA_W   = 32, 
    parameter ADDR_W   = 10, 
    parameter MEM_FILE = ""
)(
    input  wire                  clk,
    
    // 端口 A: 读端口 (-> SNN_Array_4PE)
    input  wire                  i_rd_en_a,
    input  wire [ADDR_W-1:0]     i_rd_addr_a,
    output reg signed [DATA_W-1:0] o_rd_data_a,

    // 端口 B: 写端口 (用于加载权重)
    input  wire                  i_wr_en_b,
    input  wire [ADDR_W-1:0]     i_wr_addr_b,
    input  wire signed [DATA_W-1:0] i_wr_data_b
);

    localparam MEM_DEPTH = 1 << ADDR_W;
    
    (* ram_style = "block" *) 
    reg [DATA_W-1:0] mem [0:MEM_DEPTH-1];

    initial begin
        if (MEM_FILE != "") begin
            $readmemh(MEM_FILE, mem);
        end
    end

    // 端口 A: 读逻辑 (时序)
    always @(posedge clk) begin
        if (i_rd_en_a) begin
            o_rd_data_a <= mem[i_rd_addr_a];
        end
    end

    // 端口 B: 写逻辑 (时序)
    always @(posedge clk) begin
        if (i_wr_en_b) begin
            mem[i_wr_addr_b] <= i_wr_data_b;
        end
    end

endmodule