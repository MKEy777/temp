`timescale 1ns/1ps
`default_nettype wire

module lif_unit #(
    parameter MEM_WIDTH   = 24, 
    parameter IN_WIDTH    = 18, 
    parameter V_TH        = 1000, 
    parameter TAU_SHIFT   = 2,
    parameter COUNT_WIDTH = 4
)(
    input  wire                     clk,
    input  wire                     rst_n,

    // 流水线控制
    input  wire                     valid_in,
    output reg                      valid_out,
    
    // 输入数据 (来自上一级)
    input  wire signed [IN_WIDTH-1:0]  i_in,      
    input  wire signed [MEM_WIDTH-1:0] v_old,     
    input  wire [COUNT_WIDTH-1:0]      cnt_old,   

    // 输出数据 (去往下一级)
    output reg  signed [IN_WIDTH-1:0]  i_out,     
    output reg  signed [MEM_WIDTH-1:0] v_new,     
    output reg  [COUNT_WIDTH-1:0]      cnt_new    
);

    // -----------------------------------------------------------
    // 组合逻辑: LIF 核心方程
    // -----------------------------------------------------------
    
    // 1. 漏电 (Leak)
    wire signed [MEM_WIDTH-1:0] v_decay;
    assign v_decay = v_old - (v_old >>> TAU_SHIFT);

    // 2. 积分 (Integrate)
    wire signed [MEM_WIDTH:0] v_sum;
    assign v_sum = {v_decay[MEM_WIDTH-1], v_decay} + 
                   {{(MEM_WIDTH-IN_WIDTH+1){i_in[IN_WIDTH-1]}}, i_in};

    // 3. 饱和截断 (Saturate)
    reg signed [MEM_WIDTH-1:0] v_sat;
    localparam signed [MEM_WIDTH-1:0] MAX_POS = {1'b0, {(MEM_WIDTH-1){1'b1}}};
    localparam signed [MEM_WIDTH-1:0] MIN_NEG = {1'b1, {(MEM_WIDTH-1){1'b0}}};

    always @(*) begin
        if (v_sum > MAX_POS) v_sat = MAX_POS;
        else if (v_sum < MIN_NEG) v_sat = MIN_NEG;
        else v_sat = v_sum[MEM_WIDTH-1:0];
    end

    // 4. 发放与复位 (Fire & Reset)
    wire fired;
    assign fired = (v_sat >= $signed(V_TH));

    wire signed [MEM_WIDTH-1:0] v_reset_val;
    assign v_reset_val = fired ? (v_sat - $signed(V_TH)) : v_sat;

    // -----------------------------------------------------------
    // 时序逻辑: 流水线寄存器
    // -----------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_out <= 0;
            i_out     <= 0;
            v_new     <= 0;
            cnt_new   <= 0;
        end else begin
            valid_out <= valid_in;
            
            // 数据打拍 (Pipeline Register Update)
            if (valid_in) begin
                i_out     <= i_in;        // 电流继续向下传
                v_new     <= v_reset_val; // 更新膜电位
                cnt_new   <= cnt_old + (fired ? 1'b1 : 1'b0); // 累加计数
            end
        end
    end

endmodule