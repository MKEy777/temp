`timescale 1ns/1ps
`default_nettype wire

module ocp_conv_engine_rom #(
    parameter OUT_CHANNELS = 32,   
    parameter IN_CHANNELS  = 256,   
    parameter IMG_WIDTH    = 32,
    parameter IMG_HEIGHT   = 32,
    parameter DATA_WIDTH   = 8,
    parameter WGT_WIDTH    = 8,
    parameter OUT_WIDTH    = 20,
    parameter INPUT_IS_SIGNED = 0
)(
    input  wire                    clk,
    input  wire                    rst_n,

    // 图像流输入
    input  wire [DATA_WIDTH-1:0]   din,
    input  wire                    din_valid,
    output wire                    din_ready,

    // 权重ROM地址 (对应当前的输入通道索引 0 ~ IN_CHANNELS-1)
    // 在处理完一张图的所有像素前，该地址保持不变
    input  wire [$clog2(IN_CHANNELS)-1:0] rom_addr,

    // 累加输入 (Partial Sum)
    input  wire [OUT_CHANNELS*OUT_WIDTH-1:0] psum_in,

    // 结果输出
    output wire [OUT_CHANNELS*OUT_WIDTH-1:0] dout,
    output wire                    dout_valid
);

    //==============================================================
    // 1. 权重 ROM (替换了原有的配置逻辑)
    //==============================================================
    // 总位宽: 输出通道数 * 3x3 * 权重位宽
    localparam ROM_DATA_W = OUT_CHANNELS * 9 * WGT_WIDTH;
    
    wire [ROM_DATA_W-1:0] rom_q;

    // 权重数据量较大，综合工具通常会映射为 BRAM 或 Distributed RAM
    weight_rom #(
        .ADDR_WIDTH($clog2(IN_CHANNELS)),
        .DATA_WIDTH(ROM_DATA_W)
    ) u_weight_rom (
        .clk (clk),
        .addr(rom_addr),
        .q   (rom_q)
    );

    //==============================================================
    // 2. 共享行缓存
    //==============================================================
    wire [DATA_WIDTH*9-1:0] shared_window;
    wire                    shared_window_valid;

    conv_linebuf_3x3 #(
        .DATA_WIDTH(DATA_WIDTH),
        .IMG_WIDTH (IMG_WIDTH),
        .IMG_HEIGHT(IMG_HEIGHT)
    ) u_shared_linebuf (
        .clk         (clk),
        .rst_n       (rst_n),
        .data_in     (din),
        .data_valid  (din_valid),
        .data_ready  (din_ready),
        .window_out  (shared_window),
        .window_valid(shared_window_valid),
        .init_done   () 
    );

    //==============================================================
    // 3. 权重解包与 MAC 阵列
    //==============================================================
    wire [9*WGT_WIDTH-1:0] wgt_unpacked [OUT_CHANNELS-1:0];
    wire [OUT_WIDTH-1:0]   mac_results  [OUT_CHANNELS-1:0];
    wire [OUT_CHANNELS-1:0] mac_valids;
    
    genvar i;
    generate
        for (i = 0; i < OUT_CHANNELS; i = i + 1) begin : mac_units
            assign wgt_unpacked[i] = rom_q[i*9*WGT_WIDTH +: 9*WGT_WIDTH];

            mac_array #(
                .DATA_WIDTH     (DATA_WIDTH),
                .WGT_WIDTH      (WGT_WIDTH),
                .OUT_WIDTH      (OUT_WIDTH),
                .INPUT_IS_SIGNED(INPUT_IS_SIGNED)
            ) u_mac_core (
                .clk        (clk),
                .rst_n      (rst_n),
                .valid_in   (shared_window_valid),
                .window_data(shared_window),
                .weights    (wgt_unpacked[i]), 
                .mac_out    (mac_results[i]),
                .valid_out  (mac_valids[i])
            );
        end
    endgenerate

    //==============================================================
    // 4. 累加与输出
    //==============================================================
    wire [OUT_WIDTH-1:0] psum_unpacked [OUT_CHANNELS-1:0];
    wire [OUT_WIDTH-1:0] final_result  [OUT_CHANNELS-1:0];

    generate
        for (i = 0; i < OUT_CHANNELS; i = i + 1) begin : acc_loop
            assign psum_unpacked[i] = psum_in[i*OUT_WIDTH +: OUT_WIDTH];
            assign final_result[i]  = mac_results[i] + psum_unpacked[i];
            assign dout[i*OUT_WIDTH +: OUT_WIDTH] = final_result[i];
        end
    endgenerate

    assign dout_valid = mac_valids[0];

endmodule