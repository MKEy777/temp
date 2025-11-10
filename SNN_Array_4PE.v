`timescale 1ns / 1ps

/*
 * 模块: SNN_Array_4PE [重构版]
 * 功能: 4-PE 处理阵列
 * 职责:
 * 1. 例化 4 x PE_GALS_Wrapper (使用 CE)。
 * 2. 例化 1 x GALS_Collector_Unit。
 * 3. 实现 32-bit -> 4x 8-bit 权重解包器。
 * 4. [已移除] BRAM 地址偏移量相加。
 */
module SNN_Array_4PE #(
    parameter TIME_W   = 8,
    parameter WEIGHT_W = 8,
    parameter ADDR_W   = 10, // SNN 输入维度(160) + 偏移量
    parameter ACC_W    = 32
)(
    input  wire                 local_clk,
    input  wire                 rst_n,
    input  wire                 i_clk_en, // ** 新增: 阵列级时钟使能 **

    // GALS 事件总线 (广播)
    input  wire                 i_aer_req,
    input  wire signed [TIME_W-1:0] i_aer_time,
    input  wire [ADDR_W-1:0]        i_aer_addr,
    
    // SNN FSM 控制参数
    // [已移除] i_bram_addr_offset
    input  wire signed [TIME_W-1:0] i_t_min,
    input  wire [3:0]               i_pe_enable,       // (PE 级时钟使能)
    input  wire [3:0]               i_reset_potential,
    
    // 专属 BRAM 接口 (32-bit 宽)
    output wire                 o_bram_en,
    // [已移除] o_bram_addr
    input  wire signed [31:0]   i_bram_data_32b,

    // GALS 握手 (-> SNN_Engine)
    output wire                 o_array_aer_ack,
    output wire                 o_array_error, // (暴露 Collector 状态)
    output wire                 o_array_busy,  // (暴露 Collector 状态)

    // 电位输出 (-> SNN_Engine)
    output wire signed [4*ACC_W-1:0] o_potential_flat
);

    // 内部连线
    wire [3:0] pe_done_reqs;
    wire [3:0] pe_done_acks;
    wire [3:0] pe_bram_en_vec; // (来自 4 个 PE 的 en 信号)

    // ** 关键: 32-bit -> 4x 8-bit 权重解包器 **
    wire signed [WEIGHT_W-1:0] pe_weights [0:3]; 
    assign pe_weights[0] = i_bram_data_32b[ 7: 0]; // PE0 (LSB)
    assign pe_weights[1] = i_bram_data_32b[15: 8]; // PE1
    assign pe_weights[2] = i_bram_data_32b[23:16]; // PE2
    assign pe_weights[3] = i_bram_data_32b[31:24]; // PE3 (MSB)
    
    // --- 1. 例化 4-PE 阵列 (使用重构后的 PE) ---
    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : gen_pe_array
            
            // ** 实例化重构后的 PE (有 i_clk_en) **
            PE_GALS_Wrapper #(
                .TIME_W   ( TIME_W   ),
                .WEIGHT_W ( WEIGHT_W ),
                .ADDR_W   ( ADDR_W   ),
                .ACC_W    ( ACC_W    )
            ) pe_inst (
                .local_clk ( local_clk ),
                .rst_n     ( rst_n ),
                
                // ** 关键: 传递组合后的时钟使能 **
                .i_clk_en  ( i_clk_en & i_pe_enable[i] ),
                
                .i_aer_req   ( i_aer_req ),
                .i_aer_time  ( i_aer_time ),
                .i_aer_addr  ( i_aer_addr ), // 地址直接透传
                .i_t_min     ( i_t_min ),
                
                .o_done_req ( pe_done_reqs[i] ),
                .i_done_ack ( pe_done_acks[i] ),
                
                .o_bram_en   ( pe_bram_en_vec[i] ),
                .i_bram_data ( pe_weights[i] ), // 连接解包后的 8-bit 权重
                
                .i_reset_potential ( i_reset_potential[i] ),
                .o_potential_j     ( o_potential_flat[(i+1)*ACC_W-1 -: ACC_W] )
            );
        end
    endgenerate

    // --- 汇总 BRAM 请求 ---
    
    // [已移除] 地址计算 (由 SNN_Engine 处理)
    // assign o_bram_addr = i_aer_addr + i_bram_addr_offset; 
    
    // 任何一个活动的PE都可以触发BRAM读取
    assign o_bram_en = pe_bram_en_vec[0] | pe_bram_en_vec[1] |
                       pe_bram_en_vec[2] | pe_bram_en_vec[3];

    // --- 2. 例化 GALS Collector (使用你提供的版本) ---
    GALS_Collector_Unit #(
        .OUT_NEURONS ( 4 ),
        .WATCHDOG_TIMEOUT ( 10000 )
    ) collector_inst (
        .local_clk ( local_clk ),
        .rst_n     ( rst_n ),
        
        .i_aer_req ( i_aer_req ),
        .o_aer_ack ( o_array_aer_ack ),
        
        .i_pe_done_req_vec ( pe_done_reqs ),
        .o_pe_done_ack_vec ( pe_done_acks ),
        .o_error ( o_array_error ),
        .o_busy  ( o_array_busy )
    );

endmodule