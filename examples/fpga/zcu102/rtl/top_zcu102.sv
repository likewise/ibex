// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

module top_zcu102 (
   input wire CPU_RESET,
   input wire  CLK_125_P,
   input wire  CLK_125_N,
   //input wire USER_SI570_P,
   //input wire USER_SI570_N,
   output wire GPIO_LED_0,
   output wire GPIO_LED_1,
   output wire GPIO_LED_2,
   output wire GPIO_LED_3,

  // JTAG interface
  input               PMOD1_0/*jtag_tck_i*/,
  input               PMOD1_1/*jtag_tms_i*/,
  input               PMOD1_4/*jtag_trst_ni*/,
  input               PMOD1_2/*jtag_td_i*/,
  output              PMOD1_3/*jtag_td_o*/    
);

  parameter int          MEM_SIZE  = 64 * 1024; // 64 kB
  parameter logic [31:0] MEM_START = 32'h00000000;
  parameter logic [31:0] MEM_MASK  = MEM_SIZE-1;
  parameter logic [31:0] DBG_START = 32'h10000000;
  parameter logic [31:0] DBG_MASK  = 32'h00000fff;

  // JTAG IDCODE for development versions of this code.
  // Manufacturers of OpenTitan chips must replace this code with one of their
  // own IDs.
  // Field structure as defined in the IEEE 1149.1 (JTAG) specification,
  // section 12.1.1.
  localparam JTAG_IDCODE = {
    4'h0,     // Version
    16'h4F53, // Part Number: "OS"
    11'h426,  // Manufacturer Identity: Google
    1'b1      // (fixed)
  };

  logic clk_sys, rst_sys_n;
  logic jtag_tck_i, jtag_tms_i, jtag_trst_ni, jtag_td_i, jtag_td_o;

  assign jtag_tck_i   = PMOD1_0;
  assign jtag_tms_i   = PMOD1_1;
  assign jtag_td_i    = PMOD1_2;
  assign jtag_td_o    = PMOD1_3;
  assign jtag_trst_ni = PMOD1_4;

  //BUFG jtag_tck_bufg (
  //  .I (PMOD1_0),
  //  .O (jtag_tck_i)
  //);


  // Instruction connection to SRAM
  logic        instr_req;
  logic        instr_gnt;
  logic        instr_rvalid;
  logic [31:0] instr_addr;
  logic [31:0] instr_rdata;

  // Data connection to SRAM
  logic        data_req;
  logic        data_gnt;
  logic        data_rvalid;
  logic        data_we;
  logic  [3:0] data_be;
  logic [31:0] data_addr;
  logic [31:0] data_wdata;
  logic [31:0] data_rdata;

  // SRAM arbiter
  logic [31:0] mem_addr;
  logic        mem_req;
  logic        dbg_req;
  logic        mem_write;
  logic  [3:0] mem_be;
  logic [31:0] mem_wdata;
  logic        mem_rvalid;
  logic        dbg_rvalid;
  logic [31:0] mem_rdata;
  logic [31:0] dbg_rdata;

  // debug request from rv_dm to core
  logic debug_req;
  // Non-debug module reset == reset for everything except for the debug module
  logic ndmreset_req;

  ibex_core #(
     .DmHaltAddr(DBG_START + dm::HaltAddress),
     .DmExceptionAddr(DBG_START + dm::ExceptionAddress)
  ) u_core (
     .clk_i                 (clk_sys),
     .rst_ni                (rst_sys_n),

     .test_en_i             ('b0),

     .hart_id_i             (32'b0),
     // First instruction executed is at 0x0 + 0x80
     .boot_addr_i           (32'h00000000),

     .instr_req_o           (instr_req),
     .instr_gnt_i           (instr_gnt),
     .instr_rvalid_i        (instr_rvalid),
     .instr_addr_o          (instr_addr),
     .instr_rdata_i         (instr_rdata),
     .instr_err_i           ('b0),

     .data_req_o            (data_req),
     .data_gnt_i            (data_gnt),
     .data_rvalid_i         (data_rvalid),
     .data_we_o             (data_we),
     .data_be_o             (data_be),
     .data_addr_o           (data_addr),
     .data_wdata_o          (data_wdata),
     .data_rdata_i          (data_rdata),
     .data_err_i            ('b0),

     .irq_software_i        (1'b0),
     .irq_timer_i           (1'b0),
     .irq_external_i        (1'b0),
     .irq_fast_i            (15'b0),
     .irq_nm_i              (1'b0),

     .debug_req_i           (debug_req),

     .fetch_enable_i        ('b1),
     .core_sleep_o          ()
  );

  // Debug Module (RISC-V Debug Spec 0.13)
  //

  rv_dm #(
    .NrHarts     (1),
    .IdcodeValue (JTAG_IDCODE)
  ) u_dm_top (
    .clk_i         (clk_sys),
    .rst_ni        (rst_sys_n),
    .testmode_i    (1'b0),
    .ndmreset_o    (ndmreset_req),
    .dmactive_o    (),
    .debug_req_o   (debug_req),
    .unavailable_i (1'b0),

    .req_i         (dbg_req),
    .gnt_o         (),
    .we_i          (mem_write),
    .be_i          (mem_be),
    .addr_i        (mem_addr),
    .wdata_i       (mem_wdata),
    .wmask_i       (-1),
    .rdata_o       (dbg_rdata),
    .rvalid_o      (dbg_rvalid),
    .rerror_o      (),
              
    // bus host (for system bus accesses, SBA)
//    .tl_h_o        (tl_dm_sba_h_h2d),
//    .tl_h_i        (tl_dm_sba_h_d2h),

    //JTAG
    .tck_i            (jtag_tck_i),
    .tms_i            (jtag_tms_i),
    .trst_ni          (jtag_trst_ni),
    .td_i             (jtag_td_i),
    .td_o             (jtag_td_o),
    .tdo_oe_o         (       )
  );

  // Connect Ibex to SRAM
  always_comb begin
    mem_req        = 1'b0;
    dbg_req        = 1'b0;
    mem_addr       = 32'b0;
    mem_write      = 1'b0;
    mem_be         = 4'b0;
    mem_wdata      = 32'b0;
    if (instr_req) begin
      mem_req        = (instr_addr & ~MEM_MASK) == MEM_START;
      dbg_req        = (instr_addr & ~MEM_MASK) == DBG_START;
      mem_addr       = instr_addr;
    end else if (data_req) begin
      mem_req        = (data_addr & ~MEM_MASK) == MEM_START;
      dbg_req        = (data_addr & ~MEM_MASK) == DBG_START;
      mem_write      = data_we;
      mem_be         = data_be;
      mem_addr       = data_addr;
      mem_wdata      = data_wdata;
    end
  end

  // SRAM block for instruction and data storage
  ram_1p #(
    .Depth(MEM_SIZE / 4)
  ) u_ram (
    .clk_i     ( clk_sys        ),
    .rst_ni    ( rst_sys_n      ),
    .req_i     ( mem_req        ),
    .we_i      ( mem_write      ),
    .be_i      ( mem_be         ),
    .addr_i    ( mem_addr       ),
    .wdata_i   ( mem_wdata      ),
    .rvalid_o  ( mem_rvalid     ),
    .rdata_o   ( mem_rdata      )
  );

  // SRAM to Ibex
  assign data_rdata     = mem_rvalid ? mem_rdata : dbg_rvalid ? dbg_rdata : '0;
  assign instr_rdata    = data_rdata;
  assign instr_rvalid   = mem_rvalid | dbg_rvalid;
  always_ff @(posedge clk_sys or negedge rst_sys_n) begin
    if (!rst_sys_n) begin
      instr_gnt    <= 'b0;
      data_gnt     <= 'b0;
      data_rvalid  <= 'b0;
    end else begin
      instr_gnt    <= instr_req && (mem_req|dbg_req);
      data_gnt     <= ~instr_req && data_req && (mem_req|dbg_req);
      data_rvalid  <= ~instr_req && data_req && (mem_req|dbg_req);
    end
  end

  // Connect the LED output to the lower four bits of the most significant
  // byte
  logic [3:0] leds;
  always_ff @(posedge clk_sys or negedge rst_sys_n) begin
    if (!rst_sys_n) begin
      leds <= 4'b0;
    end else begin
      if (mem_req && data_req && data_we) begin
        for (int i = 0; i < 4; i = i + 1) begin
          if (data_be[i] == 1'b1) begin
            leds <= data_wdata[i*8 +: 4];
          end
        end
      end
    end
  end
  assign GPIO_LED_0 = leds[0];
  assign GPIO_LED_1 = leds[1];
  assign GPIO_LED_2 = leds[2];
  assign GPIO_LED_3 = leds[3];

  // Clock and reset
  clkgen_xilusp
    clkgen(
      .IO_CLK_P(CLK_125_P),
      .IO_CLK_N(CLK_125_N),
      .IO_RST_N(!CPU_RESET),
      .clk_sys,
      .rst_sys_n
    );

endmodule
