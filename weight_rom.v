`timescale 1ns/1ps

module weight_rom #(
    parameter ADDR_WIDTH = 5,    // ∂‘”¶ IN_CHANNELS
    parameter DATA_WIDTH = 2304  // 32 * 9 * 8
)(
    input  wire                  clk,
    input  wire [ADDR_WIDTH-1:0] addr,
    output reg  [DATA_WIDTH-1:0] q
);

    reg [DATA_WIDTH-1:0] rom [0:(1<<ADDR_WIDTH)-1];

    initial begin
        $readmemh("weights.mem", rom);
    end

    always @(posedge clk) begin
        q <= rom[addr];
    end

endmodule