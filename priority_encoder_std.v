`timescale 1ns / 1ps

module priority_encoder_std #(
    parameter N    = 64,
    parameter IDXW = $clog2(N)
) (
    input  wire [N-1:0] in,
    output reg          has,
    output reg [IDXW-1:0] idx
);
    
    integer i;
    
    always @(*) begin
        has = 1'b0;
        idx = {IDXW{1'b0}}; 
        
        for (i = 0; i < N; i = i + 1) begin
            if (in[i]) begin
                has = 1'b1;
                idx = i;
            end
        end
    end

endmodule