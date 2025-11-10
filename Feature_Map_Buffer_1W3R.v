`timescale 1ns / 1ps

/*
 * 模块: Feature_Map_Buffer_1W3R
 * 功能: 1写3读 (1W3R) 同步RAM。
 * 实现: 通过数据复制 (Replication) 实现。
 * C1 FSM 向所有3个内部RAM写入，P1/P2/P3 各自读取1个。
 */
module Feature_Map_Buffer_1W3R #(
    parameter DATA_WIDTH = 8,
    parameter ADDR_WIDTH = 10,
    parameter RAM_DEPTH  = 1 << ADDR_WIDTH
)(
    input  wire                      clk,

    // --- 端口 A: 写端口 (来自 C1 FSM) ---
    input  wire                      i_wr_en,
    input  wire [ADDR_WIDTH-1:0]     i_wr_addr,
    input  wire signed [DATA_WIDTH-1:0]  i_wr_data,

    // --- 端口 A: 读端口 (来自 P1: Main Path) ---
    input  wire                      i_rd_en_a,
    input  wire [ADDR_WIDTH-1:0]     i_rd_addr_a,
    output reg signed [DATA_WIDTH-1:0]  o_rd_data_a,

    // --- 端口 B: 读端口 (来自 P2: Channel Gate) ---
    input  wire                      i_rd_en_b,
    input  wire [ADDR_WIDTH-1:0]     i_rd_addr_b,
    output reg signed [DATA_WIDTH-1:0]  o_rd_data_b,

    // --- 端口 C: 读端口 (来自 P3: Spatial Gate) ---
    input  wire                      i_rd_en_c,
    input  wire [ADDR_WIDTH-1:0]     i_rd_addr_c,
    output reg signed [DATA_WIDTH-1:0]  o_rd_data_c
);

    // 实例化 3 个独立的 BRAM
    (* ram_style = "block" *)
    reg [DATA_WIDTH-1:0] mem_a [0:RAM_DEPTH-1];
    
    (* ram_style = "block" *)
    reg [DATA_WIDTH-1:0] mem_b [0:RAM_DEPTH-1];
    
    (* ram_style = "block" *)
    reg [DATA_WIDTH-1:0] mem_c [0:RAM_DEPTH-1];

    // --- 端口 A: 写逻辑 (同时写入所有 BRAM) ---
    always @(posedge clk) begin
        if (i_wr_en) begin
            mem_a[i_wr_addr] <= i_wr_data;
            mem_b[i_wr_addr] <= i_wr_data;
            mem_c[i_wr_addr] <= i_wr_data;
        end
    end

    // --- 端口 A, B, C: 读逻辑 (各自读取) ---
    always @(posedge clk) begin
        if (i_rd_en_a) begin
            o_rd_data_a <= mem_a[i_rd_addr_a];
        end
        
        if (i_rd_en_b) begin
            o_rd_data_b <= mem_b[i_rd_addr_b];
        end
        
        if (i_rd_en_c) begin
            o_rd_data_c <= mem_c[i_rd_addr_c];
        end
    end

endmodule