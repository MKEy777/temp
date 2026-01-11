`timescale 1ns/1ps
`default_nettype wire

module lif_layer #(
    parameter MEM_WIDTH   = 24, 
    parameter IN_WIDTH    = 18, 
    parameter V_TH        = 1000, 
    parameter TAU_SHIFT   = 2,
    parameter COUNT_WIDTH = 4,
    parameter T_STEPS     = 4   
)(
    input  wire                     clk,
    input  wire                     rst_n,

    // 输入流 (像素流)
    input  wire [IN_WIDTH-1 : 0]    din,
    input  wire                     din_valid,
    output wire                     din_ready, 

    // 输出流 (脉冲计数流)
    output wire [COUNT_WIDTH-1 : 0] spike_out,
    output wire                     dout_valid,
    input  wire                     dout_ready
);

    assign din_ready = dout_ready;

    // -----------------------------------------------------------
    // 内部连线定义
    // -----------------------------------------------------------
    
    wire signed [IN_WIDTH-1:0]  chain_i   [0:T_STEPS];
    wire signed [MEM_WIDTH-1:0] chain_v   [0:T_STEPS];
    wire [COUNT_WIDTH-1:0]      chain_cnt [0:T_STEPS];
    wire                        chain_val [0:T_STEPS];

    // -----------------------------------------------------------
    // 1. 头部初始化 (Head Initialization)
    // -----------------------------------------------------------
    
    assign chain_i[0]   = $signed(din);
    assign chain_v[0]   = {MEM_WIDTH{1'b0}};   // 初始膜电位 = 0
    assign chain_cnt[0] = {COUNT_WIDTH{1'b0}}; // 初始计数 = 0
    assign chain_val[0] = din_valid && dout_ready; // 简单的门控

    // -----------------------------------------------------------
    // 2. 自动实例化流水线链 (Pipeline Generation)
    // -----------------------------------------------------------
    genvar k;
    generate
        for (k = 0; k < T_STEPS; k = k + 1) begin : gen_stages
            
            lif_unit #(
                .MEM_WIDTH   (MEM_WIDTH),
                .IN_WIDTH    (IN_WIDTH),
                .V_TH        (V_TH),
                .TAU_SHIFT   (TAU_SHIFT),
                .COUNT_WIDTH (COUNT_WIDTH)
            ) u_stage (
                .clk       (clk),
                .rst_n     (rst_n),
                
                // 输入来自 k
                .valid_in  (chain_val[k]),
                .i_in      (chain_i[k]),
                .v_old     (chain_v[k]),
                .cnt_old   (chain_cnt[k]),
                
                // 输出送往 k+1
                .valid_out (chain_val[k+1]),
                .i_out     (chain_i[k+1]),
                .v_new     (chain_v[k+1]),
                .cnt_new   (chain_cnt[k+1])
            );
        end
    endgenerate
    
    assign spike_out  = chain_cnt[T_STEPS];
    assign dout_valid = chain_val[T_STEPS];

endmodule