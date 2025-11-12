`timescale 1ns / 1ps

/*
 * ???: SNN_Engine [?????]
 * ????: SNN ??? GALS Master FSM (?????)??
 * ???:
 * 1. [Bug 2] ????????? SNN ??? (D_i) ROM??
 * 2. [Bug 3] ???????¦Ë??? (unpacker) 
 * generate ???§Ö?¦Ë????????????
 */
module SNN_Engine #(
    // --- ???? Q1.7 ???? ---
    parameter TIME_W      = 8,
    parameter WEIGHT_W    = 8,
    parameter ACC_W       = 32,
    parameter ADDR_W      = 10, // SNN ????(160) + ????????(224) < 1024
    
    // --- ??????? ---
    parameter NUM_ARRAYS    = 16, // 16 ???? = 64 PEs
    
    // --- ???????? (160 -> 64 -> 32 -> 3) ---
    parameter SNN_IN_LEN     = 160,
    parameter DENSE1_NEURONS = 64,
    parameter DENSE2_NEURONS = 32,
    parameter DENSE3_NEURONS = 3,
    
    // --- ??? BRAM ????? (???? SNN ????) ---
    parameter BRAM_OFFSET_D1 = 10'd0,
    parameter BRAM_OFFSET_D2 = 10'd160, // D1 ??? = D1 ???? (160)
    parameter BRAM_OFFSET_D3 = 10'd224, // D2 ??? = 160 + D1 ??? (64)

    // --- t_min (Q1.7 ????) ---
    parameter signed [TIME_W-1:0] T_MIN_D1_Q17 = 8'd0,
    parameter signed [TIME_W-1:0] T_MIN_D2_Q17 = 8'd20,
    parameter signed [TIME_W-1:0] T_MIN_D3_Q17 = 8'd40
)(
    input  wire                      local_clk, // SNN ??????????
    input  wire                      rst_n,

    // --- ??????? ---
    input  wire                      i_accelerator_start, // ???? SNN
    output reg                       o_accelerator_done,
    output reg [$clog2(DENSE3_NEURONS)-1:0] o_predicted_class,

    // --- ???: GALS_Encoder_Unit (??? 1) ---
    input  wire                      i_enc_aer_req,    // (???? ANN->SNN Encoder)
    input  wire signed [TIME_W-1:0]  i_enc_aer_time,
    input  wire [ADDR_W-1:0]         i_enc_aer_addr,   // (??????????? ADDR_W)
    input  wire                      i_enc_done,
    output reg                       o_enc_aer_ack

    // --- ???: Threshold (D_i) ROM ---
    // [???Bug 2] ??? i_threshold_data ??????????????
    // input  wire signed [WEIGHT_W-1:0] i_threshold_data
);
    localparam D1_ADDR_W = $clog2(DENSE1_NEURONS); // 6
    localparam D2_ADDR_W = $clog2(DENSE2_NEURONS); // 5

    // GALS Master FSM ??
    localparam S_IDLE        = 5'b00000;
    localparam S_DENSE1_RUN  = 5'b00001;
    localparam S_DENSE1_READ = 5'b00010; // ?? D1 ??¦Ë (64??)
    localparam S_DENSE2_RUN  = 5'b00100;
    localparam S_DENSE2_READ = 5'b00101; // ?? D2 ??¦Ë (32??)
    localparam S_DENSE3_RUN  = 5'b01000;
    localparam S_DENSE3_READ = 5'b01001; // ?? D3 ??¦Ë (3??)
    localparam S_ARGMAX_REG  = 5'b01010; // ??? ArgMax ????
    localparam S_ARGMAX_WAIT = 5'b01100;
    localparam S_DONE        = 5'b01101;
    localparam S_ERROR       = 5'b10000;
    
    reg [4:0] state, next_state;

    // --- ????????????? ---
    reg  [NUM_ARRAYS-1:0]    array_clk_en;
    reg  [4*NUM_ARRAYS-1:0]  array_pe_enable;
    reg  [ADDR_W-1:0]        current_bram_offset;
    reg  signed [TIME_W-1:0] current_t_min;
    reg  [NUM_ARRAYS-1:0]    array_reset_potential;
    
    wire [NUM_ARRAYS-1:0]     array_aer_ack;
    wire [NUM_ARRAYS-1:0]     array_error;
    
    // ??/§Õ FSM ??????
    reg  [D1_ADDR_W-1:0]     rw_cnt; // (0-63)
    
    // SNN_Array_4PE ??? (16 ?? [4*ACC_W] ????????)
    wire signed [4*ACC_W-1:0] potentials_array_flat [0:NUM_ARRAYS-1];
    // ?????? 64 ?? 32-bit ??¦Ë
    wire signed [ACC_W-1:0]   potentials_unpacked [0:NUM_ARRAYS*4-1];

    // Encoder 2 (Buffer) ????
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
    
    // [???Bug 2] ????: SNN ??? ROM ????
    wire signed [WEIGHT_W-1:0] threshold_data_wire;
    
    // ArgMax ????
    reg  signed [DENSE3_NEURONS*ACC_W-1:0] argmax_potentials_flat;
    reg                       argmax_i_valid;
    wire                      argmax_o_valid;
    wire [$clog2(DENSE3_NEURONS)-1:0] argmax_o_class;
    
    // AER MUX (??????)
    wire aer_req_mux  = (state == S_DENSE1_RUN) ? i_enc_aer_req : buf_aer_req;
    wire signed [TIME_W-1:0] aer_time_mux = (state == S_DENSE1_RUN) ? i_enc_aer_time : buf_aer_time;
    
    // AER ??? MUX (???????)
    wire [ADDR_W-1:0] aer_addr_mux_padded;
    assign aer_addr_mux_padded = (state == S_DENSE1_RUN) ? 
        i_enc_aer_addr :
        { {(ADDR_W - D1_ADDR_W){1'b0}}, buf_aer_addr };

    always @(*) begin
        buf_aer_ack = (state == S_DENSE2_RUN || state == S_DENSE3_RUN) ? 
                      (&array_aer_ack) : 1'b0;
    end
    
    always @(*) begin
        // 1. ??????????????????????? (latch)
        o_enc_aer_ack = 1'b0;
        buf_aer_ack = 1'b0;

        // 2. ?????????? MUX ???
        if (state == S_DENSE1_RUN) begin
            o_enc_aer_ack = &array_aer_ack;
        end 
        else if (state == S_DENSE2_RUN || state == S_DENSE3_RUN) begin
            buf_aer_ack = &array_aer_ack;
        end
    end
    
    // --- [???Bug 2] 1. ???? SNN ??? (D_i) ROM ---
    Parameter_ROM #(
        .DATA_WIDTH ( WEIGHT_W ),  // 8-bit
        .ADDR_WIDTH ( D1_ADDR_W ), // 6-bit (0-63)
        .MEM_FILE   ( "snn_thresholds.mem" ) // ?????ROM???
    ) threshold_rom_inst (
        .clk        ( local_clk ),
        .addr       ( buf_threshold_addr ), // ?? Buffer Encoder ????
        .data_out   ( threshold_data_wire ) // ????? Buffer Encoder
    );

    // --- 2. ???? Intermediate Buffer Encoder (D1->D2, D2->D3) ---
    Intermediate_Buffer_Encoder #(
        .MAX_NEURONS ( DENSE1_NEURONS ),
        .POTENTIAL_W ( ACC_W ), .TIME_W ( TIME_W ),
        .ADDR_W      ( D1_ADDR_W ),
        .THRESHOLD_W ( WEIGHT_W ), .VJ_SHIFT_BITS( 16 ) // ???
    ) buffer_encoder_inst (
        .local_clk ( local_clk ), .rst_n ( rst_n ),
        .i_clk_en  ( 1'b1 ), // (FSM ???????)
        
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
        
        .o_threshold_rom_addr( buf_threshold_addr ), // ????? ROM
        .i_threshold_data    ( threshold_data_wire ) // [???Bug 2]
    );
    
    // --- 3. ???? 16x RAM ?? 16x Array ---
    genvar i;
    generate
        for (i = 0; i < NUM_ARRAYS; i = i + 1) begin : gen_snn_backend
            
            wire signed [31:0] ram_data_out;
            
            // ** ???: ????BRAM??? = MUX????? + FSM????? **
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
                .o_array_busy    ( /* ¦Ä???? */ ),
                
                .o_potential_flat( potentials_array_flat[i] )
            );
            
            // ** ???: ??? 16x ???§Ö? 64x ??¦Ë **
            genvar j;
            for (j = 0; j < 4; j = j + 1) begin
                // [???Bug 3] ????? j*ACC_W ????? ACC_W
                assign potentials_unpacked[i*4 + j] = 
                    potentials_array_flat[i][(j+1)*ACC_W-1 -: ACC_W];
            end
        end
    endgenerate
    
    // --- 4. ???? ArgMax (????) ---
    ArgMax_Unit #(
        .VEC_LEN(DENSE3_NEURONS), .DATA_W(ACC_W)
    ) argmax_inst (
        .clk  ( local_clk ), .rst_n( rst_n ),
        .i_valid ( argmax_i_valid ),
        .i_potentials_flat ( argmax_potentials_flat ),
        .o_valid ( argmax_o_valid ),
        .o_predicted_class ( argmax_o_class )
    );

    // --- 5. GALS Master FSM (???) ---
    integer k;
    always @(*) begin
        next_state = state;
        o_accelerator_done = 1'b0;
        o_predicted_class  = 0;
        
        // ????
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
        
        // FSM ?????
        case (state)
            S_IDLE: begin
                array_reset_potential = {NUM_ARRAYS{1'b1}};
                if (i_accelerator_start)
                    next_state = S_DENSE1_RUN;
            end
            
            S_DENSE1_RUN: begin
                // ???? D1: 64 PEs (16 ????)
                for (k = 0; k < DENSE1_NEURONS/4; k = k + 1)
                    array_clk_en[k] = 1'b1;
                array_pe_enable     = {4*NUM_ARRAYS{1'b1}};
                current_bram_offset = BRAM_OFFSET_D1;
                current_t_min       = T_MIN_D1_Q17;
                
                if (i_enc_done) // ??? GALS_Encoder ???
                    next_state = S_DENSE1_READ;
            end
            
            S_DENSE1_READ: begin
                // ?? D1 ??¦Ë (64??) -> Buffer
                buf_potential_wr_en   = 1'b1;
                buf_potential_wr_addr = rw_cnt;
                buf_potential_wr_data = potentials_unpacked[rw_cnt];
                
                if (rw_cnt == DENSE1_NEURONS - 1)
                    next_state = S_DENSE2_RUN;
            end

            S_DENSE2_RUN: begin
                // ???? D2: 32 PEs (8 ????)
                for (k = 0; k < DENSE2_NEURONS/4; k = k + 1)
                    array_clk_en[k] = 1'b1;
                for (k = 0; k < DENSE2_NEURONS; k = k + 1)
                    array_pe_enable[k] = 1'b1;
                    
                current_bram_offset = BRAM_OFFSET_D2;
                current_t_min       = T_MIN_D2_Q17;
                
                // ???? Buffer ?? D1 -> D2
                buf_broadcast_start = 1'b1;
                buf_t_max_layer     = T_MIN_D2_Q17; // t_max_d1 = t_min_d2
                buf_neuron_count    = DENSE1_NEURONS;
                
                if (buf_done_d2)
                    next_state = S_DENSE2_READ;
            end
            
            S_DENSE2_READ: begin
                // ?? D2 ??¦Ë (32??) -> Buffer
                buf_potential_wr_en   = 1'b1;
                buf_potential_wr_addr = rw_cnt;
                buf_potential_wr_data = potentials_unpacked[rw_cnt];
                
                if (rw_cnt == DENSE2_NEURONS - 1)
                    next_state = S_DENSE3_RUN;
            end

            S_DENSE3_RUN: begin
                // ???? D3: 3 PEs (1 ????)
                array_clk_en[0]     = 1'b1;
                array_pe_enable[0]  = 1'b1;
                array_pe_enable[1]  = 1'b1;
                array_pe_enable[2]  = 1'b1;
                
                current_bram_offset = BRAM_OFFSET_D3;
                current_t_min       = T_MIN_D3_Q17;
                
                // ???? Buffer ?? D2 -> D3
                buf_broadcast_start = 1'b1;
                buf_t_max_layer     = T_MIN_D3_Q17;
                buf_neuron_count    = DENSE2_NEURONS;
                
                if (buf_done_d3)
                    next_state = S_DENSE3_READ;
            end

            S_DENSE3_READ: begin
                // ?? D3 ??¦Ë (3??) -> ??????? ArgMax
                next_state = S_ARGMAX_REG;
            end
            
            S_ARGMAX_REG: begin
                // ???????: ??? ArgMax ??????
                next_state = S_ARGMAX_WAIT;
            end

            S_ARGMAX_WAIT: begin
                argmax_i_valid = 1'b1; // ??????????
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
                next_state = S_ERROR; // ???, ?????¦Ë
            end
            
            default: next_state = S_IDLE;
        endcase
        
        if (|array_error) begin // ?¦Ê????§Ô???
            next_state = S_ERROR;
        end
    end

    // --- 6. GALS Master FSM (???) ---
    always @(posedge local_clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            rw_cnt <= 0;
            argmax_potentials_flat <= 0;
            argmax_i_valid <= 1'b0;
        end else begin
            state <= next_state;
            
            // FSM ?????? (???????¦Ë)
            case (state)
                S_DENSE1_READ:
                    rw_cnt <= rw_cnt + 1;
                S_DENSE2_READ:
                    rw_cnt <= rw_cnt + 1;
                default:
                    rw_cnt <= 0;
            endcase
            
            // ???????: ??? ArgMax ??????
            if (state == S_DENSE3_READ) begin
                 argmax_potentials_flat <= {
                    potentials_unpacked[2], 
                    potentials_unpacked[1], 
                    potentials_unpacked[0]
                 };
            end
            
            // ???????: ArgMax i_valid ??????????
            if (state == S_ARGMAX_WAIT) begin
                 argmax_i_valid <= 1'b1;
            end else begin
                 argmax_i_valid <= 1'b0;
            end
        end
    end

endmodule