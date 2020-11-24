`timescale 1ns / 1ps
// This module implements:
//
// y = z + b1*x + b2*w
// We want to operate here in 14-bit integer/10-bit fractional.
// Note that we implement this in 2 cascaded DSPs, and we also pass
// the final output result via the cascade output as well.
//
// There's an alternative implementation using 2 DSPs/ch
// flipflopping between the two on different phases of the clock.
// This simplifies routing but requires resources to toggle
// the multiplier parameters. Look into this if we need to,
// as we would want to do this *everywhere* needed.
// The help is that it *massively* reduces the routing cost
// on the data because now the updated data has more time to propagate.
//
// The first one takes in 10-bit fractional and outputs
// 27-bit fractional, cascading it upwards. Then the next one
// also calculates 27-bit fractional and adds them together, outputting it.
// The high fractionality allows us to use the PCIN cascade at the Z-add
// to get back to 10-bit fractional.
// Keep in mind, our inputs are 27 bit (A) and 18 bit (B).
// The B input will be  Q4.14
// The A input will be Q14.13
//
// The way the IIR coefficients work, this should be fine: none of the
// inputs actually grow, and a 14-bit range gives at worst 0.2%
// quantization error on any of them.
//
// This module is used in the z-merge section, along with another DSP
// which only uses the order2_macc_dsp0.
//
// Note that we *don't* use IP cores here because there's insufficient
// flexibility. The cascades mean that we only do single point-to-point
// DSP routing through fabric.
//
// Cascade-wise the first DSP takes an A-input cascade, cascades its
// output to the next, which also outputs its A-input cascade.
module order2_macc( input clk,
                    input rst,
                    input [23:0] add_in,
                    input [29:0] mult1_cascade_in,
                    input [26:0] mult2_in,
                    input [17:0] coeff1_in,
                    input [17:0] coeff2_in,
                    output [26:0] macc_out,
                    output [47:0] macc_cascade_out,
                    output [29:0] mult2_cascade_out
    );
    // This controls whether we add an additional
    // register on the second path to line things up.
    // Needed because this happens every other stage.
    parameter EXDELAY = "FALSE";
    
    
    // First DSP calculates z+b1*x.
    // We need this to be as quick as possible, so
    // we register AB/C and P only.
    // The cascaded DSP will register AB twice, plus the MREG
    // (C's not used). 
    // These come from the other order2_macc stages.
    wire [47:0] dsp0_c_in = { {7{1'b0}}, add_in, {17{1'b0}} };
    wire [47:0] dsp0_cascade;
    
    // Multiplier is ALWAYS A2*B.
    // If EXDELAY = "FALSE", ACASCREG = 1, AREG = 1
    // If EXDELAY = "TRUE", ACASCREG = 1, AREG = 2
    // Never use MREG.
    //
    // DSP0 takes ACASCREG in. 
    // OPMODE for DSP0 is 0/M/M/C.
    // OPMODE for DSP1 is 0/M/M/PCIN.
    // Both ALUMODEs are total sum (0000).
    localparam [4:0] DSP_INMODE =      5'b00000;
    localparam [8:0] DSP0_OPMODE = 9'b000110101;
    localparam [8:0] DSP1_OPMODE = 9'b000010101;
    localparam [3:0] DSP_ALUMODE = 4'b0000;
    DSP48E2 #(.ACASCREG(1),.ADREG(0),.ALUMODEREG(0),.AREG(1),.BCASCREG(1),.BREG(1),.CARRYINREG(0),.CARRYINSELREG(0),.CREG(1),
              .DREG(0),.INMODEREG(0),.MREG(0),.OPMODEREG(0),.PREG(1),
              .A_INPUT("CASCADE"),.B_INPUT("DIRECT"))
              u_dsp0(.CLK(clk),
                     .ACIN(mult1_cascade_in),
                     .B(coeff1_in),
                     .C(dsp0_c_in),
                     .PCOUT(dsp0_cascade),
                     .INMODE(DSP_INMODE),
                     .ALUMODE(DSP_ALUMODE),
                     .OPMODE(DSP0_OPMODE),
                     .RSTP(rst),
                     .CEA2(1'b1),
                     .CEB2(1'b1),
                     .CEC(1'b1),
                     .CEP(1'b1));
//    order2_macc_dsp0 u_dsp0( .A(dsp0_a_in),.B(coeff1_in),.C(dsp0_c_in),.CLK(clk),.PCOUT(dsp0_cascade));
    // Next DSP adds (z+b1*x) and calculated (b2*y).
    // This guy registers AB twice, plus the MREG. This way
    // it's technically synchronous with the inputs: as in, you present add_in/mult1_in/mult2_in
    // in the same cycle, and macc_out comes 3 cycles later.
    wire [29:0] dsp1_a_in = { 3'b000, mult2_in };
    wire [47:0] dsp1_p_out;
    DSP48E2 #(.ACASCREG(1),.ADREG(0),.ALUMODEREG(0),.AREG(EXDELAY=="FALSE" ? 1 : 2),.BREG(1),.BCASCREG(1),.CARRYINREG(0),.CARRYINSELREG(0),.CREG(1),
              .DREG(0),.INMODEREG(0),.MREG(0),.OPMODEREG(0),.PREG(1),
              .A_INPUT("DIRECT"),.B_INPUT("DIRECT"))
              u_dsp1(.CLK(clk),
                     .A(dsp1_a_in),
                     .B(coeff2_in),
                     .PCIN(dsp0_cascade),
                     .ACOUT(mult2_cascade_out),
                     .P(dsp1_p_out),
                     .PCOUT(macc_cascade_out),
                     .INMODE(DSP_INMODE),
                     .ALUMODE(DSP_ALUMODE),
                     .OPMODE(DSP1_OPMODE),
                     .RSTP(rst),
                     .CEA2(1'b1),
                     .CEA1(EXDELAY=="FALSE" ? 1'b0 : 1'b1),
                     .CEB2(1'b1),
                     .CEC(1'b1),
                     .CEP(1'b1));
//    order2_macc_dsp1 u_dsp1( .A(dsp1_a_in),.B(coeff2_in),.PCIN(dsp0_cascade),.CLK(clk),.P(macc_out),.PCOUT(macc_out_cascade));
    // The P output is Q21.27 format, and we want Q14.13 output.
    // So we lop off the bottom 14 bits and top 7.
    assign macc_out = dsp1_p_out[14 +: 27];
endmodule
