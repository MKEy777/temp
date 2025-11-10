`timescale 1ns / 1ps

/*
 * 模块: channel_wise_mean_unit
 * 功能: 实现 torch.mean(x, dim=1) (跨通道均值)
 * 行为: 串行累加 IN_CH 个输入, 然后除以 IN_CH (右移)
 * 用于: Spatial_Gate_Unit (C2.3)
 */
module channel_wise_mean_unit #(
    parameter DATA_W = 8,
    parameter IN_CH  = 8, // 例如: C2.3 的输入通道数
    parameter ACC_W  = 32
) (
    input wire                      clk,
    input wire                      rst_n,
    input wire                      i_valid,
    input wire signed [DATA_W-1:0]  i_data,
    
    output reg signed [DATA_W-1:0] o_data,
    output reg                      o_valid
);
    // SHIFT_BITS = log2(IN_CH)
    localparam SHIFT_BITS = $clog2(IN_CH); 
    
    // -- FSM 状态定义 --
    localparam S_IDLE       = 2'b00;
    localparam S_ACCUMULATE = 2'b01;
    localparam S_OUTPUT     = 2'b10;

    reg [1:0] state;
    reg [$clog2(IN_CH)-1:0] ch_cnt;
    reg signed [ACC_W-1:0]  acc_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= S_IDLE;
            ch_cnt  <= 0;
            acc_reg <= {ACC_W{1'b0}};
            o_data  <= {DATA_W{1'b0}};
            o_valid <= 1'b0;
        end else begin
            // 默认输出无效
            o_valid <= 1'b0;
            
            case (state)
                S_IDLE: begin
                    if (i_valid) begin
                        // 收到第一个通道的数据
                        acc_reg <= $signed(i_data);
                        ch_cnt  <= 1;
                        state   <= S_ACCUMULATE;
                    end
                end
                
                S_ACCUMULATE: begin
                    if (i_valid) begin
                        // 累加后续通道的数据
                        acc_reg <= acc_reg + $signed(i_data);
                        
                        if (ch_cnt == IN_CH - 1) begin
                            // 最后一个通道数据已累加
                            ch_cnt <= 0;
                            state  <= S_OUTPUT;
                        end else begin
                            ch_cnt <= ch_cnt + 1;
                        end
                    end
                end
                
                S_OUTPUT: begin
                    // 输出均值 (累加结果 / IN_CH)
                    // 使用算术右移 (>>>)
                    o_data  <= $signed(acc_reg) >>> SHIFT_BITS;
                    o_valid <= 1'b1;
                    state   <= S_IDLE;
                end
                
                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule