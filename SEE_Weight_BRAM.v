`timescale 1ns / 1ps

module SEE_Weight_BRAM #(
    parameter WEIGHT_W = 8,
    parameter ADDR_W   = 10,
    parameter MEM_FILE = ""
)(
    input  wire                clk,
    input  wire [ADDR_W-1:0]   addr,
    output wire signed [WEIGHT_W-1:0] data_out
);

    rom_sync #(
        .DATA_WIDTH ( WEIGHT_W ),
        .ADDR_WIDTH ( ADDR_W   ),
        .MEM_FILE   ( MEM_FILE )
    ) bram_inst (
        .clk        ( clk      ),
        .addr       ( addr     ),
        .data_out   ( data_out )
    );

endmodule