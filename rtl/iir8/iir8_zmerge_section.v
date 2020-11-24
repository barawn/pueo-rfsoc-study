`timescale 1ns / 1ps
// This implements the z-merge for an 8-fold IIR.
// The point here is to calculate all of the *internal* feedback in a block of 8 data points,
// free from any recursed feedback.
// The recursed part is then finally added at the end.
// This implementation is distinct from the z-merge section for a time-multiplexed 8x3-fold
// IIR, which is a fair amount more complicated.
//
// The inputs here are the 8x24-bit outputs of the FIR section.
// The outputs are just the z-merge outputs.
// Finally we also take in the 13 18-bit coefficients corresponding
// to the iterated calculations.

// Note that the zmerge outputs here are NOT synchronous: they'll need to be each delayed
// by fixed amounts. The delays required are output as zmerge_delay_out.
//
// The reason for this is that the IIR section also needs additional delays
// to line things up, and these can be combined.
//
// The final IIR section ends up having to combine:
// b0*(y6(t-2))+b1*(y7(t-2)) + b2*(z6(t-2)) + b3*(z6(t-1)) + b4*(z7(t-2)) + b5(z7(t-1))
// Which... is fairly freaking nasty.
// But we actually use the AB cascade to minimize routing on the output DSPs:
// DSP1 calculates b2*z6(t-2) and forwards AB to DSP2 who calculates b4*z6(t-2) and adds it
// to the previous. Same for the other 2 calculating the z7 terms, and then the *others*
// as well.
//
// This is *nominally* for an IIR8 but I *believe* that it'd work for any block: just changing
// the NSAMPS should do it.
//
// Note that the cascade outputs would be really nice to be able to use, but we don't
// have delay elements in the cascade path that we can use. Instead they'll be the C term
// added in the final IIR, which will look like:
//
// A,B  = y6(t-3),b0 (so AREG = y6(t-2))
// PCIN = b1*y7(t-3) + b2*z6(t-2) + b3*z6(t-1) + b4*z7(t-2) + b5*(z7(t-1))
// C = z6(t+1) (so CREG=z6(t))
// yielding on the next clock y6(t)
// This works because we've substituted for both y6(t-1)/y7(t-1) and y6(t-2)/y7(t-2).
module iir8_zmerge_section #(parameter NBITS=24, parameter NSAMPS=8, parameter COEFFBITS=18, parameter DELAYBITS=5)(
        input clk,
        input rst,
        input [NBITS*NSAMPS-1:0]        fir_in,
        output [NBITS*NSAMPS-1:0]       zmerge_out,
        output [DELAYBITS*NSAMPS-1:0]   zmerge_delay_out,
        input [COEFFBITS-1:0]           coeff1,
        input [COEFFBITS-1:0]           coeff2
    );
    // Internally, we pass around things in Q14.13 format.
    localparam INTBITS = 27;
    localparam CASCBITS = 30;
    wire [INTBITS-1:0] zmerge_int[NSAMPS-1:0];
    wire [CASCBITS-1:0] zmerge_casc[NSAMPS-1:0];
    generate
        genvar i,b;
        for (i=0;i<NSAMPS;i=i+1) begin : ZL
            if (i == 0) begin : HEAD
                // zero is easy
                assign zmerge_out[NBITS*i +: NBITS] = fir_in[NBITS*i +: NBITS];
                assign zmerge_int[0] = {zmerge_out[NBITS*i +: NBITS],3'b000};
                // zmerge_delay_out is always 2*(NSAMPS-1-i)
                assign zmerge_delay_out[DELAYBITS*i +: DELAYBITS] = 2*(NSAMPS-1-i);
                // this is junk, no one uses it
                assign zmerge_casc[i] = {CASCBITS{1'b0}};
                // these are also junk
            end else if (i==1) begin : S1
                // Stage 1 requires a single DSP, with AREG/BREG=1, no MREG, and CREG.
                // It outputs data on clock 2 (clk1 = AREG, clk2 = PREG output)
                // This is then fed back into a new DSP for stage 2, which
                // captures it on clock 3 and outputs its multiply-add on clock 4.
                // In addition the input (zmerge_out[0]) is passed forward to
                // the order2_macc in the next clock.
                localparam [4:0] DSP_INMODE =      5'b00000;
                localparam [8:0] DSP0_OPMODE = 9'b000110101;
                localparam [3:0] DSP_ALUMODE = 4'b0000;
                wire [29:0] dsp_a_in = { 3'b000, zmerge_int[i-1] };

                // FIR outputs are Q14.10, want Q21.27. Add 17 zeros below, 7 above.
                wire [47:0] dsp_c_in = { {7{1'b0}}, fir_in[NBITS*i +: NBITS], {17{1'b0}} };
                wire [47:0] dsp_p_out;
                DSP48E2 #(.ACASCREG(1),.ADREG(0),.ALUMODEREG(0),.AREG(1),.BCASCREG(1),.BREG(1),.CARRYINREG(0),.CARRYINSELREG(0),.CREG(1),
                      .DREG(0),.INMODEREG(0),.MREG(0),.OPMODEREG(0),.PREG(1),
                      .A_INPUT("DIRECT"),.B_INPUT("DIRECT"))
                      u_dsp0(.CLK(clk),
                             .A(dsp_a_in),
                             .ACOUT(zmerge_casc[i]),
                             .B(coeff1),
                             .C(dsp_c_in),
                             .P(dsp_p_out),
                             .INMODE(DSP_INMODE),
                             .ALUMODE(DSP_ALUMODE),
                             .OPMODE(DSP0_OPMODE),
                             .RSTP(rst),
                             .CEA2(1'b1),
                             .CEB2(1'b1),
                             .CEC(1'b1),
                         .CEP(1'b1));                
                // Q14.13 format                         
                assign zmerge_int[i] = dsp_p_out[14 +: INTBITS];
                // Q14.10 format
                assign zmerge_out[NBITS*i +: NBITS] = zmerge_int[i][3 +: NBITS];
                // zmerge_delay_out is always 2*(NSAMPS-1-i)
                assign zmerge_delay_out[DELAYBITS*i +: DELAYBITS] = 2*(NSAMPS-1-i);
           end else begin : LP
                // Now we begin the main loop.
                reg [23:0] fir_delay_reg = {24{1'b0}};
                // Delay inputs.
                // The input delay scales as 2*(i-2)+1. i=2 is special, it's just 1 clock.
                if (i==2) begin : REGDELAY
                    always @(posedge clk) begin : RR
                        fir_delay_reg <= fir_in[NBITS*i +: NBITS];
                    end
                end else begin : SRLDELAY
                    wire [23:0] fir_srl_out;
                    for (b=0;b<24;b=b+1) begin : BL
                        SRLC32E srl(.D(fir_in[NBITS*i+b]),.A(2*(i-2)+1),.CE(1'b1),.CLK(clk),.Q(fir_srl_out[b]));
                    end
                    always @(posedge clk) begin : RR
                        fir_delay_reg <= fir_srl_out;
                    end
                end
                // If we're *even*, we pick up an extra delay.
                wire [47:0] macc_casc_out;
                order2_macc #(.EXDELAY("FALSE")) 
                    u_macc(.clk(clk),
                           .rst(rst),
                           .add_in(fir_delay_reg),
                           .mult1_cascade_in(zmerge_casc[i-1]),
                           .mult2_in(zmerge_int[i-1]),
                           // the MACC adds z-2 in the first section, and z-1 in the second.
                           .coeff1_in(coeff2),
                           .coeff2_in(coeff1),
                           .macc_out(zmerge_int[i]),
                           // we never use macc_cascade_out
                           .mult2_cascade_out(zmerge_casc[i]));                           
               assign zmerge_out[NBITS*i +: NBITS] = zmerge_int[i][3 +: NBITS];
                // zmerge_delay_out is always 2*(NSAMPS-1-i)
               assign zmerge_delay_out[DELAYBITS*i +: DELAYBITS] = 2*(NSAMPS-1-i);
           end
        end
    endgenerate    
endmodule
