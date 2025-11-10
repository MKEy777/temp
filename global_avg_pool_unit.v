`timescale 1ns / 1ps

module global_avg_pool_unit #(
    parameter DATA_W = 8,
    parameter IN_CH  = 8,
    parameter IMG_H  = 4,
    parameter IMG_W  = 5,
    parameter ACC_W  = 32
) (
    input wire                       clk,
    input wire                       rst_n,
    input wire                       i_valid,
    input wire signed [IN_CH*DATA_W-1:0] i_data_flat, 
    
    output reg signed [IN_CH*DATA_W-1:0] o_data_flat,
    output reg                       o_valid
);
    localparam PIXEL_COUNT = IMG_H * IMG_W;
    localparam SHIFT_BITS  = $clog2(PIXEL_COUNT);
    
    localparam S_IDLE       = 2'b00;
    localparam S_ACCUMULATE = 2'b01;
    localparam S_OUTPUT     = 2'b10;

    reg [1:0] state;
    reg [$clog2(PIXEL_COUNT)-1:0] pixel_cnt;
    reg signed [ACC_W-1:0] acc_regs [0:IN_CH-1];
    
    // --- 组合逻辑: 展开输入 (保持不变) ---
    wire signed [DATA_W-1:0] i_data_unpacked [0:IN_CH-1];
    genvar i;
    generate
        for (i = 0; i < IN_CH; i = i + 1) begin : unpack_input
            assign i_data_unpacked[i] = i_data_flat[(i+1)*DATA_W-1 : i*DATA_W];
        end
    endgenerate

    // 1. 定义一个 wire 来承载组合逻辑的计算结果
    wire signed [IN_CH*DATA_W-1:0] o_data_flat_internal;
    
    // 2. 使用 generate 块来并行计算和打包所有通道的输出
    genvar k;
    generate
        for (k = 0; k < IN_CH; k = k + 1) begin : pack_output
            // 这里的 k 是一个常量, 所以 [(k+1)*DATA_W-1 : k*DATA_W] 是合法的
            assign o_data_flat_internal[(k+1)*DATA_W-1 : k*DATA_W] = 
                   $signed(acc_regs[k]) >>> SHIFT_BITS;
        end
    endgenerate

    integer j; 
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            pixel_cnt <= 0;
            o_valid   <= 1'b0;
            o_data_flat <= 0;
            for (j = 0; j < IN_CH; j = j + 1) begin
                acc_regs[j] <= {ACC_W{1'b0}};
            end
        end else begin
            o_valid <= 1'b0;
            
            case (state)
                S_IDLE: begin
                    if (i_valid) begin
                        pixel_cnt <= 1;
                        state     <= S_ACCUMULATE;
                        for (j = 0; j < IN_CH; j = j + 1) begin
                            // j 作为数组索引是合法的
                            acc_regs[j] <= $signed(i_data_unpacked[j]);
                        end
                    end
                end
                
                S_ACCUMULATE: begin
                    if (i_valid) begin
                        for (j = 0; j < IN_CH; j = j + 1) begin
                            acc_regs[j] <= acc_regs[j] + $signed(i_data_unpacked[j]);
                        end
                        
                        if (pixel_cnt == PIXEL_COUNT - 1) begin
                            pixel_cnt <= 0;
                            state     <= S_OUTPUT;
                        end else begin
                            pixel_cnt <= pixel_cnt + 1;
                        end
                    end
                end
                
                S_OUTPUT: begin
                    o_valid <= 1'b1;
                    state   <= S_IDLE;
                    
                    // 3. 直接赋值 pre-packed 好的 wire
                    o_data_flat <= o_data_flat_internal;
                end
                
                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule