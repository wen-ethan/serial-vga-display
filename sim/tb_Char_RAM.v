// tb_Char_RAM — the character memory's two ports, and the one clock of read
// latency the whole render pipeline is built around.
//
// The module is ten lines and synthesis already confirms it maps to four EBRs,
// so what is left to check is behaviour the utilisation report cannot show:
// that the read really is one clock behind the address, that the two ports are
// independent, and that a read of the cell being written returns the old byte.
// That last one is the property that makes "dual-port" mean something, and it
// is what docs/design.md claims when it argues no arbitration is needed.
//
// Address space is shrunk to 4 bits (16 cells) so every cell can be written and
// read back exhaustively, which catches address decoding that aliases.

`timescale 1ns/10ps

module tb_Char_RAM ();

  localparam c_CLOCK_PERIOD_NS = 40;
  localparam c_ADDR_BITS       = 4;
  localparam c_CELLS           = 1 << c_ADDR_BITS;   // 16

  reg r_Clk = 1'b0;
  always #(c_CLOCK_PERIOD_NS/2) r_Clk <= !r_Clk;

  integer r_Errors = 0;

  reg                   r_Wr_En   = 1'b0;
  reg [c_ADDR_BITS-1:0] r_Wr_Addr = 0;
  reg [7:0]             r_Wr_Data = 8'h00;
  reg [c_ADDR_BITS-1:0] r_Rd_Addr = 0;
  wire [7:0]            w_Rd_Data;

  Char_RAM #(.c_ADDR_BITS(c_ADDR_BITS), .c_DATA_BITS(8)) Char_RAM_Inst
    (.i_Clk     (r_Clk),
     .i_Wr_En   (r_Wr_En),
     .i_Wr_Addr (r_Wr_Addr),
     .i_Wr_Data (r_Wr_Data),
     .i_Rd_Addr (r_Rd_Addr),
     .o_Rd_Data (w_Rd_Data));

  // ---------------------------------------------------------------------
  // Checking
  // ---------------------------------------------------------------------

  task MARK;
    input [8*56:1] i_Name;
    begin
      $display("  t=%0d ns : %0s", $time, i_Name);
    end
  endtask

  task CHECK;
    input [8*56:1] i_Name;
    input          i_Cond;
    begin
      if (!i_Cond)
      begin
        $display("FAIL: %0s at t=%0d ns", i_Name, $time);
        r_Errors = r_Errors + 1;
      end
    end
  endtask

  // ---------------------------------------------------------------------
  // Stimulus
  // ---------------------------------------------------------------------

  // Exactly one write. The values are scheduled on one edge and sampled by the
  // memory on the next, then the enable drops, so o_Wr_En is high for a single
  // cycle -- the same shape Command_Parser's write port produces.
  task WRITE;
    input [c_ADDR_BITS-1:0] i_A;
    input [7:0]             i_D;
    begin
      @(posedge r_Clk);
      r_Wr_En   <= 1'b1;
      r_Wr_Addr <= i_A;
      r_Wr_Data <= i_D;
      @(posedge r_Clk);
      r_Wr_En   <= 1'b0;
    end
  endtask

  // A read costs a clock, and the #1 steps past the edge so the nonblocking
  // update has landed before the value is copied out. Same idiom, same reason,
  // as tb_Font_ROM: the latency lives in one task and nothing above it has to
  // know the memory has any.
  task READ;
    input  [c_ADDR_BITS-1:0] i_A;
    output [7:0]             o_D;
    begin
      r_Rd_Addr <= i_A;
      @(posedge r_Clk);
      #1;
      o_D = w_Rd_Data;
    end
  endtask

  integer   i;
  reg [7:0] r_D;

  initial begin
    // -----------------------------------------------------------------
    MARK("1. a byte written is the byte read back");
    WRITE(4'h3, 8'hA5);
    READ (4'h3, r_D);
    CHECK("cell 3 holds A5", r_D === 8'hA5);

    // -----------------------------------------------------------------
    // The read is registered, so presenting an address is not the same as
    // having the data. Checking both sides of the edge is what distinguishes
    // a one-clock read from a combinational one -- and a combinational read
    // is the version that does not fit on this part at all.
    MARK("2. data arrives exactly one clock after the address");
    WRITE(4'h7, 8'h5A);
    READ (4'h3, r_D);                 // park on cell 3, holding A5

    r_Rd_Addr <= 4'h7;                // present cell 7's address...
    #1;
    CHECK("still the old byte before the edge", w_Rd_Data === 8'hA5);
    @(posedge r_Clk);
    #1;
    CHECK("the new byte after one edge", w_Rd_Data === 8'h5A);

    // -----------------------------------------------------------------
    // Every cell, distinct value. An address decode that aliased two cells
    // would pass a single-cell test and fail here.
    MARK("3. all 16 cells hold distinct values, no aliasing");
    for (i = 0; i < c_CELLS; i = i + 1)
      WRITE(i[c_ADDR_BITS-1:0], 8'h10 + i[7:0]);
    for (i = 0; i < c_CELLS; i = i + 1)
    begin
      READ(i[c_ADDR_BITS-1:0], r_D);
      CHECK("cell holds its own value", r_D === 8'h10 + i[7:0]);
    end

    // -----------------------------------------------------------------
    MARK("4. a write with the enable low changes nothing");
    @(posedge r_Clk);
    r_Wr_En   <= 1'b0;
    r_Wr_Addr <= 4'h3;
    r_Wr_Data <= 8'hFF;
    @(posedge r_Clk);
    READ(4'h3, r_D);
    CHECK("cell 3 untouched", r_D === 8'h13);

    // -----------------------------------------------------------------
    // The reason this is a dual-port memory. In the real design the generator
    // reads a cell every clock while the parser occasionally writes a
    // different one, and nothing arbitrates between them.
    MARK("5. writing one cell while reading another, same cycle");
    r_Rd_Addr <= 4'h9;                // read cell 9 ...
    @(posedge r_Clk);
    r_Wr_En   <= 1'b1;                // ... while writing cell 2
    r_Wr_Addr <= 4'h2;
    r_Wr_Data <= 8'hC3;
    @(posedge r_Clk);
    #1;
    CHECK("the read is unaffected by the write", w_Rd_Data === 8'h19);
    r_Wr_En <= 1'b0;
    READ(4'h2, r_D);
    CHECK("the write landed", r_D === 8'hC3);

    // -----------------------------------------------------------------
    // Read-during-write on the SAME address. The read returns the old byte,
    // which is what design.md relies on when it says one wrong character for
    // one frame is the whole cost and no logic is spent on it.
    MARK("6. reading the cell being written returns the old byte");
    r_Rd_Addr <= 4'h5;
    @(posedge r_Clk);
    r_Wr_En   <= 1'b1;
    r_Wr_Addr <= 4'h5;
    r_Wr_Data <= 8'hEE;
    @(posedge r_Clk);
    #1;
    CHECK("old byte during the write", w_Rd_Data === 8'h15);
    r_Wr_En <= 1'b0;
    READ(4'h5, r_D);
    CHECK("new byte on the next read", r_D === 8'hEE);

    // -----------------------------------------------------------------
    repeat (4) @(posedge r_Clk);
    if (r_Errors == 0)
      $display("PASS - all checks OK");
    else
      $display("FAIL - %0d error(s)", r_Errors);

    $finish;
  end

endmodule
