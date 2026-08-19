// tb_Command_Parser — drives real serial byte streams into UART_RX through an
// instantiated UART_TX, so the receive path under test is the one that ships,
// and checks the write port the parser presents to the character RAM.
//
// Grid is shrunk from 40x30 so addresses stay readable in the waves.
//
// Coverage: nominal text, each control byte, wrap at the last column, ESC
// cursor positioning, and the malformed cases — unknown bytes, ESC col/row out
// of range, an ESC sequence abandoned partway, and a byte arriving while the
// clear walk is busy.
//
// Self-checking: every expectation goes through CHECK/CHECK_CELL, which tally
// failures in r_Errors. The last line of output is PASS or FAIL.

`timescale 1ns/10ps

module tb_Command_Parser ();

  // 25 MHz clock, 115200 baud => 217 clocks per bit
  localparam c_CLOCK_PERIOD_NS = 40;
  localparam c_CLKS_PER_BIT    = 217;

  localparam c_COLS      = 4;
  localparam c_ROWS      = 3;
  localparam c_ADDR_BITS = 4;
  localparam c_CELLS     = c_COLS * c_ROWS;

  // Bytes the parser treats as commands
  localparam c_LF  = 8'h0A;
  localparam c_CR  = 8'h0D;
  localparam c_FF  = 8'h0C;
  localparam c_ESC = 8'h1B;

  reg  r_Clk = 1'b0;
  always #(c_CLOCK_PERIOD_NS/2) r_Clk <= !r_Clk;

  // UART_TX -> serial wire -> UART_RX
  reg        r_TX_DV   = 1'b0;
  reg  [7:0] r_TX_Byte = 8'h00;
  wire       w_TX_Active, w_TX_Serial, w_TX_Done;

  wire       w_RX_DV;
  wire [7:0] w_RX_Byte;

  wire                   w_Wr_En, w_Busy;
  wire [c_ADDR_BITS-1:0] w_Wr_Addr;
  wire [7:0]             w_Wr_Data;

  // Back-door byte injection, for the one case the serial path cannot produce:
  // a byte landing inside the 12-cycle clear window. See INJECT_BYTE below.
  reg       r_Inject_DV   = 1'b0;
  reg [7:0] r_Inject_Byte = 8'h00;

  wire       w_Parser_DV   = w_RX_DV | r_Inject_DV;
  wire [7:0] w_Parser_Byte = r_Inject_DV ? r_Inject_Byte : w_RX_Byte;

  UART_TX #(.CLKS_PER_BIT(c_CLKS_PER_BIT)) UART_TX_Inst
    (.i_Rst_L     (1'b1),
     .i_Clock     (r_Clk),
     .i_TX_DV     (r_TX_DV),
     .i_TX_Byte   (r_TX_Byte),
     .o_TX_Active (w_TX_Active),
     .o_TX_Serial (w_TX_Serial),
     .o_TX_Done   (w_TX_Done));

  UART_RX #(.CLKS_PER_BIT(c_CLKS_PER_BIT)) UART_RX_Inst
    (.i_Clock     (r_Clk),
     .i_RX_Serial (w_TX_Serial),
     .o_RX_DV     (w_RX_DV),
     .o_RX_Byte   (w_RX_Byte));

  Command_Parser #(.c_COLS(c_COLS), .c_ROWS(c_ROWS), .c_ADDR_BITS(c_ADDR_BITS))
    Parser_Inst
    (.i_Clk     (r_Clk),
     .i_RX_DV   (w_Parser_DV),
     .i_RX_Byte (w_Parser_Byte),
     .o_Wr_En   (w_Wr_En),
     .o_Wr_Addr (w_Wr_Addr),
     .o_Wr_Data (w_Wr_Data),
     .o_Busy    (w_Busy));

  // ---------------------------------------------------------------------
  // Scoreboard: a testbench-side model of what Char_RAM would hold, so the
  // tests can assert on the result instead of on cycle-by-cycle behavior.
  // ---------------------------------------------------------------------

  reg [7:0] r_Shadow [0:c_CELLS-1];
  integer   r_Writes      = 0;   // every write pulse seen, ever
  integer   r_Busy_Cycles = 0;   // every cycle o_Busy was high, ever
  integer   r_Errors      = 0;

  always @(posedge r_Clk) begin
    if (w_Wr_En) begin
      r_Shadow[w_Wr_Addr] <= w_Wr_Data;
      r_Writes = r_Writes + 1;   // blocking, so a check can read it this timestep
    end
    if (w_Busy)
      r_Busy_Cycles = r_Busy_Cycles + 1;
  end

  // ---------------------------------------------------------------------
  // Checking
  // ---------------------------------------------------------------------

  // Prints where each test starts, so the simulation log doubles as an index
  // into dump.vcd when you go looking for something in the waves.
  task MARK;
    input [8*48:1] i_Name;
    begin
      $display("  t=%0d ns : %0s", $time, i_Name);
    end
  endtask

  task CHECK;
    input [8*48:1] i_Name;
    input          i_Cond;
    begin
      if (!i_Cond) begin
        $display("FAIL: %0s at t=%0d ns", i_Name, $time);
        r_Errors = r_Errors + 1;
      end
    end
  endtask

  task CHECK_CELL;
    input integer i_Addr;
    input [7:0]   i_Expect;
    begin
      if (r_Shadow[i_Addr] !== i_Expect) begin
        $display("FAIL: cell %0d holds %02h, expected %02h, at t=%0d ns",
                 i_Addr, r_Shadow[i_Addr], i_Expect, $time);
        r_Errors = r_Errors + 1;
      end
    end
  endtask

  // Every cell blank — used after a clear
  task CHECK_ALL_BLANK;
    integer i;
    begin
      for (i = 0; i < c_CELLS; i = i + 1)
        CHECK_CELL(i, " ");
    end
  endtask

  // ---------------------------------------------------------------------
  // Stimulus
  // ---------------------------------------------------------------------

  // Sends one byte and waits for the transmitter to finish it
  task SEND_BYTE;
    input [7:0] i_Data;
    begin
      @(posedge r_Clk);
      r_TX_Byte <= i_Data;
      r_TX_DV   <= 1'b1;
      @(posedge r_Clk);
      r_TX_DV   <= 1'b0;
      @(posedge w_TX_Done);
    end
  endtask

  // SEND_BYTE plus slack. UART_RX syncs to the middle of the start bit, so its
  // DV pulse actually lands ~109 clocks BEFORE o_TX_Done — the parser has
  // already reacted by the time SEND_BYTE returns. The extra clocks are margin,
  // not a requirement.
  task SEND;
    input [7:0] i_Data;
    begin
      SEND_BYTE(i_Data);
      repeat (20) @(posedge r_Clk);
    end
  endtask

  // Presents a byte straight to the parser with a one-clock DV pulse, exactly
  // as UART_RX would. Bypasses the serial path, so use it only where the serial
  // path physically cannot deliver the timing under test.
  task INJECT_BYTE;
    input [7:0] i_Data;
    begin
      @(posedge r_Clk);
      r_Inject_Byte <= i_Data;
      r_Inject_DV   <= 1'b1;
      @(posedge r_Clk);
      r_Inject_DV   <= 1'b0;
    end
  endtask

  // Known state: screen blank, cursor at (0,0). Only valid once the FF tests
  // below have proven the clear walk actually does that.
  task RESET_SCREEN;
    begin
      SEND(c_FF);
      repeat (c_CELLS + 10) @(posedge r_Clk);
    end
  endtask

  integer i;
  integer r_Writes_Mark;
  integer r_Busy_Mark;

  initial begin
    $dumpfile("dump.vcd");
    $dumpvars(0);

    for (i = 0; i < c_CELLS; i = i + 1)
      r_Shadow[i] = 8'h00;      // 0x00 is a value the parser never writes

    repeat (10) @(posedge r_Clk);
    CHECK("o_Busy low out of reset", w_Busy == 1'b0);

    // -----------------------------------------------------------------
    // 1. One printable byte lands in one cell, with exactly one write
    // -----------------------------------------------------------------
    MARK("1. one character");
    r_Writes_Mark = r_Writes;
    SEND("A");
    CHECK_CELL(0, "A");
    CHECK("one write pulse per character", r_Writes - r_Writes_Mark == 1);

    // -----------------------------------------------------------------
    // 2. A short string fills consecutive cells
    // -----------------------------------------------------------------
    MARK("2. a short string");
    SEND("B");
    SEND("C");
    SEND("D");
    CHECK_CELL(1, "B");
    CHECK_CELL(2, "C");
    CHECK_CELL(3, "D");

    // -----------------------------------------------------------------
    // 3. Wrap: the 5th character on a 4-column grid starts the next row
    // -----------------------------------------------------------------
    MARK("3. wrap at last column");
    SEND("E");
    CHECK_CELL(4, "E");

    // -----------------------------------------------------------------
    // 4. FF blanks every cell, raises o_Busy for exactly c_CELLS cycles,
    //    and leaves the cursor at (0,0)
    // -----------------------------------------------------------------
    MARK("4. FF clear screen");
    r_Writes_Mark = r_Writes;
    r_Busy_Mark   = r_Busy_Cycles;
    SEND(c_FF);
    CHECK("clear writes every cell once", r_Writes - r_Writes_Mark == c_CELLS);
    CHECK("o_Busy high for the whole walk", r_Busy_Cycles - r_Busy_Mark == c_CELLS);
    CHECK("o_Busy low again afterwards", w_Busy == 1'b0);
    CHECK_ALL_BLANK;

    SEND("F");                       // cursor came home
    CHECK_CELL(0, "F");

    // ...and the column counter came home with it, not just the address. The
    // two are redundant state; if only the address resets, the next wrap fires
    // in the wrong place and nothing before this point would notice.
    SEND("G");
    SEND("H");
    SEND("I");
    SEND("J");
    CHECK_CELL(1, "G");
    CHECK_CELL(2, "H");
    CHECK_CELL(3, "I");
    CHECK_CELL(4, "J");              // wrapped after exactly 4 columns

    // -----------------------------------------------------------------
    // 5. LF advances the row and leaves the column alone
    // -----------------------------------------------------------------
    MARK("5. LF");
    RESET_SCREEN;
    SEND("A");                       // cell 0, cursor now column 1
    SEND(c_LF);                      // row 1, column still 1
    SEND("B");
    CHECK_CELL(0, "A");
    CHECK_CELL(5, "B");              // row 1 * 4 + column 1

    // -----------------------------------------------------------------
    // 5b. LF on the last row wraps to row 0, keeping the column
    // -----------------------------------------------------------------
    MARK("5b. LF wraps at last row");
    RESET_SCREEN;
    SEND(c_ESC);
    SEND(8'd1);                      // column 1
    SEND(8'd2);                      // row 2, the last one
    SEND(c_LF);                      // wraps to row 0, column still 1
    SEND("W");
    CHECK_CELL(1, "W");

    // -----------------------------------------------------------------
    // 6. CR returns to column 0 of the same row
    // -----------------------------------------------------------------
    MARK("6. CR");
    RESET_SCREEN;
    SEND("A");
    SEND("B");                       // cells 0,1; cursor at column 2
    SEND(c_CR);                      // back to column 0, still row 0
    SEND("C");
    CHECK_CELL(0, "C");              // overwrites the A
    CHECK_CELL(1, "B");              // and leaves the B alone

    // -----------------------------------------------------------------
    // 7. CR LF together — the sequence a real host sends
    // -----------------------------------------------------------------
    MARK("7. CR LF");
    RESET_SCREEN;
    SEND("A");
    SEND("B");
    SEND(c_CR);
    SEND(c_LF);
    SEND("C");
    CHECK_CELL(4, "C");              // row 1, column 0

    // -----------------------------------------------------------------
    // 8. ESC positions the cursor
    // -----------------------------------------------------------------
    MARK("8. ESC positioning");
    RESET_SCREEN;
    r_Writes_Mark = r_Writes;
    SEND(c_ESC);
    SEND(8'd2);                      // column 2
    SEND(8'd1);                      // row 1
    CHECK("ESC sequence writes nothing", r_Writes - r_Writes_Mark == 0);
    SEND("X");
    CHECK_CELL(6, "X");              // row 1 * 4 + column 2

    // -----------------------------------------------------------------
    // 9. Out-of-range ESC coordinates clamp to the last cell (docs/design.md),
    //    and writing there wraps the cursor back to the origin
    // -----------------------------------------------------------------
    MARK("9. ESC out of range clamps");
    RESET_SCREEN;
    SEND(c_ESC);
    SEND(8'd200);
    SEND(8'd200);
    SEND("Y");
    CHECK_CELL(11, "Y");             // clamped to (3,2)
    SEND("Z");
    CHECK_CELL(0, "Z");              // past the last cell, back to (0,0)

    // -----------------------------------------------------------------
    // 10. Bytes with no meaning are ignored entirely
    // -----------------------------------------------------------------
    MARK("10. meaningless bytes ignored");
    RESET_SCREEN;
    r_Writes_Mark = r_Writes;
    SEND(8'h00);
    SEND(8'h7F);
    SEND(8'h80);
    CHECK("unknown bytes write nothing", r_Writes - r_Writes_Mark == 0);
    CHECK_ALL_BLANK;
    SEND("A");                       // and the cursor never moved
    CHECK_CELL(0, "A");

    // -----------------------------------------------------------------
    // 11. An ESC sequence eats the next two bytes whatever they are: the
    //     printables that follow are coordinates, not characters
    // -----------------------------------------------------------------
    MARK("11. ESC eats two bytes");
    RESET_SCREEN;
    r_Writes_Mark = r_Writes;
    SEND(c_ESC);
    SEND("A");                       // 0x41 = 65, a column, clamps to 3
    SEND("B");                       // 0x42 = 66, a row, clamps to 2
    CHECK("coordinates are not displayed", r_Writes - r_Writes_Mark == 0);
    CHECK_ALL_BLANK;
    SEND("C");                       // the first byte back in IDLE
    CHECK_CELL(11, "C");             // landed at the clamped (3,2)

    // -----------------------------------------------------------------
    // 12. A byte arriving during the clear walk is dropped.
    //
    //     The serial path cannot stage this: a byte occupies 2170 clocks and
    //     the walk is 12, so the clear is long finished before the next byte
    //     completes. That gap is the timing margin argued in docs/design.md.
    //     Injecting the bytes directly is the only way to exercise the case
    //     the FSM defines but the hardware never reaches.
    // -----------------------------------------------------------------
    MARK("12. byte dropped during CLEAR");
    RESET_SCREEN;
    SEND("A");                       // dirty a cell so the clear has work to do
    r_Writes_Mark = r_Writes;

    INJECT_BYTE(c_FF);
    repeat (3) @(posedge r_Clk);
    CHECK("o_Busy high during the walk", w_Busy == 1'b1);
    INJECT_BYTE("Q");                // arrives mid-walk
    repeat (c_CELLS + 10) @(posedge r_Clk);

    CHECK("dropped byte adds no write", r_Writes - r_Writes_Mark == c_CELLS);
    CHECK_ALL_BLANK;                 // no stray Q anywhere

    SEND("R");                       // parser still alive, cursor still home
    CHECK_CELL(0, "R");

    // -----------------------------------------------------------------
    repeat (20) @(posedge r_Clk);
    if (r_Errors == 0)
      $display("PASS - all checks OK");
    else
      $display("FAIL - %0d error(s)", r_Errors);

    $finish;
  end

endmodule
