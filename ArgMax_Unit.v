`timescale 1ns / 1ps

// ============================================================================
// Module:  ArgMax_Unit
// Function: Finds the index of the maximum value in a vector.
// ============================================================================
module ArgMax_Unit #(
    parameter VEC_LEN = 3,  // Vector length (number of classes)
    parameter DATA_W  = 48  // Data width of the potential vector
) (
    input wire                        clk,
    input wire                        rst_n,
    input wire                        i_valid, // From SNN_Output_Layer's out_req/done signal
    input wire signed [VEC_LEN*DATA_W-1:0] i_potentials_flat,

    output reg                        o_valid,
    output reg [$clog2(VEC_LEN)-1:0]  o_predicted_class
);

    // Internal registers to hold the current maximum value and its index
    reg signed [DATA_W-1:0]       max_val;
    reg [$clog2(VEC_LEN)-1:0]   max_idx;
    
    // Pipeline registers for output
    reg [$clog2(VEC_LEN)-1:0]   o_predicted_class_reg;
    reg                         o_valid_reg;

    integer i;

    // Combinational logic to find the max value and index
    always @(*) begin
        // Initialize with the first element
        max_val = i_potentials_flat[DATA_W-1:0];
        max_idx = 0;
        
        // Loop to find the maximum
        for (i = 1; i < VEC_LEN; i = i + 1) begin
            if (i_potentials_flat[(i+1)*DATA_W-1 -: DATA_W] > max_val) begin
                max_val = i_potentials_flat[(i+1)*DATA_W-1 -: DATA_W];
                max_idx = i;
            end
        end
    end

    // Sequential logic to register the result
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_valid <= 1'b0;
            o_predicted_class <= 0;
        end else begin
            // Register the combinational result
            o_valid <= i_valid;
            if (i_valid) begin
                o_predicted_class <= max_idx;
            end
        end
    end

endmodule