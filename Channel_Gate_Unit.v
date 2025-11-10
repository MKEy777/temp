`timescale 1ns / 1ps

/*
 * 模块: Channel_Gate_Unit (C2.2) - (最终修正版)
 * 修正:
 * 1. [修复 image_d16920.png 同类bug]: o_bram_rd_data_flat 声明为 output reg。
 * 2. [修复 image_d1697b.png 同类bug]: 修正了 gen_p2_hsig 中非法的双重范围选择。
 * 3. [修复 image_d1709c.png]: 修正了 gen_p2_hsig 中 .o_valid 的语法错误。
 */
module Channel_Gate_Unit #(
    parameter DATA_W    = 8,
    parameter IN_CH     = 8,
    parameter ACC_W     = 32,
    parameter IMG_W     = 5,
    parameter IMG_H     = 4,
    parameter FM_ADDR_W = 10
)(
    input  wire                      clk,
    input  wire                      rst_n,
    
    // --- 控制端口 (来自 ULG_Coordinator) ---
    input  wire                      i_clk_en,
    input  wire                      i_start,
    output reg                       o_done,

    // --- 接口: Feature_Map_Buffer (只读) ---
    output reg                       o_fm_rd_en,
    output reg  [FM_ADDR_W-1:0]      o_fm_rd_addr,
    input  wire signed [IN_CH*DATA_W-1:0] i_fm_rd_data_flat,

    // --- 接口: Kernel (来自 ULG_Coordinator) ---
    input  wire signed [IN_CH*IN_CH*DATA_W-1:0] i_kernel_data_flat,

    // --- 接口: 外部 SHARED_PW_UNIT ---
    output reg                       o_conv_valid,
    output reg signed [IN_CH*DATA_W-1:0] o_conv_vec_flat, 
    output reg signed [IN_CH*IN_CH*DATA_W-1:0] o_conv_weights_flat,
    input  wire signed [IN_CH*ACC_W-1:0]   i_conv_o_vec_flat, 
    input  wire                      i_conv_o_valid,

    // --- 接口: 内部 BRAM 读端口 (供 Fusion FSM 读取) ---
    input  wire [0:0]                i_bram_rd_addr, 
    output reg signed [IN_CH*DATA_W-1:0] o_bram_rd_data_flat
);

    localparam PIXEL_COUNT = IMG_H * IMG_W;

    // --- FSM 状态定义 ---
    localparam S_IDLE       = 4'b0000;
    localparam S_LOAD_KERNEL= 4'b0001;
    localparam S_RUN_GAP    = 4'b0010;
    localparam S_WAIT_GAP   = 4'b0011;
    localparam S_RUN_PWCONV = 4'b0100;
    localparam S_WAIT_PWCONV= 4'b0101;
    localparam S_RUN_HSIG   = 4'b0110;
    localparam S_WRITE_BRAM = 4'b0111;
    localparam S_DONE       = 4'b1000;

    reg [3:0] state;
    reg [$clog2(PIXEL_COUNT):0] pixel_cnt;
    
    // --- 内部 BRAM (P2 结果 BRAM) ---
    (* ram_style = "block" *)
    reg signed [IN_CH*DATA_W-1:0] p2_bram [0:0]; 
    reg                           p2_bram_wr_en;
    wire signed [IN_CH*DATA_W-1:0] p2_bram_wr_data;
    
    always @(posedge clk) begin
        if (i_clk_en) begin
            o_bram_rd_data_flat <= p2_bram[0]; 
        end
    end
    
    always @(posedge clk) begin
        if (i_clk_en) begin
            if (p2_bram_wr_en) begin
                p2_bram[0] <= p2_bram_wr_data;
            end
        end
    end
    
    // --- 内部例化: GlobalAvgPool ---
    wire signed [IN_CH*DATA_W-1:0] p2_gap_out_flat;
    wire                           p2_gap_out_valid;
    reg                            p2_gap_i_valid;

    global_avg_pool_unit #(
        .DATA_W ( DATA_W ),
        .IN_CH  ( IN_CH  ),
        .IMG_H  ( IMG_H  ),
        .IMG_W  ( IMG_W  ),
        .ACC_W  ( ACC_W  )
    ) p2_gap_unit (
        .clk         ( clk ),
        .rst_n       ( rst_n ),
        .i_valid     ( p2_gap_i_valid & i_clk_en ),
        .i_data_flat ( i_fm_rd_data_flat ),
        .o_data_flat ( p2_gap_out_flat ),
        .o_valid     ( p2_gap_out_valid )
    );

    // --- 内部例化: HardSigmoid 阵列 ---
    wire signed [DATA_W-1:0] p2_hsig_out_unpacked [0:IN_CH-1];
    wire                     p2_hsig_out_valid; 
    wire [0:IN_CH-1]         p2_hsig_valids; // 【修正 3】
    reg                      p2_hsig_i_valid;
    
    genvar i;
    generate
        for (i = 0; i < IN_CH; i = i + 1) begin : gen_p2_hsig
            wire signed [ACC_W-1:0] acc_slice;
            assign acc_slice = i_conv_o_vec_flat[(i+1)*ACC_W-1 -: ACC_W];
            
            wire signed [DATA_W-1:0] hsig_in;
            assign hsig_in = acc_slice[DATA_W-1:0];
            
            hardsigmoid_unit #( .DATA_W(DATA_W) )
            p2_hsig_inst (
                .clk(clk), .rst_n(rst_n),
                .i_valid(p2_hsig_i_valid & i_clk_en),
                .i_data(hsig_in),
                .o_data(p2_hsig_out_unpacked[i]),
                // 【修正 3】: 连接到一个 wire 数组
                .o_valid( p2_hsig_valids[i] )
            );
            
            assign p2_bram_wr_data[(i+1)*DATA_W-1 -: DATA_W] = p2_hsig_out_unpacked[i];
        end
        // 【修正 3】: 仅使用 Ch0 作为同步信号
        assign p2_hsig_out_valid = p2_hsig_valids[0];
    endgenerate
    
    // --- FSM (时序逻辑) ---
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            o_done   <= 1'b0;
            o_fm_rd_en <= 1'b0;
            o_fm_rd_addr <= 0;
            pixel_cnt  <= 0;
            p2_gap_i_valid <= 1'b0;
            o_conv_valid <= 1'b0;
            o_conv_vec_flat <= 0;
            o_conv_weights_flat <= 0;
            p2_hsig_i_valid <= 1'b0;
            p2_bram_wr_en <= 1'b0;
        end else if (i_clk_en) begin 
            
            // 默认值
            o_done   <= 1'b0;
            o_fm_rd_en <= 1'b0;
            p2_gap_i_valid <= 1'b0;
            o_conv_valid <= 1'b0;
            p2_hsig_i_valid <= 1'b0;
            p2_bram_wr_en <= 1'b0;

            case (state)
                S_IDLE: begin
                    pixel_cnt <= 0;
                    if (i_start) begin
                        state <= S_LOAD_KERNEL;
                    end
                end

                S_LOAD_KERNEL: begin
                    o_conv_weights_flat <= i_kernel_data_flat;
                    state <= S_RUN_GAP;
                end
                
                S_RUN_GAP: begin
                    o_fm_rd_en <= 1'b1;
                    o_fm_rd_addr <= pixel_cnt;
                    p2_gap_i_valid <= 1'b1;
                    
                    if (pixel_cnt == PIXEL_COUNT - 1) begin
                        o_fm_rd_en <= 1'b0;
                        p2_gap_i_valid <= 1'b0; 
                        state <= S_WAIT_GAP;
                    end else begin
                        pixel_cnt <= pixel_cnt + 1;
                    end
                end
                
                S_WAIT_GAP: begin
                    if (p2_gap_out_valid) begin
                        // (假设类型匹配, 实际需要符号扩展)
                        o_conv_vec_flat <= p2_gap_out_flat; 
                        state <= S_RUN_PWCONV;
                    end
                end
                
                S_RUN_PWCONV: begin
                    o_conv_valid <= 1'b1;
                    state <= S_WAIT_PWCONV;
                end
                
                S_WAIT_PWCONV: begin
                    if (i_conv_o_valid) begin
                        state <= S_RUN_HSIG;
                    end
                end
                
                S_RUN_HSIG: begin
                    p2_hsig_i_valid <= 1'b1;
                    state <= S_WRITE_BRAM;
                end

                S_WRITE_BRAM: begin
                    if (p2_hsig_out_valid) begin
                        p2_bram_wr_en <= 1'b1; 
                        state <= S_DONE;
                    end
                end
                
                S_DONE: begin
                    o_done <= 1'b1;
                    state  <= S_IDLE;
                end
                
                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule