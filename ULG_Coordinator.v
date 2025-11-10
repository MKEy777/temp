`timescale 1ns / 1ps

/*
 * 模块: ULG_Coordinator (C2)
 * 功能: C2 阶段 GALS 协调器，实现 2+1 共享方案
 * 职责:
 * 1. 例化 P1, P2, P3 子模块
 * 2. 精细时钟门控
 * 3. 共享卷积单元 (P1→SHARED_DW_UNIT, P2→SHARED_PW_UNIT)
 * 4. P3 使用独立 DEDICATED_DW_UNIT
 * 5. 融合 (A*B)*C 结果
 * 6. 实现 GALS 握手
 */
module ULG_Coordinator #(
    parameter DATA_W    = 8,
    parameter IN_CH     = 8,
    parameter ACC_W     = 32,
    parameter K_DIM     = 3,
    parameter IMG_W     = 5,
    parameter IMG_H     = 4,
    parameter FM_ADDR_W = 10
)(
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire                      i_clk_en,
    input  wire                      i_start,
    output reg                       o_done,

    input  wire signed [IN_CH*K_DIM*K_DIM*DATA_W-1:0] i_kernel_p1_main,
    input  wire signed [IN_CH*IN_CH*DATA_W-1:0]       i_kernel_p2_chan,
    input  wire signed [K_DIM*K_DIM*DATA_W-1:0]       i_kernel_p3_spat,

    output reg                       o_fm_rd_en_p1,
    output reg [FM_ADDR_W-1:0]       o_fm_rd_addr_p1,
    input  wire signed [IN_CH*DATA_W-1:0] i_fm_rd_data_p1,

    output reg                       o_fm_rd_en_p2,
    output reg [FM_ADDR_W-1:0]       o_fm_rd_addr_p2,
    input  wire signed [IN_CH*DATA_W-1:0] i_fm_rd_data_p2,

    output reg                       o_fm_rd_en_p3,
    output reg [FM_ADDR_W-1:0]       o_fm_rd_addr_p3,
    input  wire signed [DATA_W-1:0]  i_fm_rd_data_p3,

    output reg                       o_shared_dw_valid,
    output wire signed [IN_CH*K_DIM*K_DIM*DATA_W-1:0] o_shared_dw_win_flat,
    output reg  signed [IN_CH*K_DIM*K_DIM*DATA_W-1:0] o_shared_dw_kernel,
    input  wire signed [IN_CH*ACC_W-1:0]   i_shared_dw_acc_flat,
    input  wire                      i_shared_dw_o_valid,

    output reg                       o_shared_pw_valid,
    output wire signed [IN_CH*DATA_W-1:0] o_shared_pw_vec_flat,
    output reg  signed [IN_CH*IN_CH*DATA_W-1:0] o_shared_pw_weights_flat,
    input  wire signed [IN_CH*ACC_W-1:0]   i_shared_pw_o_vec_flat,
    input  wire                      i_shared_pw_o_valid,
    
    output reg                       o_encoder_req,
    input  wire                      i_encoder_ack,
    output reg signed [IN_CH*DATA_W-1:0] o_encoder_data_flat
);

    localparam K_SZ = K_DIM * K_DIM;
    localparam PIXEL_COUNT = IMG_H * IMG_W;
    localparam VALID_PIXEL_COUNT = (IMG_H - K_DIM + 1) * (IMG_W - K_DIM + 1);

    // =========================================================================
    // 子模块接口定义
    // =========================================================================
    wire p1_clk_en, p2_clk_en, p3_clk_en;
    reg  p1_start_reg, p2_start_reg, p3_start_reg;
    wire p1_done, p2_done, p3_done;
    reg  p1_done_reg, p2_done_reg, p3_done_reg;

    reg [FM_ADDR_W-1:0] p1_bram_rd_addr;
    wire signed [IN_CH*DATA_W-1:0] p1_bram_rd_data;
    reg [0:0] p2_bram_rd_addr;
    wire signed [IN_CH*DATA_W-1:0] p2_bram_rd_data;
    reg [FM_ADDR_W-1:0] p3_bram_rd_addr;
    wire signed [DATA_W-1:0] p3_bram_rd_data;

    // =========================================================================
    // 子模块例化
    // =========================================================================
    Main_Path_Unit #(
        .DATA_W(DATA_W), .IN_CH(IN_CH), .K_DIM(K_DIM), .ACC_W(ACC_W),
        .IMG_W(IMG_W), .IMG_H(IMG_H), .FM_ADDR_W(FM_ADDR_W)
    ) p1_main_path_inst (
        .clk(clk), .rst_n(rst_n),
        .i_clk_en(p1_clk_en), .i_start(p1_start_reg), .o_done(p1_done),
        .o_fm_rd_en(o_fm_rd_en_p1), .o_fm_rd_addr(o_fm_rd_addr_p1),
        .i_fm_rd_data_flat(i_fm_rd_data_p1), .i_kernel_data_flat(i_kernel_p1_main),
        .o_conv_valid(o_shared_dw_valid), .o_conv_win_flat(o_shared_dw_win_flat),
        .o_conv_kernel_flat(o_shared_dw_kernel),
        .i_conv_acc_flat(i_shared_dw_acc_flat), .i_conv_o_valid(i_shared_dw_o_valid),
        .i_bram_rd_addr(p1_bram_rd_addr), .o_bram_rd_data_flat(p1_bram_rd_data)
    );

    Channel_Gate_Unit #(
        .DATA_W(DATA_W), .IN_CH(IN_CH), .ACC_W(ACC_W),
        .IMG_W(IMG_W), .IMG_H(IMG_H), .FM_ADDR_W(FM_ADDR_W)
    ) p2_channel_gate_inst (
        .clk(clk), .rst_n(rst_n),
        .i_clk_en(p2_clk_en), .i_start(p2_start_reg), .o_done(p2_done),
        .o_fm_rd_en(o_fm_rd_en_p2), .o_fm_rd_addr(o_fm_rd_addr_p2),
        .i_fm_rd_data_flat(i_fm_rd_data_p2), .i_kernel_data_flat(i_kernel_p2_chan),
        .o_conv_valid(o_shared_pw_valid), .o_conv_vec_flat(o_shared_pw_vec_flat),
        .o_conv_weights_flat(o_shared_pw_weights_flat),
        .i_conv_o_vec_flat(i_shared_pw_o_vec_flat), .i_conv_o_valid(i_shared_pw_o_valid),
        .i_bram_rd_addr(p2_bram_rd_addr), .o_bram_rd_data_flat(p2_bram_rd_data)
    );

    Spatial_Gate_Unit #(
        .DATA_W(DATA_W), .IN_CH(IN_CH), .K_DIM(K_DIM), .ACC_W(ACC_W),
        .IMG_W(IMG_W), .IMG_H(IMG_H), .FM_ADDR_W(FM_ADDR_W)
    ) p3_spatial_gate_inst (
        .clk(clk), .rst_n(rst_n),
        .i_clk_en(p3_clk_en), .i_start(p3_start_reg), .o_done(p3_done),
        .o_fm_rd_en(o_fm_rd_en_p3), .o_fm_rd_addr(o_fm_rd_addr_p3),
        .i_fm_rd_data(i_fm_rd_data_p3), .i_kernel_data_flat(i_kernel_p3_spat),
        .i_bram_rd_addr(p3_bram_rd_addr), .o_bram_rd_data(p3_bram_rd_data)
    );

    // =========================================================================
    // 融合 (Fusion) 单元
    // =========================================================================
    wire signed [DATA_W-1:0] f_mul1_out, f_mul2_out;
    wire f_mul1_valid, f_mul2_valid;
    reg  f_mul1_i_valid, f_mul2_i_valid;
    reg  signed [DATA_W-1:0] f_mul1_a, f_mul1_b;
    reg  signed [DATA_W-1:0] f_mul2_a, f_mul2_b;
    
    arithmetic_unit #(.DATA_W(DATA_W)) f_mul1 (
        .clk(clk), .rst_n(rst_n),
        .i_valid(f_mul1_i_valid & i_clk_en),
        .i_data_a(f_mul1_a), .i_data_b(f_mul1_b),
        .o_data(f_mul1_out), .o_valid(f_mul1_valid)
    );
    
    arithmetic_unit #(.DATA_W(DATA_W)) f_mul2 (
        .clk(clk), .rst_n(rst_n),
        .i_valid(f_mul2_i_valid & i_clk_en),
        .i_data_a(f_mul2_a), .i_data_b(f_mul2_b),
        .o_data(f_mul2_out), .o_valid(f_mul2_valid)
    );

    wire signed [DATA_W-1:0] p1_rd_unpacked [0:IN_CH-1];
    wire signed [DATA_W-1:0] p2_rd_unpacked [0:IN_CH-1];

    genvar i;
    generate
        for (i = 0; i < IN_CH; i = i + 1) begin : gen_fusion_unpack
            assign p1_rd_unpacked[i] = p1_bram_rd_data[(i+1)*DATA_W-1 -: DATA_W];
            assign p2_rd_unpacked[i] = p2_bram_rd_data[(i+1)*DATA_W-1 -: DATA_W];
        end
    endgenerate

    // =========================================================================
    // 融合 FSM
    // =========================================================================
    localparam F_IDLE = 4'b0000;
    localparam F_START_PATHS = 4'b0001;
    localparam F_WAIT_PATHS  = 4'b0010;
    localparam F_FUSION_READ = 4'b0011;
    localparam F_FUSION_MUL1 = 4'b0100;
    localparam F_FUSION_MUL2 = 4'b0101;
    localparam F_FUSION_PACK = 4'b0110;
    localparam F_FUSION_REQ  = 4'b0111;
    localparam F_FUSION_WAIT_ACK = 4'b1000;
    localparam F_DONE = 4'b1001;
    
    reg [3:0] state_fusion;
    reg [$clog2(VALID_PIXEL_COUNT):0] f_pixel_cnt;
    reg [$clog2(IN_CH):0] f_ch_cnt;
    reg signed [IN_CH*DATA_W-1:0] o_encoder_data_reg;

    assign p1_clk_en = i_clk_en & ~p1_done_reg;
    assign p2_clk_en = i_clk_en & ~p2_done_reg;
    assign p3_clk_en = i_clk_en & ~p3_done_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_fusion <= F_IDLE;
            o_done <= 1'b0;
            p1_start_reg <= 1'b0; p2_start_reg <= 1'b0; p3_start_reg <= 1'b0;
            p1_done_reg <= 1'b0;  p2_done_reg <= 1'b0;  p3_done_reg <= 1'b0;
            f_pixel_cnt <= 0; f_ch_cnt <= 0;
            p1_bram_rd_addr <= 0; p2_bram_rd_addr <= 0; p3_bram_rd_addr <= 0;
            f_mul1_i_valid <= 1'b0; f_mul2_i_valid <= 1'b0;
            o_encoder_req <= 1'b0;
            o_encoder_data_flat <= 0;
            o_encoder_data_reg <= 0;
        end else if (i_clk_en) begin
            if (p1_done) p1_done_reg <= 1'b1;
            if (p2_done) p2_done_reg <= 1'b1;
            if (p3_done) p3_done_reg <= 1'b1;

            o_done <= 1'b0;
            p1_start_reg <= 1'b0;
            p2_start_reg <= 1'b0;
            p3_start_reg <= 1'b0;
            f_mul1_i_valid <= 1'b0;
            f_mul2_i_valid <= 1'b0;

            case (state_fusion)
                F_IDLE: begin
                    o_encoder_req <= 1'b0;
                    p1_done_reg <= 1'b0;
                    p2_done_reg <= 1'b0;
                    p3_done_reg <= 1'b0;
                    if (i_start) state_fusion <= F_START_PATHS;
                end

                F_START_PATHS: begin
                    p1_start_reg <= 1'b1;
                    p2_start_reg <= 1'b1;
                    p3_start_reg <= 1'b1;
                    state_fusion <= F_WAIT_PATHS;
                end

                F_WAIT_PATHS: begin
                    if (p1_done_reg && p2_done_reg && p3_done_reg) begin
                        f_pixel_cnt <= 0;
                        f_ch_cnt <= 0;
                        state_fusion <= F_FUSION_READ;
                    end
                end

                F_FUSION_READ: begin
                    p1_bram_rd_addr <= f_pixel_cnt;
                    p3_bram_rd_addr <= f_pixel_cnt;
                    p2_bram_rd_addr <= 0;
                    state_fusion <= F_FUSION_MUL1;
                end

                F_FUSION_MUL1: begin
                    f_mul1_i_valid <= 1'b1;
                    f_mul1_a <= p1_rd_unpacked[f_ch_cnt];
                    f_mul1_b <= p2_rd_unpacked[f_ch_cnt];
                    state_fusion <= F_FUSION_MUL2;
                end

                F_FUSION_MUL2: begin
                    if (f_mul1_valid) begin
                        f_mul2_i_valid <= 1'b1;
                        f_mul2_a <= f_mul1_out;
                        f_mul2_b <= p3_bram_rd_data;
                    end
                    if (f_mul2_valid) state_fusion <= F_FUSION_PACK;
                end

                F_FUSION_PACK: begin
                    if (f_mul2_valid) begin
                        o_encoder_data_reg[(f_ch_cnt+1)*DATA_W-1 -: DATA_W] <= f_mul2_out;
                        if (f_ch_cnt == IN_CH - 1)
                            state_fusion <= F_FUSION_REQ;
                        else begin
                            f_ch_cnt <= f_ch_cnt + 1;
                            state_fusion <= F_FUSION_MUL1;
                        end
                    end
                end

                F_FUSION_REQ: begin
                    o_encoder_data_flat <= o_encoder_data_reg;
                    o_encoder_req <= 1'b1;
                    state_fusion <= F_FUSION_WAIT_ACK;
                end

                F_FUSION_WAIT_ACK: begin
                    o_encoder_req <= 1'b1;
                    if (i_encoder_ack) begin
                        o_encoder_req <= 1'b0;
                        if (f_pixel_cnt == VALID_PIXEL_COUNT - 1)
                            state_fusion <= F_DONE;
                        else begin
                            f_pixel_cnt <= f_pixel_cnt + 1;
                            f_ch_cnt <= 0;
                            state_fusion <= F_FUSION_READ;
                        end
                    end
                end

                F_DONE: begin
                    o_done <= 1'b1;
                    state_fusion <= F_IDLE;
                end

                default: state_fusion <= F_IDLE;
            endcase
        end
    end
endmodule
