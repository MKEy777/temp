`timescale 1ns/1ps
`default_nettype wire

module avgpool2d_stream #(
    parameter IMG_WIDTH = 32,  // 输入图像宽度
    parameter IN_WIDTH  = 4,   // 输入位宽
    parameter OUT_WIDTH = 6    // 输出位宽 
)(
    input  wire                     clk,
    input  wire                     rst_n,

    // Input Interface
    input  wire [IN_WIDTH-1:0]      din,
    input  wire                     din_valid,
    output wire                     din_ready,

    // Output Interface
    output reg  [OUT_WIDTH-1:0]     dout,
    output reg                      dout_valid,
    input  wire                     dout_ready
);

    // ------------------------------------------------------
    // Flow Control & Coordinates
    // ------------------------------------------------------
    assign din_ready = dout_ready; // Transparent backpressure
    wire handshake   = din_valid && dout_ready;

    reg [$clog2(IMG_WIDTH)-1:0] col_cnt;
    reg                         row_idx; // 0: Even row, 1: Odd row

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col_cnt <= 0;
            row_idx <= 0;
        end else if (handshake) begin
            if (col_cnt == IMG_WIDTH - 1) begin
                col_cnt <= 0;
                row_idx <= ~row_idx;
            end else begin
                col_cnt <= col_cnt + 1;
            end
        end
    end

    // ------------------------------------------------------
    // Line Buffer (Stores previous row)
    // ------------------------------------------------------
    reg [IN_WIDTH-1:0] line_buff [0:IMG_WIDTH-1];
    reg [IN_WIDTH-1:0] lb_val_out;

    always @(posedge clk) begin
        if (handshake) begin
            lb_val_out         <= line_buff[col_cnt]; // Read previous row
            line_buff[col_cnt] <= din;                // Write current row
        end
    end

    // ------------------------------------------------------
    // 2x2 Window & Computation
    // Window: [p0, p1] (Prev Row)
    //         [p2, p3] (Curr Row)
    // ------------------------------------------------------
    reg [IN_WIDTH-1:0] p0, p1, p2, p3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dout_valid <= 0;
            dout       <= 0;
            p0 <= 0; p1 <= 0; p2 <= 0; p3 <= 0;
        end else begin
            dout_valid <= 0;

            if (handshake) begin
                // Shift Window
                p3 <= din;        // Bottom-Right
                p2 <= p3;         // Bottom-Left
                p1 <= lb_val_out; // Top-Right
                p0 <= p1;         // Top-Left

                // Output Condition: Odd Row & Odd Column
                // Note: p0/p2 align with col_cnt-1. When col_cnt is odd (e.g. 1), 
                // we have columns [0, 1] ready.
                if (row_idx == 1'b1 && col_cnt[0] == 1'b1) begin
                    // Sum Calculation with zero-padding
                    dout <= { {(OUT_WIDTH-IN_WIDTH){1'b0}}, p0 } + 
                            { {(OUT_WIDTH-IN_WIDTH){1'b0}}, p1 } + 
                            { {(OUT_WIDTH-IN_WIDTH){1'b0}}, p2 } + 
                            { {(OUT_WIDTH-IN_WIDTH){1'b0}}, p3 };
                            
                    dout_valid <= 1'b1;
                end
            end
        end
    end

endmodule