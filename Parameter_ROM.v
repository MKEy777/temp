`timescale 1ns / 1ps

module Parameter_ROM #(
    parameter DATA_WIDTH = 8,
    parameter ADDR_WIDTH = 10,
    parameter MEM_FILE   = ""
)(
    input  wire                  clk,
    input  wire [ADDR_WIDTH-1:0] addr,
    output wire signed [DATA_WIDTH-1:0] data_out
);

    rom_sync #(
        .DATA_WIDTH ( DATA_WIDTH ),
        .ADDR_WIDTH ( ADDR_WIDTH ),
        .MEM_FILE   ( MEM_FILE   )
    ) rom_inst (
        .clk        ( clk      ),
        .addr       ( addr     ),
        .data_out   ( data_out )
    );

endmodule