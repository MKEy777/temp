`timescale 1ns/1ps
`default_nettype wire

module conv3x3_engine #(
    parameter IMG_WIDTH = 32,
    parameter IMG_HEIGHT = 32,
    parameter DATA_WIDTH = 8,
    parameter WGT_WIDTH = 8,
    parameter OUT_WIDTH = 20 
)(
    input  wire                    clk,
    input  wire                    rst_n,
    
    // 输入数据流
    input  wire [DATA_WIDTH-1:0]   din,
    input  wire                    din_valid,
    output wire                    din_ready,
    
    // 输出卷积结果 (无偏置)
    output wire [OUT_WIDTH-1:0]    dout,
    output wire                    dout_valid,
    input  wire                    dout_ready,
    
    // 配置接口
    input  wire [WGT_WIDTH*9-1:0]  weight_config,
    input  wire                    config_en
);

    // 内部信号
    wire [DATA_WIDTH*9-1:0] window_data_flat;
    wire                    window_valid;
    wire                    init_done;
    wire [WGT_WIDTH*9-1:0]  weights_flat; 
    
    reg  signed [WGT_WIDTH-1:0]    weights_reg [8:0]; 
    wire signed [OUT_WIDTH-1:0]    mac_result;
    wire                           mac_valid;

    integer j;

    // 1. 权重配置 
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (j = 0; j < 9; j = j + 1) weights_reg[j] <= 0;
        end else if (config_en) begin
            for (j = 0; j < 9; j = j + 1) 
                weights_reg[j] <= $signed(weight_config[j*WGT_WIDTH +: WGT_WIDTH]);
        end
    end

    // 权重打包
    genvar k;
    generate
        for (k = 0; k < 9; k = k + 1) begin : pack_weights
            assign weights_flat[k*WGT_WIDTH +: WGT_WIDTH] = weights_reg[k];
        end
    endgenerate

    // 2. 行缓存 (Line Buffer)
    conv_linebuf_3x3 #(
        .DATA_WIDTH(DATA_WIDTH),
        .IMG_WIDTH(IMG_WIDTH),
        .IMG_HEIGHT(IMG_HEIGHT)
    ) u_conv_linebuf_3x3 (
        .clk(clk),
        .rst_n(rst_n),
        .data_in(din),
        .data_valid(din_valid),
        .data_ready(din_ready),
        .window_out(window_data_flat), 
        .window_valid(window_valid),
        .init_done(init_done) 
    );

    // 3. 乘加阵列 (MAC Array)
    mac_array #(
        .DATA_WIDTH(DATA_WIDTH),
        .WGT_WIDTH(WGT_WIDTH),
        .OUT_WIDTH(OUT_WIDTH)
    ) u_mac_array (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(window_valid),
        .window_data(window_data_flat), 
        .weights(weights_flat),         
        .mac_out(mac_result),
        .valid_out(mac_valid)
    );

    assign dout = mac_result;
    assign dout_valid = mac_valid;
    
endmodule