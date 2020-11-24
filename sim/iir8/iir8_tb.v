`timescale 1ns / 1ps
module iir8_tb;
    real ckper = (1/375.0)*1000.0;

    reg clk = 0;
    always #(ckper/2.0) clk <= ~clk;
    
    // clk is 10 intervals long.
    // We need to fit 8 samples there. So each one is 1.25 long.
    
    reg rst = 1;
    
    reg [11:0] samp_in[7:0];
    reg [11:0] in = {12{1'b0}};
    localparam [11:0] MULT_VAL = (-1.40209)*1024;
    wire [12*8-1:0] samp_in_vec = { samp_in[7],samp_in[6],samp_in[5],samp_in[4],samp_in[3],samp_in[2],samp_in[1],samp_in[0] };
    wire [23:0] fir_out[7:0];
    iir8_fir_section u_fir(.din(samp_in_vec),
                           .dout( {fir_out[7],fir_out[6],fir_out[5],fir_out[4],fir_out[3],fir_out[2],fir_out[1],fir_out[0] } ),
                           .mult_val(MULT_VAL),
                           .clk(clk));
    wire [23:0] zmerge_out[7:0];
    wire [4:0] zmerge_delay_out[7:0];
    localparam [17:0] COEFF1 = 21612;
    localparam [17:0] COEFF2 = -14444;
    iir8_zmerge_section u_zmerge(.clk(clk),
                                 .rst(rst),
                                 .fir_in( {fir_out[7],fir_out[6],fir_out[5],fir_out[4],fir_out[3],fir_out[2],fir_out[1],fir_out[0] } ),
                                 .zmerge_out( {zmerge_out[7],zmerge_out[6],zmerge_out[5],zmerge_out[4],zmerge_out[3],zmerge_out[2],zmerge_out[1],zmerge_out[0] } ),
                                 .zmerge_delay_out( {zmerge_delay_out[7],zmerge_delay_out[6],zmerge_delay_out[5],zmerge_delay_out[4],zmerge_delay_out[3],zmerge_delay_out[2],zmerge_delay_out[1],zmerge_delay_out[0] } ),
                                 .coeff1(COEFF1),
                                 .coeff2(COEFF2));    
    integer i;
    wire [23:0] align_out[7:0];        
    reg [23:0] out = {24{1'b0}};
    always @(posedge clk) begin
        #0.1;
        out <= align_out[0];
        in <= samp_in[0];
        #(ckper/8.0);
        out <= align_out[1];
        in <= samp_in[1];
        #(ckper/8.0);
        out <= align_out[2];
        in <= samp_in[2];
        #(ckper/8.0);
        out <= align_out[3];
        in <= samp_in[3];
        #(ckper/8.0);
        out <= align_out[4];
        in <= samp_in[4];
        #(ckper/8.0);
        out <= align_out[5];
        in <= samp_in[5];
        #(ckper/8.0);
        out <= align_out[6];
        in <= samp_in[6];
        #(ckper/8.0);
        out <= align_out[7];
        in <= samp_in[7];
    end
    
    generate
        genvar d,b;
        for (d=0;d<8;d=d+1) begin : AL
            for (b=0;b<24;b=b+1) begin : BL            
                SRLC32E u_srl(.D(zmerge_out[d][b]),.A(zmerge_delay_out[d]),.CE(1'b1),.CLK(clk),.Q(align_out[d][b]));
            end
        end
    endgenerate
    initial begin                          
        for (i=0;i<8;i=i+1) samp_in[i] <= {12{1'b0}};
        #150;
        @(posedge clk);
        #1 rst = 0;
        @(posedge clk);
        #400;
        @(posedge clk);
        #1;
        samp_in[0] <= 100;
        samp_in[1] <= 0;
        samp_in[2] <= 0;
        samp_in[3] <= 0;
        samp_in[4] <= 0;
        samp_in[5] <= 0;
        samp_in[6] <= 0;
        samp_in[7] <= 0;
        @(posedge clk);
        #1;
        samp_in[0] <= 0;
        samp_in[1] <= 0;
        samp_in[2] <= 0;
        samp_in[3] <= 0;
        samp_in[4] <= 0;
        samp_in[5] <= 0;
        samp_in[6] <= 0;
        samp_in[7] <= 0;
        @(posedge clk);
        #1;
        for (i=0;i<8;i=i+1) samp_in[i] <= {12{1'b0}};
    end
        

endmodule
