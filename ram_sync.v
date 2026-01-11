`timescale 1ns / 1ps

module ram_sync #(
    parameter DATA_WIDTH = 24,
    parameter ADDR_WIDTH = 10,
    parameter MEM_FILE   = ""    
)(
    input  wire                  clk,
    
    // 写端口 (Port A)
    input  wire                  wr_en,
    input  wire [ADDR_WIDTH-1:0] wr_addr,
    input  wire [DATA_WIDTH-1:0] wr_data,
    
    // 读端口 (Port B)
    input  wire                  rd_en,
    input  wire [ADDR_WIDTH-1:0] rd_addr,
    output reg  [DATA_WIDTH-1:0] rd_data
);

    localparam MEM_DEPTH = 1 << ADDR_WIDTH;

    // 强制推断为 Block RAM
    (* ram_style = "block" *) 
    reg [DATA_WIDTH-1:0] mem [0:MEM_DEPTH-1];

    // 初始化 (通常用于仿真，FPGA上电初始值)
    integer i;
    initial begin
        if (MEM_FILE != "") begin
            $readmemh(MEM_FILE, mem);
        end else begin
            // 如果没有文件，初始化为全0 (对于SNN膜电位很重要)
            for (i = 0; i < MEM_DEPTH; i = i + 1) begin
                mem[i] = 0;
            end
        end
    end

    // 写逻辑 (Port A)
    always @(posedge clk) begin
        if (wr_en) begin
            mem[wr_addr] <= wr_data;
        end
    end

    // 读逻辑 (Port B)
    always @(posedge clk) begin
        if (rd_en) begin
            rd_data <= mem[rd_addr];
        end
    end

endmodule