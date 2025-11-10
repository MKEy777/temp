`timescale 1ns / 1ps

/*
 * 模块: SNN_Engine [重构版]
 * 功能: SNN 后端 GALS Master FSM (总指挥)。
 * 职责:
 * 1. 例化 16x 阵列 (64 PEs) 和 16x 32-bit BRAMs。
 * 2. 例化 层间编码器 和 决策单元。
 * 3. 实现 3 周期 FSM (dense_1, dense_2, dense_3)。
 * 4. 控制时钟使能 (CE) 和 BRAM 偏移量，实现层同步。
 */
module SNN_Engine #(
    // --- 核心 Q1.7 参数 ---
    parameter TIME_W      = 8,
    parameter WEIGHT_W    = 8,
    parameter ACC_W       = 32,
    parameter ADDR_W      = 10, // SNN 输入(160) + 最大偏移量(224) < 1024
    
    // --- 架构参数 ---
    parameter NUM_ARRAYS    = 16, // 16 阵列 = 64 PEs
    
    // --- 软件拓扑 (160 -> 64 -> 32 -> 3) ---
    parameter SNN_IN_LEN     = 160,
    parameter DENSE1_NEURONS = 64,
    parameter DENSE2_NEURONS = 32,
    parameter DENSE3_NEURONS = 3,
    
    // --- 权重 BRAM 偏移量 (基于 SNN 拓扑) ---
    parameter BRAM_OFFSET_D1 = 10'd0,
    parameter BRAM_OFFSET_D2 = 10'd160, // D1 偏移 = D1 输入 (160)
    parameter BRAM_OFFSET_D3 = 10'd224, // D2 偏移 = 160 + D1 输出 (64)

    // --- t_min (Q1.7 示例值) ---
    parameter signed [TIME_W-1:0] T_MIN_D1_Q17 = 8'd0,
    parameter signed [TIME_W-1:0] T_MIN_D2_Q17 = 8'd20,
    parameter signed [TIME_W-1:0] T_MIN_D3_Q17 = 8'd40
)(
    input  wire                      local_clk, // SNN 后端的本地时钟
    input  wire                      rst_n,

    // --- 顶层控制 ---
    input  wire                      i_accelerator_start, // 启动 SNN
    output reg                       o_accelerator_done,
    output reg [$clog2(DENSE3_NEURONS)-1:0] o_predicted_class,

    // --- 接口: GALS_Encoder_Unit (信使 1) ---
    input  wire                      i_enc_aer_req,    // (来自 ANN->SNN Encoder)
    input  wire signed [TIME_W-1:0]  i_enc_aer_time,
    input  wire [ADDR_W-1:0]         i_enc_aer_addr,   // (假设已扩展到 ADDR_W)
    input  wire                      i_enc_done,
    output reg                       o_enc_aer_ack,

    // --- 接口: Threshold (D_i) ROM ---
    input  wire signed [WEIGHT_W-1:0] i_threshold_data
);
    localparam D1_ADDR_W = $clog2(DENSE1_NEURONS); // 6
    localparam D2_ADDR_W = $clog2(DENSE2_NEURONS); // 5

    // GALS Master FSM 状态
    localparam S_IDLE        = 5'b00000;
    localparam S_DENSE1_RUN  = 5'b00001;
    localparam S_DENSE1_READ = 5'b00010; // 读 D1 电位 (64次)
    localparam S_DENSE2_RUN  = 5'b00100;
    localparam S_DENSE2_READ = 5'b00101; // 读 D2 电位 (32次)
    localparam S_DENSE3_RUN  = 5'b01000;
    localparam S_DENSE3_READ = 5'b01001; // 读 D3 电位 (3次)
    localparam S_ARGMAX_REG  = 5'b01010; // 寄存 ArgMax 输入
    localparam S_ARGMAX_WAIT = 5'b01100;
    localparam S_DONE        = 5'b01101;
    localparam S_ERROR       = 5'b10000;
    
    reg [4:0] state, next_state;

    // --- 内部连线与寄存器 ---
    reg  [NUM_ARRAYS-1:0]    array_clk_en;
    reg  [4*NUM_ARRAYS-1:0]  array_pe_enable;
    reg  [ADDR_W-1:0]        current_bram_offset;
    reg  signed [TIME_W-1:0] current_t_min;
    reg  [NUM_ARRAYS-1:0]    array_reset_potential;
    
    wire [NUM_ARRAYS-1:0]     array_aer_ack;
    wire [NUM_ARRAYS-1:0]     array_error;
    
    // 读/写 FSM 计数器
    reg  [D1_ADDR_W-1:0]     rw_cnt; // (0-63)
    
    // SNN_Array_4PE 输出 (16 组 [4*ACC_W] 的扁平向量)
    wire signed [4*ACC_W-1:0] potentials_array_flat [0:NUM_ARRAYS-1];
    // 解包后的 64 个 32-bit 电位
    wire signed [ACC_W-1:0]   potentials_unpacked [0:NUM_ARRAYS*4-1];

    // Encoder 2 (Buffer) 连线
    wire                      buf_aer_req;
    wire signed [TIME_W-1:0]  buf_aer_time;
    wire [D1_ADDR_W-1:0]      buf_aer_addr;
    wire                      buf_done_d2, buf_done_d3;
    reg                       buf_potential_wr_en;
    reg  [D1_ADDR_W-1:0]      buf_potential_wr_addr;
    reg  signed [ACC_W-1:0]   buf_potential_wr_data;
    reg                       buf_broadcast_start;
    reg  signed [TIME_W-1:0]  buf_t_max_layer;
    reg  [D1_ADDR_W-1:0]      buf_neuron_count;
    reg                       buf_aer_ack;
    wire [D1_ADDR_W-1:0]      buf_threshold_addr;
    
    // ArgMax 连线
    reg  signed [DENSE3_NEURONS*ACC_W-1:0] argmax_potentials_flat;
    reg                       argmax_i_valid;
    wire                      argmax_o_valid;
    wire [$clog2(DENSE3_NEURONS)-1:0] argmax_o_class;
    
    // AER MUX (选择信使)
    wire aer_req_mux  = (state == S_DENSE1_RUN) ? i_enc_aer_req : buf_aer_req;
    wire signed [TIME_W-1:0] aer_time_mux = (state == S_DENSE1_RUN) ? i_enc_aer_time : buf_aer_time;
    
    // AER 地址 MUX (带零扩展)
    wire [ADDR_W-1:0] aer_addr_mux_padded;
    assign aer_addr_mux_padded = (state == S_DENSE1_RUN) ? 
        i_enc_aer_addr :
        { {(ADDR_W - D1_ADDR_W){1'b0}}, buf_aer_addr };

    always @(*) begin
        buf_aer_ack = (state == S_DENSE2_RUN || state == S_DENSE3_RUN) ? 
                      (&array_aer_ack) : 1'b0;
    end
    
    always @(*) begin
        // 1. 设置默认值，防止产生锁存器 (latch)
        o_enc_aer_ack = 1'b0;
        buf_aer_ack = 1'b0;

        // 2. 根据状态进行 MUX 赋值
        if (state == S_DENSE1_RUN) begin
            o_enc_aer_ack = &array_aer_ack;
        end 
        else if (state == S_DENSE2_RUN || state == S_DENSE3_RUN) begin
            buf_aer_ack = &array_aer_ack;
        end
    end
    
    // --- 1. 例化 Intermediate Buffer Encoder (D1->D2, D2->D3) ---
    Intermediate_Buffer_Encoder #(
        .MAX_NEURONS ( DENSE1_NEURONS ),
        .POTENTIAL_W ( ACC_W ), .TIME_W ( TIME_W ),
        .ADDR_W      ( D1_ADDR_W ),
        .THRESHOLD_W ( WEIGHT_W ), .VJ_SHIFT_BITS( 16 ) // 示例
    ) buffer_encoder_inst (
        .local_clk ( local_clk ), .rst_n ( rst_n ),
        .i_clk_en  ( 1'b1 ), // (FSM 状态已控制)
        
        .i_potential_wr_en  ( buf_potential_wr_en ),
        .i_potential_wr_addr( buf_potential_wr_addr ),
        .i_potential_wr_data( buf_potential_wr_data ),
        
        .i_broadcast_start( buf_broadcast_start ),
        .i_t_max_layer    ( buf_t_max_layer ),
        .i_neuron_count   ( buf_neuron_count ),
        .o_broadcast_done ( (state == S_DENSE2_RUN) ? buf_done_d2 : buf_done_d3 ),
        
        .o_aer_req ( buf_aer_req ),
        .i_aer_ack ( buf_aer_ack ),
        .o_aer_time( buf_aer_time ),
        .o_aer_addr( buf_aer_addr ),
        
        .o_threshold_rom_addr( buf_threshold_addr ),
        .i_threshold_data    ( i_threshold_data )
    );
    
    // --- 2. 例化 16x RAM 和 16x Array ---
    genvar i;
    generate
        for (i = 0; i < NUM_ARRAYS; i = i + 1) begin : gen_snn_backend
            
            wire signed [31:0] ram_data_out;
            
            // ** 关键: 最终BRAM地址 = MUX后的地址 + FSM偏移量 **
            wire [ADDR_W-1:0]  final_bram_addr = aer_addr_mux_padded + current_bram_offset;
            
            SEE_Weight_BRAM #(
                .DATA_W(32), .ADDR_W(ADDR_W), .MEM_FILE("weights.mem")
            ) ram_inst (
                .clk ( local_clk ),
                .i_rd_en_a   ( array_clk_en[i] ),
                .i_rd_addr_a ( final_bram_addr ),
                .o_rd_data_a ( ram_data_out ),
                .i_wr_en_b   ( 1'b0 ), .i_wr_addr_b(0), .i_wr_data_b(0)
            );
            

            SNN_Array_4PE #(
                .TIME_W(TIME_W), .WEIGHT_W(WEIGHT_W), .ADDR_W(ADDR_W), .ACC_W(ACC_W)
            ) array_inst (
                .local_clk ( local_clk ), .rst_n ( rst_n ),
                .i_clk_en  ( array_clk_en[i] ),
                
                .i_aer_req  ( aer_req_mux ),
                .i_aer_time ( aer_time_mux ),
                .i_aer_addr ( aer_addr_mux_padded ),
                
                .i_t_min           ( current_t_min ),
                .i_pe_enable       ( array_pe_enable[i*4 +: 4] ),
                .i_reset_potential ( {4{array_reset_potential[i]}} ),
                
                .i_bram_data_32b ( ram_data_out ),
                
                .o_array_aer_ack ( array_aer_ack[i] ),
                .o_array_error   ( array_error[i] ),
                .o_array_busy    ( /* 未连接 */ ),
                
                .o_potential_flat( potentials_array_flat[i] )
            );
            
            // ** 关键: 解包 16x 阵列的 64x 电位 **
            genvar j;
            for (j = 0; j < 4; j = j + 1) begin
                assign potentials_unpacked[i*4 + j] = 
                    potentials_array_flat[i][(j+1)*ACC_W-1 -: j*ACC_W];
            end
        end
    endgenerate
    
    // --- 3. 例化 ArgMax (决策) ---
    ArgMax_Unit #(
        .VEC_LEN(DENSE3_NEURONS), .DATA_W(ACC_W)
    ) argmax_inst (
        .clk  ( local_clk ), .rst_n( rst_n ),
        .i_valid ( argmax_i_valid ),
        .i_potentials_flat ( argmax_potentials_flat ),
        .o_valid ( argmax_o_valid ),
        .o_predicted_class ( argmax_o_class )
    );

    // --- 4. GALS Master FSM (组合) ---
    integer k;
    always @(*) begin
        next_state = state;
        o_accelerator_done = 1'b0;
        o_predicted_class  = 0;
        
        // 默认值
        array_clk_en           = {NUM_ARRAYS{1'b0}};
        array_pe_enable        = {4*NUM_ARRAYS{1'b0}};
        current_bram_offset    = BRAM_OFFSET_D1;
        current_t_min          = T_MIN_D1_Q17;
        array_reset_potential  = {NUM_ARRAYS{1'b0}};
        
        buf_potential_wr_en   = 1'b0;
        buf_potential_wr_addr = 0;
        buf_potential_wr_data = 0;
        buf_broadcast_start   = 1'b0;
        buf_t_max_layer       = 0;
        buf_neuron_count      = 0;
        
        argmax_i_valid        = 1'b0;
        
        // FSM 状态转移
        case (state)
            S_IDLE: begin
                array_reset_potential = {NUM_ARRAYS{1'b1}};
                if (i_accelerator_start)
                    next_state = S_DENSE1_RUN;
            end
            
            S_DENSE1_RUN: begin
                // 启用 D1: 64 PEs (16 阵列)
                for (k = 0; k < DENSE1_NEURONS/4; k = k + 1)
                    array_clk_en[k] = 1'b1;
                array_pe_enable     = {4*NUM_ARRAYS{1'b1}};
                current_bram_offset = BRAM_OFFSET_D1;
                current_t_min       = T_MIN_D1_Q17;
                
                if (i_enc_done) // 等待 GALS_Encoder 完成
                    next_state = S_DENSE1_READ;
            end
            
            S_DENSE1_READ: begin
                // 读 D1 电位 (64次) -> Buffer
                buf_potential_wr_en   = 1'b1;
                buf_potential_wr_addr = rw_cnt;
                buf_potential_wr_data = potentials_unpacked[rw_cnt];
                
                if (rw_cnt == DENSE1_NEURONS - 1)
                    next_state = S_DENSE2_RUN;
            end

            S_DENSE2_RUN: begin
                // 启用 D2: 32 PEs (8 阵列)
                for (k = 0; k < DENSE2_NEURONS/4; k = k + 1)
                    array_clk_en[k] = 1'b1;
                for (k = 0; k < DENSE2_NEURONS; k = k + 1)
                    array_pe_enable[k] = 1'b1;
                    
                current_bram_offset = BRAM_OFFSET_D2;
                current_t_min       = T_MIN_D2_Q17;
                
                // 启动 Buffer 广播 D1 -> D2
                buf_broadcast_start = 1'b1;
                buf_t_max_layer     = T_MIN_D2_Q17; // t_max_d1 = t_min_d2
                buf_neuron_count    = DENSE1_NEURONS;
                
                if (buf_done_d2)
                    next_state = S_DENSE2_READ;
            end
            
            S_DENSE2_READ: begin
                // 读 D2 电位 (32次) -> Buffer
                buf_potential_wr_en   = 1'b1;
                buf_potential_wr_addr = rw_cnt;
                buf_potential_wr_data = potentials_unpacked[rw_cnt];
                
                if (rw_cnt == DENSE2_NEURONS - 1)
                    next_state = S_DENSE3_RUN;
            end

            S_DENSE3_RUN: begin
                // 启用 D3: 3 PEs (1 阵列)
                array_clk_en[0]     = 1'b1;
                array_pe_enable[0]  = 1'b1;
                array_pe_enable[1]  = 1'b1;
                array_pe_enable[2]  = 1'b1;
                
                current_bram_offset = BRAM_OFFSET_D3;
                current_t_min       = T_MIN_D3_Q17;
                
                // 启动 Buffer 广播 D2 -> D3
                buf_broadcast_start = 1'b1;
                buf_t_max_layer     = T_MIN_D3_Q17;
                buf_neuron_count    = DENSE2_NEURONS;
                
                if (buf_done_d3)
                    next_state = S_DENSE3_READ;
            end

            S_DENSE3_READ: begin
                // 读 D3 电位 (3次) -> 准备送入 ArgMax
                next_state = S_ARGMAX_REG;
            end
            
            S_ARGMAX_REG: begin
                // 时序修正: 寄存 ArgMax 的输入
                next_state = S_ARGMAX_WAIT;
            end

            S_ARGMAX_WAIT: begin
                argmax_i_valid = 1'b1; // 单周期脉冲
                if (argmax_o_valid)
                    next_state = S_DONE;
            end
            
            S_DONE: begin
                o_accelerator_done = 1'b1;
                o_predicted_class  = argmax_o_class;
                if (!i_accelerator_start)
                    next_state = S_IDLE;
            end
            
            S_ERROR: begin
                next_state = S_ERROR; // 停滞, 等待复位
            end
            
            default: next_state = S_IDLE;
        endcase
        
        if (|array_error) begin // 任何阵列出错
            next_state = S_ERROR;
        end
    end

    // --- 5. GALS Master FSM (时序) ---
    always @(posedge local_clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            rw_cnt <= 0;
            argmax_potentials_flat <= 0;
            argmax_i_valid <= 1'b0;
        end else begin
            state <= next_state;
            
            // FSM 计数器 (用于读电位)
            case (state)
                S_DENSE1_READ:
                    rw_cnt <= rw_cnt + 1;
                S_DENSE2_READ:
                    rw_cnt <= rw_cnt + 1;
                default:
                    rw_cnt <= 0;
            endcase
            
            // 时序修正: 寄存 ArgMax 的输入
            if (state == S_DENSE3_READ) begin
                 argmax_potentials_flat <= {
                    potentials_unpacked[2], 
                    potentials_unpacked[1], 
                    potentials_unpacked[0]
                 };
            end
            
            // 时序修正: ArgMax i_valid 单周期脉冲
            if (state == S_ARGMAX_WAIT) begin
                 argmax_i_valid <= 1'b1;
            end else begin
                 argmax_i_valid <= 1'b0;
            end
        end
    end

endmodule