`timescale 1ns / 1ps
`include "dsp_macros.vh"
// FIR section of an 8-fold simple IIR filter.
// This only handles symmetric zeros on the unit circle,
// meaning there's only a single parameter. That parameter's limited
// to be 2 or less (it's 2x the real part), meaning in integer-land, we're doing:
// (a+b-2*c) meaning that our biggest value could be 4*max,
// or we're expanding by 2 bits. So 14-bit integer, 10-bit
// fractional here.
// So the input B value here is actually (parameter*1024)
// (or -1436). We only allow 12 bits, and sign extend the rest.
//
// After that they get cross-merged around, which means
// the output bit depth needs to get dropped later.
module iir8_fir_section #(parameter NBITS=12, parameter NOUTBITS=24)(
        input   [8*NBITS-1:0]       din,
        input   [11:0]              mult_val,
        output  [8*NOUTBITS-1:0]    dout,
        input                       clk
    );
    localparam NSAMP=8;
    
    // We need to store a few of the inputs.
    reg [2*NBITS-1:0] reg_store = {2*NBITS{1'b0}};
    always @(posedge clk) reg_store <= din[(NSAMP-2)*NBITS +: 2*NBITS];
    
    // Now create a vector for them
    wire [NBITS-1:0] samp_in[NSAMP+2-1:0];
    // Just for convenience we'll also create a new vector mapping these
    // guys to unsigned values via "value+2048". Which is done by flipping
    // the top bit. Which is FREE at the DSP. Magic!
    wire [NBITS-1:0] usamp_in[NSAMP+2-1:0];
    generate
        genvar i;
        for (i=0;i<NSAMP+2;i=i+1) begin
            if (i<2) begin : STORE
                assign samp_in[i] = reg_store[NBITS*i +: NBITS];
            end else begin : IN
                assign samp_in[i] = din[NBITS*(i-2) +: NBITS];
            end
            // Flippity-floppity!
            assign usamp_in[i][NBITS-1] = ~samp_in[i][NBITS-1];
            assign usamp_in[i][0 +: (NBITS-1)] = samp_in[i][0 +: (NBITS-1)];
        end
    endgenerate    
    // The FOUR12 DSPs get
    // samp[2] samp[0]
    // samp[3] samp[1]
    // samp[4] samp[2]
    // samp[5] samp[3]
    // samp[6] samp[4]
    // samp[7] samp[5]
    // samp[8] samp[6]
    // samp[9] samp[7]
    wire [12:0] presum_out[7:0];
    generate
        genvar j,k;
        for (j=0;j<2;j=j+1) begin : PREADD
            // OK - we need to do magic here.
            // We're calculating "a+b" with both signed, but we *can't* actually use signed arithmetic.
            // So what we do is flip the top bit. What this actually does is add 2048 to each (by magic!)
            // Consider:
            // 0     = 000 -> 800 = 2048
            // -1    = FFF -> 7FF = 2047
            // -2    = FFE -> 7FE = 2046
            // -2048 = 800 -> 000 = 0
            // 2047  = 7FF -> FFF = 4095
            // So our output is now "a+b+4096".
            wire [47:0] samppre_ab = { usamp_in[4*j+2], usamp_in[4*j+3], usamp_in[4*j+4], usamp_in[4*j+5] };
            wire [47:0] samppre_c =  { usamp_in[4*j+0], usamp_in[4*j+1], usamp_in[4*j+2], usamp_in[4*j+3] };    
            DSP48E1 #(`NO_MULT_ATTRS, `D_UNUSED_ATTRS,`CONSTANT_MODE_ATTRS,.USE_SIMD("FOUR12"))
                u_preadd(`D_UNUSED_PORTS,
                     .OPMODE( { `Z_OPMODE_C , `Y_OPMODE_0, `X_OPMODE_AB } ),
                     .ALUMODE( `ALUMODE_SUM_ZXYCIN ),
                     .CEA2(1'b1),.CEB2(1'b1),.CEC(1'b1),.CEP(1'b1),
                     .A( `DSP_AB_A(samppre_ab) ),
                     .B( `DSP_AB_B(samppre_ab) ),
                     .C( samppre_c ),
                     .CARRYIN(0),
                     .CARRYINSEL(0),
                     .INMODE(0),
                     .CLK(clk),
                     .P( { presum_out[4*j+0][11:0], presum_out[4*j+1][11:0],presum_out[4*j+2][11:0],presum_out[4*j+3][11:0] } ),
                     .CARRYOUT({ presum_out[4*j+0][12], presum_out[4*j+1][12], presum_out[4*j+2][12], presum_out[4*j+3][12] } ));
        end
        for (k=0;k<8;k=k+1) begin : MULT
            // Now we have a 13 bit number representing "a+b+4096". We need to subtract off that 4096
            // somehow. How do we do that?
            // 0    = 0000    -> -4096 = 1000
            // 1    = 0001    -> -4095 = 1001
            // 4096 = 1000    -> 0 =     0000
            // 8191 = 1FFF    -> 4095 =  0FFF
            // So again, all we do is just flip the top bit. Sign extension is *also* an invert of the top bit.
            // Why do people make such a big deal out of this stuff...?? Maybe with more than 2 inputs it's harder or something?
            // I seriously don't get it. Even if you have -2048 -2048, that maps to 0 + 0 = 0 = -4096, which again... just flip
            // the top bit first, and then again afterwards.
            
            // we multiply (mult_val*1024)*input = (output*1024)
            wire [17:0] mult_const_in = { {6{mult_val[11]}}, mult_val };
            wire [26:0] mult_data_in = { {(27-NBITS){samp_in[k+1][11]}}, samp_in[k+1] };
            // but now we have to *add* the presum_out shifted up by 10, then subtract 4096 (flip top bit)
            // and sign-extend.
            // presum_out is 13 bits, lop off the top bit and you get 12 bits, + 10 lower,
            // to extend to 48 need 26 (26+12+10 = 48)
            wire [47:0] add_in = { {26{~presum_out[k][12]}}, presum_out[k][11:0], {10{1'b0}} };
            wire [47:0] p_out;
            ii48_fir_dsp u_dsp(.A(mult_data_in),.B(mult_const_in),.C(add_in),.CLK(clk),.P(p_out));
            // Outbits are the 24 low bits.
            assign dout[NOUTBITS*k +: NOUTBITS] = p_out[0 +: NOUTBITS];
        end
    endgenerate        
endmodule
