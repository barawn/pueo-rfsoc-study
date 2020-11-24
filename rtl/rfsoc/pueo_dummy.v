`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 09/15/2020 12:13:38 PM
// Design Name: 
// Module Name: pueo_dummy
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module pueo_dummy(
        input   adc0_clk_p,
        input   adc0_clk_n,
        input   adc1_clk_p,
        input   adc1_clk_n,
        input   adc2_clk_p,
        input   adc2_clk_n,
        input   adc3_clk_p,
        input   adc3_clk_n,
        
        input   vin0_01_n,
        input   vin0_01_p,
        input   vin0_23_n,
        input   vin0_23_p,

        input   vin1_01_n,
        input   vin1_01_p,
        input   vin1_23_n,
        input   vin1_23_p,

        input   vin2_01_n,
        input   vin2_01_p,
        input   vin2_23_n,
        input   vin2_23_p,

        input   vin3_01_n,
        input   vin3_01_p,
        input   vin3_23_n,
        input   vin3_23_p,
        
        input   CLK_100,
        input   FPGA_RXD,
        output  FPGA_TXD        
    );
    // AXI4-Lite control path for RFDC
    wire [17:0] axi_araddr;
    wire        axi_arready;
    wire        axi_arvalid;
    wire [17:0] axi_awaddr;
    wire        axi_awready;
    wire        axi_awvalid;
    wire [1:0]  axi_bresp;
    wire        axi_bready;
    wire        axi_bvalid;
    wire [31:0] axi_rdata;
    wire [1:0]  axi_rresp;
    wire        axi_rvalid;
    wire        axi_rready;
    wire        axi_rlast = 1'b1;
    wire [31:0] axi_wdata;
    wire        axi_wready;
    wire        axi_wvalid;
    wire [3:0]  axi_wstrb;
    wire        axi_wlast;
    
    // 1/16th clock in... (23.025)
    wire [3:0]  adc_clk;
    // out of the MMCM (368.4) and the 1/4th down
    wire [7:0]  m_clk;
    wire [7:0]  m_aresetn = {4{1'b1}};
    // dumb dumb dumb, just 1 aclk
    wire        aclk;
    wire [7:0]  aresetn = {4{1'b1}};
    // fast AXI parts. 
    wire [127:0]    m_axis_tdata[7:0];
    wire            m_axis_tready[7:0];
    wire            m_axis_tvalid[7:0];
    // resized AXI parts (down by 4)
    wire [511:0]    wide_tdata[7:0];
    wire            wide_tready[7:0];
    wire            wide_tvalid[7:0];
    // and out of the clock converter
    wire [511:0]    ws_tdata[7:0];
    wire [7:0]      ws_tready;
    assign          ws_tready = {8{1'b1}};
    wire            ws_tvalid[7:0];
    ref_to_axi u_clk1(.clk_in1(adc_clk[0]),.clk_out1(m_clk[0]),.clk_out2(aclk));
    assign m_clk[1] = m_clk[0];
    ref_to_output u_clk2(.clk_in1(adc_clk[1]),.clk_out1(m_clk[2]));
    assign m_clk[3] = m_clk[2];
    ref_to_output u_clk3(.clk_in1(adc_clk[2]),.clk_out1(m_clk[4]));
    assign m_clk[5] = m_clk[4];
    ref_to_output u_clk4(.clk_in1(adc_clk[3]),.clk_out1(m_clk[6]));
    assign m_clk[7] = m_clk[6];
    
    
    generate
        genvar i;
        for (i=0;i<8;i=i+1) begin : LP
            if (i<4) begin : CLK
                adc_raw_buf u_ila(.clk(aclk),.probe0(ws_tdata[2*i]),.probe1(ws_tdata[2*i+1]));                
            end
            resize_by_4 u_resizer(.aclk(m_clk[i]),.aresetn(m_aresetn[i]),
                                  .s_axis_tdata(m_axis_tdata[i]),
                                  .s_axis_tvalid(m_axis_tvalid[i]),
                                  .s_axis_tready(m_axis_tready[i]),
                                  .m_axis_tdata(wide_tdata[i]),
                                  .m_axis_tvalid(wide_tvalid[i]),
                                  .m_axis_tready(wide_tready[i]));
            slowdown_fifo u_cc_f(.s_aclk(m_clk[i]),.s_aresetn(m_aresetn[i]),.m_aclk(aclk),
                                 .s_axis_tdata(wide_tdata[i]),
                                 .s_axis_tvalid(wide_tvalid[i]),
                                 .s_axis_tready(wide_tready[i]),
                                 .m_axis_tdata(ws_tdata[i]),
                                 .m_axis_tready(ws_tready[i]),
                                 .m_axis_tvalid(ws_tvalid[i]));
        end
    endgenerate
    wire sys_reset;
    wire alite_resetn;
    wire [7:0] bridge_tx_tdata;
    wire       bridge_tx_tvalid;
    wire       bridge_tx_tready;
    wire [0:0] bridge_tx_tkeep;
    wire       bridge_tx_tlast;
    wire [2:0] bridge_tx_tid;
    
    wire [7:0] bridge_rx_tdata;
    wire       bridge_rx_tvalid;
    wire       bridge_rx_tready;
    wire [0:0] bridge_rx_tkeep;
    wire       bridge_rx_tlast;
    wire [2:0] bridge_rx_tid;
    
    serial_axis_bridge_0 u_bridge(.clk_i(CLK_100),
                                .rst_i(vio_rst),
                                .serial_rx_i(FPGA_RXD),
                                .serial_tx_o(FPGA_TXD),
                                .SYS_RESET(sys_reset),
                                .ARESETN(alite_resetn),
                                .M_AXIS_TDATA(  bridge_tx_tdata     ),
                                .M_AXIS_TVALID( bridge_tx_tvalid    ),
                                .M_AXIS_TREADY( bridge_tx_tready    ),
                                .M_AXIS_TKEEP(  bridge_tx_tkeep     ),
                                .M_AXIS_TLAST(  bridge_tx_tlast     ),
                                .M_AXIS_TID(    bridge_tx_tid       ),
                                .S_AXIS_TDATA(  bridge_rx_tdata     ),
                                .S_AXIS_TVALID( bridge_rx_tvalid    ),
                                .S_AXIS_TREADY( bridge_rx_tready    ),
                                .S_AXIS_TKEEP(  bridge_rx_tkeep     ),
                                .S_AXIS_TLAST(  bridge_rx_tlast     ),
                                .S_AXIS_TID(    bridge_rx_tid       ));
                                
    s2mm_map u_mapper(.aclk(CLK_100),.aresetn(alite_resetn),
                      .s_axis_tdata(    bridge_tx_tdata     ),
                      .s_axis_tid(      bridge_tx_tid       ),
                      .s_axis_tvalid(   bridge_tx_tvalid    ),
                      .s_axis_tready(   bridge_tx_tready    ),
                      .s_axis_tlast(    bridge_tx_tlast     ),
                      .s_axis_tkeep(    bridge_tx_tkeep     ),
                      .m_axis_tdata(    bridge_rx_tdata     ),
                      .m_axis_tid(      bridge_rx_tid       ),
                      .m_axis_tvalid(   bridge_rx_tvalid    ),
                      .m_axis_tready(   bridge_rx_tready    ),
                      .m_axis_tlast(    bridge_rx_tlast     ),
                      .m_axis_tkeep(    bridge_rx_tkeep     ),
                      .m_axi_araddr(    axi_araddr          ),
                      .m_axi_arready(   axi_arready         ),
                      .m_axi_arvalid(   axi_arvalid         ),
                      .m_axi_awaddr(    axi_awaddr          ),
                      .m_axi_awready(   axi_awready         ),
                      .m_axi_awvalid(   axi_awvalid         ),
                      .m_axi_bresp(     axi_bresp           ),
                      .m_axi_bready(    axi_bready          ),
                      .m_axi_bvalid(    axi_bvalid          ),
                      .m_axi_rdata(     axi_rdata           ),
                      .m_axi_rresp(     axi_rresp           ),
                      .m_axi_rready(    axi_rready          ),
                      .m_axi_rvalid(    axi_rvalid          ),
                      .m_axi_rlast(     axi_rlast           ),
                      .m_axi_wdata(     axi_wdata           ),
                      .m_axi_wstrb(     axi_wstrb           ),
                      .m_axi_wready(    axi_wready          ),
                      .m_axi_wvalid(    axi_wvalid          ),
                      .m_axi_wlast(     axi_wlast           ));
    usp_rf_data_converter_0 u_dc( .s_axi_aclk(CLK_100),.s_axi_aresetn(alite_resetn),
                      .s_axi_araddr(    axi_araddr          ),
                      .s_axi_arready(   axi_arready         ),
                      .s_axi_arvalid(   axi_arvalid         ),
                      .s_axi_awaddr(    axi_awaddr          ),
                      .s_axi_awready(   axi_awready         ),
                      .s_axi_awvalid(   axi_awvalid         ),
                      .s_axi_bresp(     axi_bresp           ),
                      .s_axi_bready(    axi_bready          ),
                      .s_axi_bvalid(    axi_bvalid          ),
                      .s_axi_rdata(     axi_rdata           ),
                      .s_axi_rresp(     axi_rresp           ),
                      .s_axi_rready(    axi_rready          ),
                      .s_axi_rvalid(    axi_rvalid          ),
//                      .s_axi_rlast(     axi_rlast           ),
                      .s_axi_wdata(     axi_wdata           ),
                      .s_axi_wstrb(     axi_wstrb           ),
                      .s_axi_wready(    axi_wready          ),
                      .s_axi_wvalid(    axi_wvalid          ),
//                      .s_axi_wlast(     axi_wlast           ),
                      .adc0_clk_p(  adc0_clk_p  ),
                      .adc0_clk_n(  adc0_clk_n  ),
                      .adc1_clk_p(  adc1_clk_p  ),
                      .adc1_clk_n(  adc1_clk_n  ),
                      .adc2_clk_p(  adc2_clk_p  ),
                      .adc2_clk_n(  adc2_clk_n  ),
                      .adc3_clk_p(  adc3_clk_p  ),
                      .adc3_clk_n(  adc3_clk_n  ),
                      .sysref_in_n( sysref_in_n ),
                      .sysref_in_p( sysref_in_p ),

                      .vin0_01_p          (vin0_01_p),
                      .vin0_01_n          (vin0_01_n),
                      .vin0_23_p          (vin0_23_p),
                      .vin0_23_n          (vin0_23_n),

                      .vin1_01_p          (vin1_01_p),
                      .vin1_01_n          (vin1_01_n),
                      .vin1_23_p          (vin1_23_p),
                      .vin1_23_n          (vin1_23_n),
                          
                      .vin2_01_p          (vin2_01_p),
                      .vin2_01_n          (vin2_01_n),
                      .vin2_23_p          (vin2_23_p),
                      .vin2_23_n          (vin2_23_n),

                      .vin3_01_p          (vin3_01_p),
                      .vin3_01_n          (vin3_01_n),
                      .vin3_23_p          (vin3_23_p),
                      .vin3_23_n          (vin3_23_n),
                      
                      .m0_axis_aclk(    m_clk[0]    ),
                      .m0_axis_aresetn( 1'b1        ),
                      .m1_axis_aclk(    m_clk[2]    ),
                      .m1_axis_aresetn( 1'b1        ),
                      .m2_axis_aclk(    m_clk[4]    ),
                      .m2_axis_aresetn( 1'b1        ),
                      .m3_axis_aclk(    m_clk[6]    ),
                      .m3_axis_aresetn( 1'b1        ),
                      
                      .m00_axis_tdata(   m_axis_tdata[0] ),
                      .m00_axis_tvalid( m_axis_tvalid[0] ),
                      .m00_axis_tready( m_axis_tready[0] ),

                      .m02_axis_tdata(   m_axis_tdata[1] ),
                      .m02_axis_tvalid( m_axis_tvalid[1] ),
                      .m02_axis_tready( m_axis_tready[1] ),

                      .m10_axis_tdata(   m_axis_tdata[2] ),
                      .m10_axis_tvalid( m_axis_tvalid[2] ),
                      .m10_axis_tready( m_axis_tready[2] ),

                      .m12_axis_tdata(   m_axis_tdata[3] ),
                      .m12_axis_tvalid( m_axis_tvalid[3] ),
                      .m12_axis_tready( m_axis_tready[3] ),

                      .m20_axis_tdata(   m_axis_tdata[4] ),
                      .m20_axis_tvalid( m_axis_tvalid[4] ),
                      .m20_axis_tready( m_axis_tready[4] ),

                      .m22_axis_tdata(   m_axis_tdata[5] ),
                      .m22_axis_tvalid( m_axis_tvalid[5] ),
                      .m22_axis_tready( m_axis_tready[5] ),

                      .m30_axis_tdata(   m_axis_tdata[6] ),
                      .m30_axis_tvalid( m_axis_tvalid[6] ),
                      .m30_axis_tready( m_axis_tready[6] ),

                      .m32_axis_tdata(   m_axis_tdata[7] ),
                      .m32_axis_tvalid( m_axis_tvalid[7] ),
                      .m32_axis_tready( m_axis_tready[7] ),
                      
                      .clk_adc0(    adc_clk[0]    ),
                      .clk_adc1(    adc_clk[1]    ),
                      .clk_adc2(    adc_clk[2]    ),
                      .clk_adc3(    adc_clk[3]    ));

endmodule
