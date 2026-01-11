`timescale 1ns/1ps

/**
 * Module: conv_linebuf_3x3
 * Fixed: 
 * 1. Increased warmup threshold to (IMG_WIDTH + 1) to flush undefined data from sliding window.
 * 2. Restored coordinate hold logic to ensure (0,0) is processed correctly.
 */
module conv_linebuf_3x3 #(
    parameter DATA_WIDTH = 8,
    parameter IMG_WIDTH  = 64,
    parameter IMG_HEIGHT = 64
) (
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire [DATA_WIDTH-1:0]   data_in,
    input  wire                    data_valid,
    output wire                    data_ready,
    output wire [DATA_WIDTH*9-1:0] window_out, 
    output wire                    window_valid,
    output wire                    init_done
);
    localparam CNT_WIDTH        = $clog2(IMG_WIDTH);
    localparam CNT_HEIGHT_WIDTH = $clog2(IMG_HEIGHT);

    reg [DATA_WIDTH-1:0] line_buf0 [0:IMG_WIDTH-1];
    reg [DATA_WIDTH-1:0] line_buf1 [0:IMG_WIDTH-1];
    reg [CNT_WIDTH-1:0]  wr_x_cnt;
    reg [DATA_WIDTH-1:0] win_raw [2:0][2:0];

    // Control Signals
    reg [15:0]           pixel_counter;
    reg                  warmup_done;
    reg                  valid_out_reg;

    reg [CNT_WIDTH-1:0]        out_x;
    reg [CNT_HEIGHT_WIDTH-1:0] out_y;

    wire [DATA_WIDTH-1:0] lb0_out;
    wire [DATA_WIDTH-1:0] lb1_out;

    reg [DATA_WIDTH-1:0] win_y_muxed [2:0][2:0];
    reg [DATA_WIDTH-1:0] win_final   [2:0][2:0];

    integer i, j;

    assign data_ready = 1'b1;
    assign lb0_out = line_buf0[wr_x_cnt];
    assign lb1_out = line_buf1[wr_x_cnt];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_x_cnt      <= 0;
            pixel_counter <= 0;
            warmup_done   <= 1'b0;
            valid_out_reg <= 1'b0;
            out_x         <= 0;
            out_y         <= 0;
            for(i=0; i<3; i=i+1)
                for(j=0; j<3; j=j+1) win_raw[i][j] <= 0;
        end else if (data_valid) begin
            // 1. Line Buffer Write & Shift
            line_buf0[wr_x_cnt] <= data_in;
            line_buf1[wr_x_cnt] <= lb0_out;

            // 2. Pointer Update
            if (wr_x_cnt == IMG_WIDTH - 1)
                wr_x_cnt <= 0;
            else
                wr_x_cnt <= wr_x_cnt + 1;

            // 3. Window Shift
            win_raw[0][2] <= win_raw[0][1]; win_raw[0][1] <= win_raw[0][0]; win_raw[0][0] <= lb1_out;
            win_raw[1][2] <= win_raw[1][1]; win_raw[1][1] <= win_raw[1][0]; win_raw[1][0] <= lb0_out;
            win_raw[2][2] <= win_raw[2][1]; win_raw[2][1] <= win_raw[2][0]; win_raw[2][0] <= data_in;

            // 4. Counter & Validation Logic
            // [FIX] Threshold increased to IMG_WIDTH + 1
            // This ensures P0 shifts from win_raw[...][0] to win_raw[...][1] (Center)
            if (pixel_counter < (IMG_WIDTH + 1)) begin
                pixel_counter <= pixel_counter + 1;
                valid_out_reg <= 1'b0;
                warmup_done   <= 1'b0;
            end else begin
                warmup_done   <= 1'b1;
                valid_out_reg <= 1'b1;

                // [FIX] Coordinate Update: Only increment if we were ALREADY valid.
                // This holds out_x=0 for the very first valid cycle.
                if (valid_out_reg) begin
                    if (out_x == IMG_WIDTH - 1) begin
                        out_x <= 0;
                        if (out_y == IMG_HEIGHT - 1) 
                            out_y <= 0;
                        else 
                            out_y <= out_y + 1;
                    end else begin
                        out_x <= out_x + 1;
                    end
                end
            end
        end else begin
            valid_out_reg <= 1'b0;
        end
    end

    // Combinational Padding Logic (Same as before)
    always @(*) begin
        if (out_y == 0) begin
            {win_y_muxed[0][2], win_y_muxed[0][1], win_y_muxed[0][0]} = {DATA_WIDTH{1'b0}};
            {win_y_muxed[1][2], win_y_muxed[1][1], win_y_muxed[1][0]} = {win_raw[1][2], win_raw[1][1], win_raw[1][0]};
            {win_y_muxed[2][2], win_y_muxed[2][1], win_y_muxed[2][0]} = {win_raw[2][2], win_raw[2][1], win_raw[2][0]};
        end
        else if (out_y == IMG_HEIGHT - 1) begin
            {win_y_muxed[0][2], win_y_muxed[0][1], win_y_muxed[0][0]} = {win_raw[0][2], win_raw[0][1], win_raw[0][0]};
            {win_y_muxed[1][2], win_y_muxed[1][1], win_y_muxed[1][0]} = {win_raw[1][2], win_raw[1][1], win_raw[1][0]};
            {win_y_muxed[2][2], win_y_muxed[2][1], win_y_muxed[2][0]} = {DATA_WIDTH{1'b0}};
        end
        else begin
            for(i=0; i<3; i=i+1)
                for(j=0; j<3; j=j+1)
                    win_y_muxed[i][j] = win_raw[i][j];
        end
    end

    always @(*) begin
        if (out_x == 0) begin
            for(i=0; i<3; i=i+1) begin
                win_final[i][2] = {DATA_WIDTH{1'b0}};
                win_final[i][1] = win_y_muxed[i][1];
                win_final[i][0] = win_y_muxed[i][0];
            end
        end
        else if (out_x == IMG_WIDTH - 1) begin
            for(i=0; i<3; i=i+1) begin
                win_final[i][2] = win_y_muxed[i][2];
                win_final[i][1] = win_y_muxed[i][1];
                win_final[i][0] = {DATA_WIDTH{1'b0}};
            end
        end
        else begin
            for(i=0; i<3; i=i+1) begin
                win_final[i][2] = win_y_muxed[i][2];
                win_final[i][1] = win_y_muxed[i][1];
                win_final[i][0] = win_y_muxed[i][0];
            end
        end
    end

    assign window_out = {
        win_final[2][0], win_final[2][1], win_final[2][2], 
        win_final[1][0], win_final[1][1], win_final[1][2], 
        win_final[0][0], win_final[0][1], win_final[0][2] 
    };
    assign window_valid = valid_out_reg;
    assign init_done    = warmup_done;

endmodule