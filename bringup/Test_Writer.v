// Test_Writer — walks every cell of Char_RAM once, writing a known message,
// then stops forever.
//
// Scaffolding. It drives exactly the three signals Command_Parser drives —
// an address, a byte, and a write enable — so that on integration day one
// instantiation is swapped for the other and nothing else changes. Today it
// means the display is driven by something whose behaviour is already known,
// which keeps pixel bugs separable from protocol bugs.
//
// Deleted once Serial_Display_Top works.

module Test_Writer
  #(parameter c_ADDR_BITS = 11,
    parameter c_CELLS     = 1200)
   (input  wire i_Clk,
    output wire o_Wr_En,
    output wire [c_ADDR_BITS-1:0] o_Wr_Addr,
    output wire [7:0]             o_Wr_Data);

  // Four full 40-column rows. The message runs past the end of a row on
  // purpose: the writer counts linearly and the generator computes
  // row * c_COLS + col, so the text continuing exactly where it should is those
  // two agreeing about where the next row begins.
  //
  // The startup hold below matters: without it the first ~50 cells never take
  // their data on hardware and rows 0 and 1 come up partly blank.
  //
  // c_LEN must equal the characters actually supplied, so the blank rows are
  // not padding to trim. A shortfall becomes zero bytes on the left and shifts
  // every character right by that many cells, breaking the message across rows
  // unless the shortfall happens to be a multiple of 40. Nothing warns.
  localparam integer c_LEN = 80;
  localparam [8*c_LEN-1:0] c_MSG =
    {"CHAR_RAM WRITE TEST - LINE 0 OF THE DEMO",
     "AND LINE 1 CONTINUES FROM ADDRESS 40    "};

  reg [c_ADDR_BITS-1:0] r_Count = 0;
  reg                   r_Done  = 1'b0;

  // Hold the walk off for 4096 clocks (164 us) after configuration.
  //
  // Writing from the first clock edge loses roughly the first 50 cells on
  // hardware, and only on hardware -- simulation has no configuration phase.
  // Lattice documents that EBR contents are write-protected during
  // configuration, and that configuration is not finished when the design
  // starts running: 49 further SPI clocks are needed after CDONE goes high.
  // Writes issued in that window are dropped silently. See verification.md.
  //
  // Command_Parser needs no equivalent: it cannot write until a UART byte
  // arrives, which is thousands of clocks past this window. Test_Writer is
  // unusual only because it starts on clock one.
  reg [11:0] r_Startup = 0;
  wire       w_Ready   = &r_Startup;

  // One pass over every cell, then stop. It matters that it stops: a writer
  // that looped would look identical on screen and would hide a Char_RAM that
  // fails to hold data, because the display would just be repainted forever.
  always @(posedge i_Clk)
  begin
    if (!w_Ready)
      r_Startup <= r_Startup + 1'b1;
    else if (!r_Done)
    begin
      r_Count <= r_Count + 1'b1;
      if (r_Count == c_CELLS-1)
        r_Done <= 1'b1;
    end
  end

  // The message, then spaces for the remaining 1120 cells. The default is what
  // makes this write the whole screen, so what is on the monitor is entirely
  // determined by this module rather than partly by whatever the bitstream
  // left in the memory.
  //
  // Verilog packs a string literal with its first character in the highest
  // bits, so character n sits at [(c_LEN - n)*8-1 -: 8].
  //
  // A continuous assignment rather than always @(*) on purpose: an always block
  // needs an event on its sensitivity list to run, and at time zero nothing has
  // changed -- r_Count was initialised to 0, it never transitioned to 0. So the
  // block would not execute before the first clock edge and cell 0 would be
  // written with whatever the register was initialised to. Continuous
  // assignments are active from time zero.
  wire [7:0] w_Char = (r_Count < c_LEN) ? c_MSG[(c_LEN - r_Count)*8-1 -: 8]
                                        : " ";

  // Combinational, unlike Command_Parser's registered write port. Char_RAM
  // samples all three on the clock edge, so at the edge where the counter holds
  // N the memory sees address N with the data for cell N. Same contract at the
  // boundary, reached differently.
  assign o_Wr_En   = w_Ready & ~r_Done;
  assign o_Wr_Addr = r_Count;
  assign o_Wr_Data = w_Char;

endmodule
