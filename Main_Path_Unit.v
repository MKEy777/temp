`timescale 1ns / 1ps

// ------------------------------------------------------------
// 模块: Main_Path_Unit
// 功能: 卷积主路径单元 (C2.1)
// 行为:
//   1. 从 Feature Map Buffer 读取数据并输入 LineBuffer。
//   2. 生成 3x3 窗口并送入外部共享卷积单元。
//   3. 将卷积结果写入内部 BRAM。
//   4. 可被 Fusion FSM 读取中间结果。
// ------------------------------------------------------------
module Main_Path_Unit #(
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

    // 控制接口
    input  wire                      i_clk_en,
    input  wire                      i_start,
    output reg                       o_done,

    // Feature Map Buffer 读口
    output reg                       o_fm_rd_en,
    output reg  [FM_ADDR_W-1:0]      o_fm_rd_addr,
    input  wire signed [IN_CH*DATA_W-1:0] i_fm_rd_data_flat,

    // Kernel 数据输入
    input  wire signed [IN_CH*K_DIM*K_DIM*DATA_W-1:0] i_kernel_data_flat,

    // 卷积单元接口
    output reg                       o_conv_valid,
    output wire signed [IN_CH*K_DIM*K_DIM*DATA_W-1:0] o_conv_win_flat,
    output reg  signed [IN_CH*K_DIM*K_DIM*DATA_W-1:0] o_conv_kernel_flat,
    input  wire signed [IN_CH*ACC_W-1:0]   i_conv_acc_flat,
    input  wire                      i_conv_o_valid,

    // BRAM 读端口 (供后级读取)
    input  wire [FM_ADDR_W-1:0]      i_bram_rd_addr,
    output reg signed [IN_CH*DATA_W-1:0] o_bram_rd_data_flat
);

    localparam K_SZ        = K_DIM * K_DIM;
    localparam PIXEL_COUNT = IMG_H * IMG_W;

    // FSM 状态定义
    localparam S_IDLE       = 3'b000;
    localparam S_LOAD_KERNEL= 3'b001;
    localparam S_RUN        = 3'b010;
    localparam S_FLUSH      = 3'b011;
    localparam S_DONE       = 3'b100;

    reg [2:0] state;
    reg [$clog2(PIXEL_COUNT):0] pixel_cnt;
    reg [$clog2(PIXEL_COUNT):0] write_cnt;

    // 内部 BRAM：保存 P1 层卷积结果
    (* ram_style = "block" *)
    reg signed [IN_CH*DATA_W-1:0] p1_bram [0:PIXEL_COUNT-1];
    reg                           p1_bram_wr_en;
    reg [FM_ADDR_W-1:0]           p1_bram_wr_addr;
    wire signed [IN_CH*DATA_W-1:0] p1_bram_wr_data;

    // BRAM 读写逻辑
    always @(posedge clk) begin
        if (i_clk_en)
            o_bram_rd_data_flat <= p1_bram[i_bram_rd_addr];
    end

    always @(posedge clk) begin
        if (i_clk_en && p1_bram_wr_en)
            p1_bram[p1_bram_wr_addr] <= p1_bram_wr_data;
    end

    // ------------------- LineBuffer 阵列 -------------------
    wire signed [DATA_W-1:0]  p1_fm_unpacked [0:IN_CH-1];
    wire signed [K_SZ*DATA_W-1:0] p1_lb_out_flat [0:IN_CH-1];
    wire                      p1_lb_valid_ch0;
    wire [0:IN_CH-1]          p1_lb_valids;
    reg                       lb_i_en;

    genvar i;
    generate
        // 解包输入特征图通道
        for (i = 0; i < IN_CH; i = i + 1) begin : gen_p1_unpack_fm
            assign p1_fm_unpacked[i] = i_fm_rd_data_flat[(i+1)*DATA_W-1 -: DATA_W];
        end

        // 每通道一个 LineBuffer
        for (i = 0; i < IN_CH; i = i + 1) begin : gen_p1_lb
            line_buffer_3x3 #(
                .DATA_W (DATA_W),
                .IMG_W  (IMG_W),
                .K_DIM  (K_DIM)
            ) p1_lb_inst (
                .clk        (clk),
                .rst_n      (rst_n),
                .i_en       (lb_i_en & i_clk_en),
                .i_data     (p1_fm_unpacked[i]),
                .o_win_flat (p1_lb_out_flat[i]),
                .o_valid    (p1_lb_valids[i])
            );
        end
        assign p1_lb_valid_ch0 = p1_lb_valids[0];

        // 打包 3x3 窗口输出
        for (i = 0; i < IN_CH; i = i + 1) begin : gen_p1_pack_win
            assign o_conv_win_flat[(i+1)*K_SZ*DATA_W-1 -: K_SZ*DATA_W] = p1_lb_out_flat[i];
        end
        
        // 打包卷积结果写入 BRAM
        for (i = 0; i < IN_CH; i = i + 1) begin : gen_p1_pack_res
            wire signed [ACC_W-1:0] acc_slice;
            assign acc_slice = i_conv_acc_flat[(i+1)*ACC_W-1 -: ACC_W];
            assign p1_bram_wr_data[(i+1)*DATA_W-1 -: DATA_W] = acc_slice[DATA_W-1:0];
        end
    endgenerate

    // ------------------- FSM 主控制逻辑 -------------------
    reg p1_lb_valid_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            o_done   <= 1'b0;
            o_fm_rd_en <= 1'b0;
            o_fm_rd_addr <= 0;
            lb_i_en    <= 1'b0;
            pixel_cnt  <= 0;
            write_cnt  <= 0;
            o_conv_valid <= 1'b0;
            o_conv_kernel_flat <= 0;
            p1_bram_wr_en <= 1'b0;
            p1_bram_wr_addr <= 0;
            p1_lb_valid_reg <= 1'b0;
        end else if (i_clk_en) begin 
            // 默认值
            o_done        <= 1'b0;
            o_fm_rd_en    <= 1'b0;
            lb_i_en       <= 1'b0;
            o_conv_valid  <= 1'b0;
            p1_bram_wr_en <= 1'b0;

            // 窗口有效同步控制
            p1_lb_valid_reg <= p1_lb_valid_ch0;
            o_conv_valid    <= p1_lb_valid_reg;

            // 写回 BRAM
            if (i_conv_o_valid) begin
                p1_bram_wr_en <= 1'b1;
                p1_bram_wr_addr <= write_cnt;
                write_cnt <= write_cnt + 1;
            end
            
            // 状态机
            case (state)
                S_IDLE: begin
                    pixel_cnt <= 0;
                    write_cnt <= 0;
                    if (i_start)
                        state <= S_LOAD_KERNEL;
                end

                S_LOAD_KERNEL: begin
                    o_conv_kernel_flat <= i_kernel_data_flat;
                    state <= S_RUN;
                end
                
                S_RUN: begin
                    o_fm_rd_en <= 1'b1;
                    o_fm_rd_addr <= pixel_cnt;
                    lb_i_en <= 1'b1;
                    if (pixel_cnt == PIXEL_COUNT - 1) begin
                        o_fm_rd_en <= 1'b0;
                        lb_i_en <= 1'b0;
                        state <= S_FLUSH;
                    end else
                        pixel_cnt <= pixel_cnt + 1;
                end
                
                S_FLUSH: begin
                    if (write_cnt == PIXEL_COUNT)
                        state <= S_DONE;
                end
                
                S_DONE: begin
                    o_done <= 1'b1;
                    state  <= S_IDLE;
                end
            endcase
        end
    end
endmodule
