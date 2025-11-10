`timescale 1ns / 1ps

/*
 * 模块: Spatial_Gate_Unit (C2.3) - (最终版)
 * 功能: 纯同步 FSM, 实现 C2.3 Spatial Gate 逻辑。
 * 架构: "2+1 共享方案" -> 此模块使用专用硬件。
 * 行为:
 * 1. 由 i_clk_en 和 i_start 门控和启动。
 * 2. 内部例化完整的流水线:
 * ChannelMean -> LineBuffer -> 
 * DWConv (Dedicated) -> HardSigmoid。
 * 3. 从 Feature_Map_Buffer 串行读取。
 * 4. 将结果 (1xHxW 掩码) 写入内部 P3_BRAM。
 * 5. 完成后拉高 o_done。
 * 6. 修复了 中 o_bram_rd_data 的 output reg 错误。
 */
module Spatial_Gate_Unit #(
    parameter DATA_W    = 8,
    parameter IN_CH     = 8,
    parameter K_DIM     = 3,
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
    input  wire signed [DATA_W-1:0]  i_fm_rd_data, // 串行读 (1 像素, 1 通道)

    // --- 接口: Kernel (来自 ULG_Coordinator) ---
    input  wire signed [K_DIM*K_DIM*DATA_W-1:0] i_kernel_data_flat,

    // --- 接口: 内部 BRAM 读端口 (供 Fusion FSM 读取) ---
    input  wire [FM_ADDR_W-1:0]      i_bram_rd_addr,
    // 【修正】: 必须声明为 reg
    output reg signed [DATA_W-1:0]   o_bram_rd_data
);

    localparam K_SZ        = K_DIM * K_DIM;
    localparam PIXEL_COUNT = IMG_H * IMG_W;
    // 注: line_buffer 实现的是 "valid" 
    // 将输出 (IMG_H-K_DIM+1) * (IMG_W-K_DIM+1) 个像素
    localparam VALID_PIXEL_COUNT = (IMG_H - K_DIM + 1) * (IMG_W - K_DIM + 1);
    
    // --- FSM 状态定义 ---
    localparam S_IDLE       = 3'b000;
    localparam S_LOAD_KERNEL= 3'b001;
    localparam S_RUN        = 3'b010;
    localparam S_FLUSH      = 3'b011;
    localparam S_DONE       = 3'b100;

    reg [2:0] state;
    reg [$clog2(PIXEL_COUNT*IN_CH):0] read_cnt;
    reg [$clog2(PIXEL_COUNT):0]       write_cnt;
    reg signed [K_SZ*DATA_W-1:0]      kernel_reg;

    // --- 内部 BRAM (P3 结果 BRAM) ---
    (* ram_style = "block" *)
    reg signed [DATA_W-1:0] p3_bram [0:VALID_PIXEL_COUNT-1];
    reg                           p3_bram_wr_en;
    reg [FM_ADDR_W-1:0]           p3_bram_wr_addr;
    
    // 4. HardSigmoid
    wire signed [DATA_W-1:0] hsig_out_data;
    wire                     hsig_out_valid;
    
    // BRAM 读端口 (时序)
    always @(posedge clk) begin
        if (i_clk_en) begin
            // 【修正】: 赋值给 output reg
            o_bram_rd_data <= p3_bram[i_bram_rd_addr];
        end
    end
    
    // BRAM 写端口 (时序)
    always @(posedge clk) begin
        if (i_clk_en) begin
            if (p3_bram_wr_en) begin
                p3_bram[p3_bram_wr_addr] <= hsig_out_data;
            end
        end
    end

    // --- 内部例化: C2.3 完整流水线 ---
    
    // 1. Channel Wise Mean
    wire signed [DATA_W-1:0] mean_out_data;
    wire                     mean_out_valid;
    reg                      mean_i_valid;

    channel_wise_mean_unit #(
        .DATA_W ( DATA_W ),
        .IN_CH  ( IN_CH  ),
        .ACC_W  ( ACC_W  )
    ) p3_mean_unit (
        .clk     ( clk ),
        .rst_n   ( rst_n ),
        .i_valid ( mean_i_valid & i_clk_en ),
        .i_data  ( i_fm_rd_data ),
        .o_data  ( mean_out_data ),
        .o_valid ( mean_out_valid )
    );

    // 2. Line Buffer
    wire signed [K_SZ*DATA_W-1:0] lb_out_win_flat;
    wire                          lb_out_valid;

    line_buffer_3x3 #(
        .DATA_W ( DATA_W ),
        .IMG_W  ( IMG_W  ),
        .K_DIM  ( K_DIM  )
    ) p3_lb_unit (
        .clk        ( clk ),
        .rst_n      ( rst_n ),
        .i_en       ( mean_out_valid & i_clk_en ), // 由 mean 单元驱动
        .i_data     ( mean_out_data ),
        .o_win_flat ( lb_out_win_flat ),
        .o_valid    ( lb_out_valid )
    );

    // 3. DWConv (DEDICATED_DW_UNIT)
    wire signed [ACC_W-1:0] dw_out_acc;
    wire                      dw_out_valid;

    depthwise_conv_unit #(
        .DATA_W ( DATA_W ),
        .K_DIM  ( K_DIM  ),
        .ACC_W  ( ACC_W  )
    ) p3_dw_unit (
        .clk           ( clk ),
        .rst_n         ( rst_n ),
        .i_valid       ( lb_out_valid & i_clk_en ), // 由 lb 单元驱动
        .i_win_flat    ( lb_out_win_flat ),
        .i_kernel_flat ( kernel_reg ),
        .o_acc         ( dw_out_acc ),
        .o_valid       ( dw_out_valid )
    );

    

    hardsigmoid_unit #(
        .DATA_W ( DATA_W )
    ) p3_hsig_unit (
        .clk     ( clk ),
        .rst_n   ( rst_n ),
        .i_valid ( dw_out_valid & i_clk_en ), // 由 dw 单元驱动
        .i_data  ( dw_out_acc[DATA_W-1:0] ), // 截断
        .o_data  ( hsig_out_data ),
        .o_valid ( hsig_out_valid )
    );
    

    // --- FSM (时序逻辑) ---
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            o_done   <= 1'b0;
            o_fm_rd_en <= 1'b0;
            o_fm_rd_addr <= 0;
            read_cnt   <= 0;
            write_cnt  <= 0;
            mean_i_valid <= 1'b0;
            p3_bram_wr_en <= 1'b0;
            p3_bram_wr_addr <= 0;
            kernel_reg <= 0;
        end else if (i_clk_en) begin // 模块只在 clk_en=1 时运行
            
            // 默认值
            o_done   <= 1'b0;
            o_fm_rd_en <= 1'b0;
            mean_i_valid <= 1'b0;
            p3_bram_wr_en <= 1'b0;

            case (state)
                S_IDLE: begin
                    read_cnt  <= 0;
                    write_cnt <= 0;
                    if (i_start) begin
                        state <= S_LOAD_KERNEL;
                    end
                end

                S_LOAD_KERNEL: begin
                    kernel_reg <= i_kernel_data_flat;
                    state <= S_RUN;
                end
                
                S_RUN: begin
                    // --- 启动流水线 ---
                    // 1. FM Read (为 p3_mean_unit 提供数据)
                    o_fm_rd_en   <= 1'b1;
                    o_fm_rd_addr <= read_cnt; 
                    mean_i_valid <= 1'b1;

                    // 4. BRAM Write (在流水线末端)
                    if (hsig_out_valid) begin
                        p3_bram_wr_en <= 1'b1;
                        p3_bram_wr_addr <= write_cnt;
                        write_cnt <= write_cnt + 1;
                    end
                    
                    // --- 计数器逻辑 ---
                    // (流水线启动端)
                    if (read_cnt == (PIXEL_COUNT * IN_CH) - 1) begin
                        // 停止读 FM 和 Mean 单元
                        o_fm_rd_en   <= 1'b0;
                        mean_i_valid <= 1'b0;
                        state        <= S_FLUSH;
                    end else begin
                        read_cnt <= read_cnt + 1;
                    end
                end
                
                S_FLUSH: begin
                    // 流水线输入已停止, 继续处理残余数据
                    if (hsig_out_valid) begin
                        p3_bram_wr_en <= 1'b1;
                        p3_bram_wr_addr <= write_cnt;
                        write_cnt <= write_cnt + 1;
                    end
                    
                    // (流水线末端)
                    if (write_cnt == VALID_PIXEL_COUNT) begin
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