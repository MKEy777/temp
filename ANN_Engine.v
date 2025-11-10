`timescale 1ns / 1ps

module ANN_Engine #(
    parameter DATA_W    = 8,
    parameter ACC_W     = 32,
    parameter K_DIM     = 3,
    
    parameter C1_IN_CH  = 4,
    parameter C1_OUT_CH = 8,
    parameter C1_IMG_W  = 9,
    parameter C1_IMG_H  = 8,
    
    parameter C2_IN_CH  = 8, 
    parameter C2_IMG_W  = 5, 
    parameter C2_IMG_H  = 4, 
    
    parameter FM_ADDR_W = 10,
    
    parameter C1_BIAS_W    = 32,
    parameter C1_SHIFT_BITS= 14
)(
    input  wire                      clk,
    input  wire                      rst_n,
    
    input  wire                      i_data_req,
    input  wire signed [C1_IN_CH*DATA_W-1:0] i_data_flat,
    output reg                       o_data_ack,

    output wire                      o_encoder_req,
    input  wire                      i_encoder_ack,
    output wire signed [C2_IN_CH*DATA_W-1:0] o_encoder_data_flat,
    
    input  wire signed [C1_IN_CH*K_DIM*K_DIM*DATA_W-1:0] i_kernel_c1_dw,
    input  wire signed [C1_OUT_CH*C1_IN_CH*DATA_W-1:0] i_kernel_c1_pw,
    input  wire signed [C1_BIAS_W-1:0]                 i_bias_c1_requant_dw,
    input  wire signed [C1_BIAS_W-1:0]                 i_bias_c1_requant_pw,
    input  wire signed [C2_IN_CH*K_DIM*K_DIM*DATA_W-1:0] i_kernel_c2_p1,
    input  wire signed [C2_IN_CH*C2_IN_CH*DATA_W-1:0] i_kernel_c2_p2,
    input  wire signed [K_DIM*K_DIM*DATA_W-1:0] i_kernel_c2_p3
);

    localparam C1_PIXEL_COUNT = C1_IMG_H * C1_IMG_W;
    localparam C1_VALID_PIXEL_COUNT = (C1_IMG_H - K_DIM + 1) * (C1_IMG_W - K_DIM + 1);

    // =========================================================================
    // 0. 声明所有 wire 和 reg
    // =========================================================================
    
    reg  [2:0] c1_state;
    reg  [$clog2(C1_PIXEL_COUNT):0] c1_pixel_cnt;
    reg  [$clog2(C1_VALID_PIXEL_COUNT):0] c1_write_cnt;
    reg  c1_done_internal;
    
    reg  c1_lb_i_en;
    reg  shared_dw_valid_c1;
    reg  c1_dw_requant_i_valid;
    reg  shared_pw_valid_c1;
    reg  c1_pw_requant_i_valid;
    reg  fm_wr_en;
    reg  [FM_ADDR_W-1:0] fm_wr_addr;
    reg  signed [C1_OUT_CH*DATA_W-1:0] shared_pw_vec_c1;
    wire signed [C1_OUT_CH*DATA_W-1:0] c1_pw_requant_out_flat; 

    wire shared_dw_valid_c2;
    wire signed [C2_IN_CH*K_DIM*K_DIM*DATA_W-1:0] shared_dw_win_c2;
    wire signed [C2_IN_CH*K_DIM*K_DIM*DATA_W-1:0] shared_dw_kernel_c2;
    wire shared_pw_valid_c2;
    wire signed [C2_IN_CH*DATA_W-1:0]             shared_pw_vec_c2;
    wire signed [C2_IN_CH*C2_IN_CH*DATA_W-1:0]    shared_pw_kernel_c2;

    wire o_fm_rd_en_p1, o_fm_rd_en_p2, o_fm_rd_en_p3;
    wire [FM_ADDR_W-1:0] o_fm_rd_addr_p1, o_fm_rd_addr_p2, o_fm_rd_addr_p3;
    
    wire ulg_p1_clk_en;
    wire ulg_p2_clk_en;
    
    // =========================================================================
    // 1. 例化 "硬件池" (2x DW, 1x PW)
    // =========================================================================
    
    reg                       shared_dw_clk_en;
    reg                       shared_dw_valid_mux;
    reg  signed [C1_IN_CH*K_DIM*K_DIM*DATA_W-1:0] shared_dw_win_mux; 
    reg  signed [C1_IN_CH*K_DIM*K_DIM*DATA_W-1:0] shared_dw_kernel_mux;
    wire signed [C1_IN_CH*ACC_W-1:0]   shared_dw_acc_flat;
    wire                      shared_dw_o_valid;
    
    depthwise_conv_unit #( 
        .DATA_W(DATA_W), .K_DIM(K_DIM), .ACC_W(ACC_W), .IN_CH(C1_IN_CH) 
    )
    SHARED_DW_UNIT (
        .clk(clk), .rst_n(rst_n),
        .i_valid(shared_dw_valid_mux & shared_dw_clk_en),
        .i_win_flat(shared_dw_win_mux),
        .i_kernel_flat(shared_dw_kernel_mux),
        .o_acc_flat(shared_dw_acc_flat),
        .o_valid(shared_dw_o_valid)
    );

    reg                       shared_pw_clk_en;
    reg                       shared_pw_valid_mux;
    reg  signed [C1_OUT_CH*DATA_W-1:0] shared_pw_vec_mux; 
    reg  signed [C1_OUT_CH*C1_IN_CH*DATA_W-1:0] shared_pw_kernel_mux;
    wire signed [C1_OUT_CH*ACC_W-1:0] shared_pw_acc_flat;
    wire                      shared_pw_o_valid;
    
    pointwise_conv_unit #(
        .DATA_W(DATA_W), .ACC_W(ACC_W), 
        .IN_CH(C1_IN_CH), .OUT_CH(C1_OUT_CH)
    )
    SHARED_PW_UNIT (
        .clk(clk), .rst_n(rst_n),
        .i_valid(shared_pw_valid_mux & shared_pw_clk_en),
        .i_vec_flat(shared_pw_vec_mux),
        .i_weights_flat(shared_pw_kernel_mux),
        .o_vec_flat(shared_pw_acc_flat),
        .o_valid(shared_pw_o_valid)
    );
    
    // =========================================================================
    // 2. 例化存储器 (Feature_Map_Buffer)
    // =========================================================================
    
    wire signed [C1_OUT_CH*DATA_W-1:0] fm_rd_data_p1;
    wire signed [C1_OUT_CH*DATA_W-1:0] fm_rd_data_p2;
    wire signed [DATA_W-1:0]           fm_rd_data_p3;
    
    Feature_Map_Buffer_1W3R #( 
        .DATA_WIDTH(C1_OUT_CH*DATA_W), .ADDR_WIDTH(FM_ADDR_W) 
    )
    fm_bram_inst (
        .clk(clk),
        .i_wr_en(fm_wr_en),
        .i_wr_addr(fm_wr_addr),
        .i_wr_data(c1_pw_requant_out_flat),
        
        .i_rd_en_a(o_fm_rd_en_p1),
        .i_rd_addr_a(o_fm_rd_addr_p1),
        .o_rd_data_a(fm_rd_data_p1), 
        
        .i_rd_en_b(o_fm_rd_en_p2),
        .i_rd_addr_b(o_fm_rd_addr_p2),
        .o_rd_data_b(fm_rd_data_p2), 
        
        .i_rd_en_c(o_fm_rd_en_p3),
        .i_rd_addr_c(o_fm_rd_addr_p3),
        .o_rd_data_c(fm_rd_data_p3)
    );

    // =========================================================================
    // 3. 例化 C2 协调器 (ULG_Coordinator)
    // =========================================================================
    reg  ulg_clk_en;
    reg  ulg_start;
    wire ulg_done;
    
    ULG_Coordinator #(
        .DATA_W(DATA_W), .IN_CH(C2_IN_CH), .ACC_W(ACC_W), .K_DIM(K_DIM),
        .IMG_W(C2_IMG_W), .IMG_H(C2_IMG_H), .FM_ADDR_W(FM_ADDR_W)
    ) ulg_coord_inst (
        .clk(clk), .rst_n(rst_n),
        .i_clk_en(ulg_clk_en),
        .i_start(ulg_start),
        .o_done(ulg_done),
        
        .i_kernel_p1_main(i_kernel_c2_p1),
        .i_kernel_p2_chan(i_kernel_c2_p2),
        .i_kernel_p3_spat(i_kernel_c2_p3),
        
        .o_fm_rd_en_p1(o_fm_rd_en_p1),
        .o_fm_rd_addr_p1(o_fm_rd_addr_p1),
        .i_fm_rd_data_p1(fm_rd_data_p1),
        
        .o_fm_rd_en_p2(o_fm_rd_en_p2),
        .o_fm_rd_addr_p2(o_fm_rd_addr_p2),
        .i_fm_rd_data_p2(fm_rd_data_p2),
        
        .o_fm_rd_en_p3(o_fm_rd_en_p3),
        .o_fm_rd_addr_p3(o_fm_rd_addr_p3),
        .i_fm_rd_data_p3(fm_rd_data_p3),
        
        .o_shared_dw_valid(shared_dw_valid_c2),
        .o_shared_dw_win_flat(shared_dw_win_c2),
        .o_shared_dw_kernel(shared_dw_kernel_c2),
        .i_shared_dw_acc_flat(shared_dw_acc_flat),
        .i_shared_dw_o_valid(shared_dw_o_valid),
        
        .o_shared_pw_valid(shared_pw_valid_c2),
        .o_shared_pw_vec_flat(shared_pw_vec_c2),
        .o_shared_pw_weights_flat(shared_pw_kernel_c2),
        .i_shared_pw_o_vec_flat(shared_pw_acc_flat),
        .i_shared_pw_o_valid(shared_pw_o_valid),
        
        .o_p1_clk_en(ulg_p1_clk_en),
        .o_p2_clk_en(ulg_p2_clk_en),

        .o_encoder_req(o_encoder_req),
        .i_encoder_ack(i_encoder_ack),
        .o_encoder_data_flat(o_encoder_data_flat)
    );

    // =========================================================================
    // 4. C1 (DSC) 任务 FSM
    // =========================================================================
    
    wire signed [C1_IN_CH*K_DIM*K_DIM*DATA_W-1:0] c1_lb_out_flat;
    wire                      c1_lb_o_valid;
    wire signed [C1_OUT_CH*DATA_W-1:0] c1_dw_requant_out_flat;
    wire                      c1_dw_requant_o_valid;
    wire                      c1_pw_requant_o_valid;
    
    line_buffer_3x3 #(
        .DATA_W(DATA_W), .IMG_W(C1_IMG_W), .K_DIM(K_DIM), .IN_CH(C1_IN_CH)
    ) c1_lb_inst (
        .clk(clk), .rst_n(rst_n),
        .i_en(c1_lb_i_en & shared_dw_clk_en),
        .i_data_flat(i_data_flat),
        .o_win_flat(c1_lb_out_flat),
        .o_valid(c1_lb_o_valid)
    );
    
    requantize_relu #(
        .IN_W(ACC_W), .BIAS_W(C1_BIAS_W), .OUT_W(DATA_W), 
        .SHIFT_BITS(C1_SHIFT_BITS), .IN_CH(C1_IN_CH)
    ) c1_dw_requant_inst (
        .clk(clk), .rst_n(rst_n),
        .i_valid(c1_dw_requant_i_valid & shared_dw_clk_en),
        .i_acc_flat(shared_dw_acc_flat),
        .i_bias_flat(i_bias_c1_requant_dw),
        .o_data_flat(c1_dw_requant_out_flat),
        .o_valid(c1_dw_requant_o_valid)
    );
    
    requantize_relu #(
        .IN_W(ACC_W), .BIAS_W(C1_BIAS_W), .OUT_W(DATA_W), 
        .SHIFT_BITS(C1_SHIFT_BITS), .IN_CH(C1_OUT_CH)
    ) c1_pw_requant_inst (
        .clk(clk), .rst_n(rst_n),
        .i_valid(c1_pw_requant_i_valid & shared_pw_clk_en),
        .i_acc_flat(shared_pw_acc_flat),
        .i_bias_flat(i_bias_c1_requant_pw),
        .o_data_flat(c1_pw_requant_out_flat),
        .o_valid(c1_pw_requant_o_valid)
    );
    
    localparam C1_IDLE  = 3'b000;
    localparam C1_RUN   = 3'b001;
    localparam C1_FLUSH = 3'b010;
    localparam C1_DONE  = 3'b011;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            c1_state <= C1_IDLE;
            c1_done_internal <= 1'b0;
            c1_lb_i_en <= 1'b0;
            c1_pixel_cnt <= 0;
            c1_write_cnt <= 0;
            shared_dw_valid_c1 <= 1'b0;
            c1_dw_requant_i_valid <= 1'b0;
            shared_pw_valid_c1 <= 1'b0;
            shared_pw_vec_c1 <= 0;
            c1_pw_requant_i_valid <= 1'b0;
            fm_wr_en <= 1'b0;
            fm_wr_addr <= 0;
        // 【修复 2】: 使用 bitwise OR
        end else if (shared_dw_clk_en | shared_pw_clk_en) begin 
            
            c1_lb_i_en <= 1'b0;
            shared_dw_valid_c1 <= 1'b0;
            c1_dw_requant_i_valid <= 1'b0;
            shared_pw_valid_c1 <= 1'b0;
            c1_pw_requant_i_valid <= 1'b0;
            fm_wr_en <= 1'b0;
            c1_done_internal <= 1'b0;
            
            // --- C1 流水线控制 ---
            c1_lb_i_en <= 1'b1; 
            shared_dw_valid_c1 <= c1_lb_o_valid;
            c1_dw_requant_i_valid <= shared_dw_o_valid;
            shared_pw_valid_c1 <= c1_dw_requant_o_valid;
            shared_pw_vec_c1   <= c1_dw_requant_out_flat;
            c1_pw_requant_i_valid <= shared_pw_o_valid;
            
            if (c1_pw_requant_o_valid) begin
                fm_wr_en <= 1'b1;
                fm_wr_addr <= c1_write_cnt;
                c1_write_cnt <= c1_write_cnt + 1;
            end
            
            case (c1_state)
                C1_IDLE: begin
                    c1_pixel_cnt <= 0;
                    c1_write_cnt <= 0;
                    if (o_data_ack) begin 
                        c1_state <= C1_RUN;
                    end
                end
                
                C1_RUN: begin
                    if (c1_pixel_cnt == C1_PIXEL_COUNT - 1) begin
                        c1_lb_i_en <= 1'b0; 
                        c1_state   <= C1_FLUSH;
                    end else begin
                        c1_pixel_cnt <= c1_pixel_cnt + 1;
                    end
                end
                
                C1_FLUSH: begin
                    if (c1_write_cnt == C1_VALID_PIXEL_COUNT) begin
                        c1_state <= C1_DONE;
                    end
                end
                
                C1_DONE: begin
                    c1_done_internal <= 1'b1; 
                    c1_state         <= C1_IDLE;
                end
            endcase
        end
    end

    // =========================================================================
    // 5. GALS 任务协调器 (顶层 FSM)
    // =========================================================================
    
    // 【修复 3】: state 声明必须在 MUX 之前
    localparam S_IDLE   = 2'b00;
    localparam S_C1_RUN = 2'b01; 
    localparam S_C2_RUN = 2'b10; 

    reg [1:0] state;
    // 【修复 4】: 声明 c1_done 为 reg
    reg c1_done; 
    
    // --- 共享硬件 MUX 逻辑 ---
    always @(*) begin
        if (state == S_C1_RUN) begin
            shared_dw_win_mux    = c1_lb_out_flat;
            shared_dw_kernel_mux = i_kernel_c1_dw;
            shared_dw_valid_mux  = shared_dw_valid_c1;
            
            shared_pw_vec_mux    = shared_pw_vec_c1; 
            shared_pw_kernel_mux = i_kernel_c1_pw;
            shared_pw_valid_mux  = shared_pw_valid_c1;
            
        end else begin // (state == S_C2_RUN)
            shared_dw_win_mux    = shared_dw_win_c2;
            shared_dw_kernel_mux = shared_dw_kernel_c2;
            shared_dw_valid_mux  = shared_dw_valid_c2;

            shared_pw_vec_mux    = shared_pw_vec_c2; 
            shared_pw_kernel_mux = shared_pw_kernel_c2;
            shared_pw_valid_mux  = shared_pw_valid_c2;
        end
    end

    // --- GALS 任务 FSM (时序) ---
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            o_data_ack <= 1'b0;
            ulg_clk_en <= 1'b0;
            ulg_start  <= 1'b0;
            // 【修复 4】: 复位 c1_done reg
            c1_done    <= 1'b0;
            // 【修复 1】: c1_done_internal 不在此处复位
            shared_dw_clk_en <= 1'b0;
            shared_pw_clk_en <= 1'b0;
        end else begin
            
            o_data_ack <= 1'b0;
            ulg_start  <= 1'b0;
            // 【修复 4】: 锁存 C1 FSM 的完成信号
            c1_done    <= c1_done_internal; 

            case (state)
                S_IDLE: begin
                    // 【修复 1, 3】: 在 IDLE 状态复位 c1_done_internal
                    c1_done_internal <= 1'b0;
                    shared_dw_clk_en <= 1'b0;
                    shared_pw_clk_en <= 1'b0;
                    ulg_clk_en       <= 1'b0;

                    if (i_data_req) begin
                        o_data_ack       <= 1'b1;
                        state            <= S_C1_RUN;
                        shared_dw_clk_en <= 1'b1; 
                        shared_pw_clk_en <= 1'b1; 
                    end
                end
                
                S_C1_RUN: begin
                    if (c1_done) begin
                        state            <= S_C2_RUN;
                        
                        shared_dw_clk_en <= 1'b0; 
                        shared_pw_clk_en <= 1'b0; 
                        
                        ulg_clk_en       <= 1'b1; 
                        ulg_start        <= 1'b1;
                    end
                end
                
                S_C2_RUN: begin
                    // 【修复 1】: C2 控制共享硬件时钟
                    shared_dw_clk_en <= ulg_p1_clk_en;
                    shared_pw_clk_en <= ulg_p2_clk_en;
                    
                    if (ulg_done) begin
                        state      <= S_IDLE;
                        ulg_clk_en <= 1'b0; 
                    end
                end
            endcase
        end
    end

endmodule