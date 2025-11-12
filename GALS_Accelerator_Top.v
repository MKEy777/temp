`timescale 1ns / 1ps

/*
 * 模块: GALS_Accelerator_Top
 * 功能: GALS混合ANN-SNN加速器的顶层封装。
 * 职责:
 * 1. 例化 ANN_Engine, GALS_Encoder_Unit, SNN_Engine。
 * 2. 连接顶层 GALS 异步握手接口。
 * 3. 汇总所有硬件参数。
 * 4. 暴露数据和权重/偏置的顶层 I/O。
 */
module GALS_Accelerator_Top #(
    // --- 核心 Q1.7 参数 ---
    parameter DATA_W    = 8,   // 激活/权重 (Q1.7)
    parameter TIME_W    = 8,   // 脉冲时间 (Q1.7)
    parameter WEIGHT_W  = 8,   // SNN 权重 (Q1.7)
    parameter ACC_W     = 32,  // 32-bit 累加器
    
    // --- 卷积参数 ---
    parameter K_DIM     = 3,   // 3x3 卷积核
    
    // --- ANN C1 拓扑 (来自 QAT.py) ---
    parameter C1_IN_CH  = 4,
    parameter C1_OUT_CH = 8,
    parameter C1_IMG_W  = 9,
    parameter C1_IMG_H  = 8,
    
    // --- ANN C2 拓扑 (来自 QAT.py) ---
    parameter C2_IN_CH  = 8,   // C1_OUT_CH
    parameter C2_IMG_W  = 5,   // C1 卷积/步进后的结果
    parameter C2_IMG_H  = 4,
    
    // --- ANN Requantize 参数 ---
    parameter C1_BIAS_W     = 32,
    parameter C1_SHIFT_BITS = 14, // 示例
    
    // --- SNN 拓扑 (来自 QAT.py 和 SNN_Engine.v) ---
    parameter SNN_IN_LEN     = 160, // 8 (C2_IN_CH) * 5 * 4 = 160
    parameter DENSE1_NEURONS = 64,
    parameter DENSE2_NEURONS = 32,
    parameter DENSE3_NEURONS = 3,
    parameter NUM_ARRAYS     = 16,  // 64 PE / 4 PE-per-Array
    
    // --- 地址总线宽度 ---
    parameter FM_ADDR_W = 10,  // 特征图 BRAM 地址
    parameter ADDR_W    = 10   // SNN BRAM 地址
)(
    input  wire                      clk,
    input  wire                      rst_n,

    // --- ANN 顶层输入接口 ---
    input  wire                      i_data_req,    // 请求输入一帧 (来自外部)
    input  wire signed [C1_IN_CH*DATA_W-1:0] i_data_flat, // ANN 输入像素流
    output wire                      o_data_ack,    // 确认收到ANN输入

    // --- SNN 顶层控制接口 ---
    input  wire                      i_accelerator_start, // 启动 SNN (来自外部)
    output wire                      o_accelerator_done,  // SNN 完成
    output wire [$clog2(DENSE3_NEURONS)-1:0] o_predicted_class, // SNN 结果

    // --- 权重/偏置 ROM 接口 (来自外部) ---
    
    // ANN C1 (DSC)
    input  wire signed [C1_IN_CH*K_DIM*K_DIM*DATA_W-1:0] i_kernel_c1_dw,
    input  wire signed [C1_OUT_CH*C1_IN_CH*DATA_W-1:0] i_kernel_c1_pw,
    input  wire signed [C1_BIAS_W-1:0]                 i_bias_c1_requant_dw,
    input  wire signed [C1_BIAS_W-1:0]                 i_bias_c1_requant_pw,
    
    // ANN C2 (ULG)
    input  wire signed [C2_IN_CH*K_DIM*K_DIM*DATA_W-1:0] i_kernel_c2_p1,
    input  wire signed [C2_IN_CH*C2_IN_CH*DATA_W-1:0] i_kernel_c2_p2,
    input  wire signed [K_DIM*K_DIM*DATA_W-1:0] i_kernel_c2_p3,
    
    // SNN 层间阈值 (来自外部 ROM)
    /*
     * 注: SNN_Engine 期望 i_snn_threshold_data 端口在正确的时间
     * (由 SNN_Engine 内部的 Intermediate_Buffer_Encoder 决定) 
     * 携带正确的阈值 D_i。
     * 在实际系统中，这需要一个 ROM，其地址由 SNN_Engine 的
     * 内部信号驱动 (该地址端口在 SNN_Engine.v 中未被导出)。
     * 此处我们仅暴露 SNN_Engine.v 所需的数据端口。
     */
    input  wire signed [WEIGHT_W-1:0] i_snn_threshold_data
);

    // =========================================================================
    // 1. GALS 握手连线
    // =========================================================================
    
    // --- 接口 1: ANN_Engine -> GALS_Encoder_Unit ---
    // (ANN 发送 Q1.7 像素流)
    wire        ann_to_enc_req;
    wire        ann_to_enc_ack;
    wire signed [C2_IN_CH*DATA_W-1:0] ann_to_enc_data; // (8-channel wide)
    
    // --- 接口 2: GALS_Encoder_Unit -> SNN_Engine ---
    // (Encoder 广播 Q1.7 AER 脉冲)
    wire        enc_to_snn_req;
    wire        enc_to_snn_ack;
    wire        enc_to_snn_done;
    wire signed [TIME_W-1:0] enc_to_snn_time;
    
    // 地址总线匹配
    localparam SNN_ADDR_W = $clog2(SNN_IN_LEN); // 8-bit (for 160)
    wire [SNN_ADDR_W-1:0] enc_to_snn_addr_raw;
    wire [ADDR_W-1:0]     enc_to_snn_addr_padded;
    
    // SNN_Engine 期望 [ADDR_W-1:0] 输入, 
    // GALS_Encoder 输出 [$clog2(VEC_LEN)-1:0]
    assign enc_to_snn_addr_padded = { {(ADDR_W - SNN_ADDR_W){1'b0}}, enc_to_snn_addr_raw };


    // =========================================================================
    // 2. 例化 GALS 模块
    // =========================================================================

    // --- 模块 1: ANN 前端引擎 ---
    ANN_Engine #(
        .DATA_W    ( DATA_W    ), .ACC_W     ( ACC_W     ), .K_DIM     ( K_DIM     ),
        .C1_IN_CH  ( C1_IN_CH  ), .C1_OUT_CH ( C1_OUT_CH ), .C1_IMG_W  ( C1_IMG_W  ),
        .C1_IMG_H  ( C1_IMG_H  ), .C2_IN_CH  ( C2_IN_CH  ), .C2_IMG_W  ( C2_IMG_W  ),
        .C2_IMG_H  ( C2_IMG_H  ), .FM_ADDR_W ( FM_ADDR_W ), .C1_BIAS_W ( C1_BIAS_W ),
        .C1_SHIFT_BITS( C1_SHIFT_BITS )
    ) ann_engine_inst (
        .clk        ( clk ),
        .rst_n      ( rst_n ),
        
        .i_data_req ( i_data_req ),
        .i_data_flat( i_data_flat ),
        .o_data_ack ( o_data_ack ),

        .o_encoder_req     ( ann_to_enc_req ),
        .i_encoder_ack     ( ann_to_enc_ack ),
        .o_encoder_data_flat( ann_to_enc_data ),
        
        .i_kernel_c1_dw      ( i_kernel_c1_dw ),
        .i_kernel_c1_pw      ( i_kernel_c1_pw ),
        .i_bias_c1_requant_dw( i_bias_c1_requant_dw ),
        .i_bias_c1_requant_pw( i_bias_c1_requant_pw ),
        .i_kernel_c2_p1      ( i_kernel_c2_p1 ),
        .i_kernel_c2_p2      ( i_kernel_c2_p2 ),
        .i_kernel_c2_p3      ( i_kernel_c2_p3 )
    );

    // --- 模块 2: GALS 桥接器 (ANN -> SNN) ---
  
    localparam ENCODER_PIXEL_VEC_LEN = C2_IN_CH;
    localparam ENCODER_NUM_PIXELS    = SNN_IN_LEN / ENCODER_PIXEL_VEC_LEN;
    
    GALS_Encoder_Unit #(
        .VEC_LEN       ( SNN_IN_LEN ),
        .PIXEL_VEC_LEN ( ENCODER_PIXEL_VEC_LEN ),
        .NUM_PIXELS    ( ENCODER_NUM_PIXELS ),
        .DATA_W        ( DATA_W ),
        .TIME_W        ( TIME_W ),
        

        .T_MAX_Q17 ( 8'd127 ),
        .K_MIN_Q17 ( -8'd128 ),
        .SHIFT_BITS( 2 )
    ) gals_encoder_inst (
        .local_clk ( clk ),
        .rst_n     ( rst_n ),

        // 来自 ANN_Engine
        .i_data_req( ann_to_enc_req ),
        .o_data_ack( ann_to_enc_ack ),
        .i_data_bus( ann_to_enc_data ), 

        // 发往 SNN_Engine
        .o_aer_req     ( enc_to_snn_req ),
        .i_aer_ack     ( enc_to_snn_ack ),
        .o_aer_time    ( enc_to_snn_time ),
        .o_aer_addr    ( enc_to_snn_addr_raw ),
        .o_encoder_done( enc_to_snn_done ),
        
        .o_busy ( /* 未连接 */ )
    );

    // --- 模块 3: SNN 后端引擎 ---
    SNN_Engine #(
        .TIME_W      ( TIME_W ),
        .WEIGHT_W    ( WEIGHT_W ),
        .ACC_W       ( ACC_W ),
        .ADDR_W      ( ADDR_W ),
        .NUM_ARRAYS  ( NUM_ARRAYS ),
        .SNN_IN_LEN  ( SNN_IN_LEN ),
        .DENSE1_NEURONS ( DENSE1_NEURONS ),
        .DENSE2_NEURONS ( DENSE2_NEURONS ),
        .DENSE3_NEURONS ( DENSE3_NEURONS ),
        
        // BRAM 偏移量 (来自 SNN_Engine.v 默认值)
        .BRAM_OFFSET_D1 ( 10'd0 ),
        .BRAM_OFFSET_D2 ( 10'd160 ), // SNN_IN_LEN
        .BRAM_OFFSET_D3 ( 10'd224 ), // 160 + 64
        
        // t_min (来自 SNN_Engine.v 默认值)
        .T_MIN_D1_Q17 ( 8'd0 ),
        .T_MIN_D2_Q17 ( 8'd20 ),
        .T_MIN_D3_Q17 ( 8'd40 )
    ) snn_engine_inst (
        .local_clk ( clk ),
        .rst_n     ( rst_n ),

        // 顶层控制
        .i_accelerator_start( i_accelerator_start ),
        .o_accelerator_done ( o_accelerator_done ),
        .o_predicted_class  ( o_predicted_class ),

        // 来自 GALS_Encoder_Unit
        .i_enc_aer_req    ( enc_to_snn_req ),
        .i_enc_aer_time   ( enc_to_snn_time ),
        .i_enc_aer_addr   ( enc_to_snn_addr_padded ), // 使用填充后的地址
        .i_enc_done       ( enc_to_snn_done ),
        .o_enc_aer_ack    ( enc_to_snn_ack ),

        // 阈值 ROM 接口
        .i_threshold_data ( i_snn_threshold_data )
    );

endmodule