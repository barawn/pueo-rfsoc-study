`timescale 1ns / 1ps
`include "dsp_macros.vh"
// Takes the raw RFSoC inputs and rescales. Basically creating
// a digital FADC. For a 3 bit FADC, we have
// +/-3.5, +/-2.5, +/-1.5, +/- 0.5.
// However, all of these are symmetric, so we just preserve
// the sign bit. Meaning we actually only need 3 thresholds,
// at +1, +2, and +3.
// This puts the central values at +/-0.5, +/-1.5, +/-2.5 (and then 7/0 are clamp outputs).
//
// Each sample needs 0.75 DSPs, and we have 8 channels.
// So each of these uses 6 DSPs, or 48 for the whole set.
//
// I can't think of an easy way to avoid the sign flip, I don't think it's possible.
module digital_rescale #(parameter NSAMP=8, parameter NBITS=12)(
        input [NSAMP*NBITS-1:0] din,
        input                   clk,
        input [10:0]            thresh1,
        input [10:0]            thresh2,
        input [10:0]            thresh3,
        input                   en_thresh,
        output [NSAMP*3-1:0]    dout
    );
    // Storage registers for input thresholds. These might end up being duplicated.
    reg [10:0] thresh1_reg = {11{1'b0}};
    reg [10:0] thresh2_reg = {11{1'b0}};
    reg [10:0] thresh3_reg = {11{1'b0}};
    // Sign storage (first stage). 
    reg [NSAMP-1:0] sign = {NSAMP{1'b0}};
    reg [NSAMP-1:0] sign_inreg = {NSAMP{1'b0}};
    reg [NSAMP-1:0] sign_outreg = {NSAMP{1'b0}};
    // These are the sign-flipped inputs.  
    reg [NSAMP*(NBITS-1)-1:0] abs_din = {(NSAMP*(NBITS-1)){1'b0}};

    // DSP inputs
    wire [NBITS-1:0] dsp_din[NSAMP-1:0];
    wire [NBITS-1:0] dsp_thr[2:0][NSAMP-1:0];
    // thermometer-encoded outputs
    wire [2:0] therm_code[7:0];            

    // these are the re-encoded outputs
    reg [NSAMP*3-1:0] dout_enc = {(NSAMP*3){1'b0}};

    localparam [6:0] OPMODE = { `Z_OPMODE_C, `Y_OPMODE_0, `X_OPMODE_AB };
    localparam [3:0] ALUMODE = `ALUMODE_SUM_ZXYCIN;
    localparam [2:0] CARRYINSEL = `CARRYINSEL_CARRYIN;
    // Our thresholds (written in *negative!*) go into Z,
    // and our inputs go in to X.
    // If the input's negative, we flip the bits and
    // both of the low bits are 1, for the 2's complement conversion.
    always @(posedge clk) begin
        if (en_thresh) begin
            thresh1_reg <= thresh1;
            thresh2_reg <= thresh2;
            thresh3_reg <= thresh3;
        end
    end
    generate
        genvar i,j,k;
        for (i=0;i<NSAMP;i=i+1) begin : LP
            wire sample_is_negative;
            assign sample_is_negative = din[NBITS*i + NBITS - 1];
            always @(posedge clk) begin : LP
                sign[i] <= sample_is_negative;
                sign_inreg[i] <= sign[i];
                sign_outreg[i] <= sign_inreg[i];
                if (sample_is_negative) begin
                    abs_din[(NBITS-1)*i +: (NBITS-1)] <= ~din[NBITS*i +: (NBITS-1)];
                end else begin
                    abs_din[(NBITS-1)*i +: (NBITS-1)] <= din[NBITS*i +: (NBITS-1)];
                end
                // Now our encoding goes
                // therm    sign    output
                // 000      0       4
                // 001      0       5
                // 01x      0       6
                // 1xx      0       7
                // 000      1       3
                // 001      1       2
                // 01x      1       1
                // 1xx      1       0
                if (sign_outreg[i]) begin
                    if (therm_code[i][2])       dout_enc[3*i +: 3] <= 3'd0;
                    else if (therm_code[i][1])  dout_enc[3*i +: 3] <= 3'd1;
                    else if (therm_code[i][0])  dout_enc[3*i +: 3] <= 3'd2;
                    else                        dout_enc[3*i +: 3] <= 3'd3;
                end else begin
                    if (therm_code[i][2])       dout_enc[3*i +: 3] <= 3'd7;
                    else if (therm_code[i][1])  dout_enc[3*i +: 3] <= 3'd6;
                    else if (therm_code[i][0])  dout_enc[3*i +: 3] <= 3'd5;
                    else                        dout_enc[3*i +: 3] <= 3'd4;
                end
            end
            assign dsp_din[i][0] = sign[i];
            assign dsp_din[i][1 +: (NBITS-1)] = abs_din[(NBITS-1)*i +: (NBITS-1)];
            assign dsp_thr[0][i][0] = sign[i];
            assign dsp_thr[1][i][0] = sign[i];
            assign dsp_thr[2][i][0] = sign[i];
            assign dsp_thr[0][i][1 +: (NBITS-1)] = thresh1_reg;
            assign dsp_thr[1][i][1 +: (NBITS-1)] = thresh2_reg;
            assign dsp_thr[2][i][1 +: (NBITS-1)] = thresh3_reg;
        end
        // We need 6 DSPs: 3 for samples 0-3 and 3 for samples 4-7.
        for (j=0;j<8;j=j+4) begin : DL
            // This is organized in such a way that we can use the cascade path
            // to feed inputs along (adding 2 clocks latency likely).
            // as in, TH[0].dspA gets AB in with A/BREG=2, A/BCASCREG=1     
            //        TH[1].dspA gets ACIN/BCIN with A/BREG=2,A/BCASCREG=1
            //        TH[2].dspA gets ACIN/BCIN with A/BREG=1
            // I think this gives:
            // clk 0:   a/b th0_a1  th0_a2  th0_acout   th1_a1 th1_a2   th1_acout   th2_a1
            //          D0  X       X       X           X       X       X           X
            //          D1  D0      X       D0          X       X       X           X
            //          D2  D1      D0      D1          D0      X       D0          X
            //          D3  D2      D1      D2          D1     D0       D1          D0
            //
            // So in this case the timing path between the DSPs is just cascade->cascade and we only need
            // a single register to delay the th0 output. That's totally worth the routing ease.
            
            wire [47:0] dspA_ab = (k==0) ? { dsp_din[j+3], dsp_din[j+2], dsp_din[j+1], dsp_din[j+0] } : {48{1'b0}};
            wire [47:0] dspA_c =  { dsp_thr[0][j+3], dsp_thr[0][j+2], dsp_thr[0][j+1], dsp_thr[0][j+0] };
            wire [47:0] dspB_c =  { dsp_thr[1][j+3], dsp_thr[1][j+2], dsp_thr[1][j+1], dsp_thr[1][j+0] };
            wire [47:0] dspC_c =  { dsp_thr[2][j+3], dsp_thr[2][j+2], dsp_thr[2][j+1], dsp_thr[2][j+0] };
            wire [47:0] cascAB_AtoB;
            wire [47:0] cascAB_BtoC;
            wire [3:0] therm0_code_out;
            reg [3:0] therm0_code_reg = {4{1'b0}};
            DSP48E1 #(`CONSTANT_MODE_ATTRS, `NO_MULT_ATTRS, `D_UNUSED_ATTRS,
                      .AREG(2),.ACASCREG(1),
                      .BREG(2),.BCASCREG(1),
                      .USE_SIMD("FOUR12")) u_dspA( .A( `DSP_AB_A( dspA_ab ) ),
                                                   .B( `DSP_AB_B( dspA_ab ) ),
                                                   .C( dspA_c  ),
                                                   .ACOUT( `DSP_AB_A( cascAB_AtoB) ),
                                                   .BCOUT( `DSP_AB_B( cascAB_AtoB) ),
                                                   .OPMODE(OPMODE),
                                                   .ALUMODE(ALUMODE),
                                                   .CARRYINSEL(CARRYINSEL),
                                                   .INMODE(5'h00),
                                                   .CARRYIN(1'b0),
                                                   .CLK(clk),
                                                   .CARRYOUT( { therm0_code_out[3],
                                                                therm0_code_out[2],
                                                                therm0_code_out[1],
                                                                therm0_code_out[0] } ),
                                                   .CEA1(1'b1),
                                                   .CEA2(1'b1),
                                                   .CEB1(1'b1),
                                                   .CEB2(1'b1),
                                                   .CEC(1'b1),
                                                   .CEP(1'b1));
            DSP48E1 #(`CONSTANT_MODE_ATTRS, `NO_MULT_ATTRS, `D_UNUSED_ATTRS,            
                      .AREG(2),.ACASCREG(1),.A_INPUT("CASCADE"),
                      .BREG(2),.BCASCREG(1),.B_INPUT("CASCADE"),
                      .USE_SIMD("FOUR12")) u_dspB( .C( dspB_c  ),
                                                   .ACIN( `DSP_AB_A( cascAB_AtoB) ),
                                                   .BCIN( `DSP_AB_B( cascAB_AtoB) ),
                                                   .ACOUT( `DSP_AB_A( cascAB_BtoC) ),
                                                   .BCOUT( `DSP_AB_B( cascAB_BtoC) ),
                                                   .OPMODE(OPMODE),
                                                   .ALUMODE(ALUMODE),
                                                   .CARRYINSEL(CARRYINSEL),
                                                   .INMODE(5'h00),
                                                   .CARRYIN(1'b0),
                                                   .CLK(clk),
                                                   .CARRYOUT( { therm_code[1][j+3],
                                                                therm_code[1][j+2],
                                                                therm_code[1][j+1],
                                                                therm_code[1][j+0] } ),
                                                   .CEA1(1'b1),
                                                   .CEA2(1'b1),
                                                   .CEB1(1'b1),
                                                   .CEB2(1'b1),
                                                   .CEC(1'b1),
                                                   .CEP(1'b1));
            DSP48E1 #(`CONSTANT_MODE_ATTRS, `NO_MULT_ATTRS, `D_UNUSED_ATTRS,            
                      .AREG(1),.A_INPUT("CASCADE"),
                      .BREG(1),.B_INPUT("CASCADE"),
                      .USE_SIMD("FOUR12")) u_dspC( .C( dspC_c  ),
                                                   .ACIN( `DSP_AB_A( cascAB_BtoC) ),
                                                   .BCIN( `DSP_AB_B( cascAB_BtoC) ),
                                                   .OPMODE(OPMODE),
                                                   .ALUMODE(ALUMODE),
                                                   .CARRYINSEL(CARRYINSEL),
                                                   .INMODE(5'h00),
                                                   .CARRYIN(1'b0),
                                                   .CLK(clk),
                                                   .CARRYOUT( { therm_code[2][j+3],
                                                                therm_code[2][j+2],
                                                                therm_code[2][j+1],
                                                                therm_code[2][j+0] } ),
                                                   .CEA1(1'b1),
                                                   .CEA2(1'b1),
                                                   .CEB1(1'b1),
                                                   .CEB2(1'b1),
                                                   .CEC(1'b1),
                                                   .CEP(1'b1));
            always @(posedge clk) begin : DSPA_REG
                therm0_code_reg <= therm0_code_out;
            end                                                           
            assign therm_code[0][j +: 4] = therm0_code_reg;
        end
    endgenerate    
endmodule
