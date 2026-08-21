// tb_Serial_Display_Top — bytes on the serial wire, pixels out.
//
// Every module here already has its own testbench, and each passes. This one
// exists for the failures that only appear when they are joined:
//
//   Command_Parser and Char_Generator BOTH compute row * c_COLS + col,
//   independently, in different modules, from different inputs. If they
//   disagreed by one, every unit test in the project would still pass.
//
// The ESC test below is the only thing that can catch that.
//
// Three things are shrunk so a run takes seconds rather than minutes: the grid
// (3x2), the frame (64x40), and the UART divisor (16 clocks per bit rather than
// 217). The last is the one that matters -- at 217 a single character costs
// 2170 clocks, more than a whole shrunken frame.
//
// Shrinking the divisor does NOT test the clear-walk timing margin. At 16
// clocks per bit a byte occupies 160 clocks and the 3x2 clear walk is 6, a 27x
// margin rather than the 1.8x the real design has. That margin is an argument
// from two datasheet numbers and nothing here measures it.
//
// Assertions are taken at Char_Generator's outputs, reached hierarchically.
// VGA_Sync_Porch sits downstream in the real design but its porch constants are
// hardcoded larger than this whole frame; it is unchanged, hardware-proven, and
// outside what integration can break.

`timescale 1ns/10ps

module tb_Serial_Display_Top ();

  localparam c_CLOCK_PERIOD_NS = 40;
  localparam c_CLKS_PER_BIT    = 16;

  localparam c_VIDEO_WIDTH = 3;
  localparam c_TOTAL_COLS  = 64;
  localparam c_TOTAL_ROWS  = 40;
  localparam c_ACTIVE_COLS = 48;
  localparam c_ACTIVE_ROWS = 32;

  localparam c_COLS      = 3;
  localparam c_ROWS      = 2;
  localparam c_ADDR_BITS = 4;                // blanking reaches address 9
  localparam c_CELLS     = c_COLS * c_ROWS;  // 6

  localparam c_FRAME = c_TOTAL_COLS * c_TOTAL_ROWS;

  localparam c_LF  = 8'h0A;
  localparam c_CR  = 8'h0D;
  localparam c_FF  = 8'h0C;
  localparam c_ESC = 8'h1B;

  reg r_Clk = 1'b0;
  always #(c_CLOCK_PERIOD_NS/2) r_Clk <= !r_Clk;

  integer r_Errors = 0;

  // ---------------------------------------------------------------------
  // A real transmitter driving the real receive path, as in tb_Command_Parser
  // ---------------------------------------------------------------------

  reg        r_TX_DV   = 1'b0;
  reg  [7:0] r_TX_Byte = 8'h00;
  wire       w_TX_Active, w_TX_Serial, w_TX_Done;

  UART_TX #(.CLKS_PER_BIT(c_CLKS_PER_BIT)) UART_TX_Inst
    (.i_Rst_L     (1'b1),
     .i_Clock     (r_Clk),
     .i_TX_DV     (r_TX_DV),
     .i_TX_Byte   (r_TX_Byte),
     .o_TX_Active (w_TX_Active),
     .o_TX_Serial (w_TX_Serial),
     .o_TX_Done   (w_TX_Done));

  Serial_Display_Top #(.c_VIDEO_WIDTH  (c_VIDEO_WIDTH),
                       .c_TOTAL_COLS   (c_TOTAL_COLS),
                       .c_TOTAL_ROWS   (c_TOTAL_ROWS),
                       .c_ACTIVE_COLS  (c_ACTIVE_COLS),
                       .c_ACTIVE_ROWS  (c_ACTIVE_ROWS),
                       .c_COLS         (c_COLS),
                       .c_ROWS         (c_ROWS),
                       .c_ADDR_BITS    (c_ADDR_BITS),
                       .c_CLKS_PER_BIT (c_CLKS_PER_BIT))
  DUT
    (.i_Clk       (r_Clk),
     .i_UART_RX   (w_TX_Serial),
     .o_UART_TX   (),
     .o_Segment1_A(), .o_Segment1_B(), .o_Segment1_C(), .o_Segment1_D(),
     .o_Segment1_E(), .o_Segment1_F(), .o_Segment1_G(),
     .o_Segment2_A(), .o_Segment2_B(), .o_Segment2_C(), .o_Segment2_D(),
     .o_Segment2_E(), .o_Segment2_F(), .o_Segment2_G(),
     .o_VGA_HSync (), .o_VGA_VSync (),
     .o_VGA_Red_0 (), .o_VGA_Red_1 (), .o_VGA_Red_2 (),
     .o_VGA_Grn_0 (), .o_VGA_Grn_1 (), .o_VGA_Grn_2 (),
     .o_VGA_Blu_0 (), .o_VGA_Blu_1 (), .o_VGA_Blu_2 ());

  // ---------------------------------------------------------------------
  // Frame capture, positioned only at the frame boundary
  //
  // Same as tb_Char_Generator: the counter is anchored to the rising edge of
  // the DUT's VSync and free-runs, so a skewed HSync cannot drag the capture
  // along with it.
  // ---------------------------------------------------------------------

  wire w_HSync_CG = DUT.w_HSync_CG;
  wire w_VSync_CG = DUT.w_VSync_CG;
  wire [c_VIDEO_WIDTH-1:0] w_Red_CG = DUT.w_Red_Video_CG;

  reg [c_ACTIVE_COLS-1:0] r_Frame [0:c_ACTIVE_ROWS-1];

  reg [9:0] r_Cap_Col = 0;
  reg [9:0] r_Cap_Row = 0;
  reg       r_VSync_D = 1'b1;

  wire w_Frame_Start = w_VSync_CG & ~r_VSync_D;
  wire w_In_Active   = (r_Cap_Col < c_ACTIVE_COLS) && (r_Cap_Row < c_ACTIVE_ROWS);

  always @(posedge r_Clk)
  begin
    r_VSync_D <= w_VSync_CG;

    if (w_In_Active)
      r_Frame[r_Cap_Row][r_Cap_Col] <= w_Red_CG[0];

    if (w_Frame_Start)
    begin
      r_Cap_Col <= 1;
      r_Cap_Row <= 0;
    end
    else if (r_Cap_Col == c_TOTAL_COLS-1)
    begin
      r_Cap_Col <= 0;
      r_Cap_Row <= (r_Cap_Row == c_TOTAL_ROWS-1) ? 0 : r_Cap_Row + 1;
    end
    else
      r_Cap_Col <= r_Cap_Col + 1;
  end

  // ---------------------------------------------------------------------
  // Expected screen
  //
  // A testbench-side model of what the protocol should have put in each cell.
  // Tests update it as they send, and CHECK_FRAME renders it and compares every
  // pixel -- so a disagreement between the parser's idea of a cell address and
  // the generator's shows up as glyphs in the wrong place.
  // ---------------------------------------------------------------------

  reg [7:0] r_Expect [0:c_CELLS-1];

  // Hardcoded rather than read from Font_ROM: a test that fetches expectations
  // from the design proves the two agree, not that either is right. F and L are
  // asymmetric, so a reversed bit order cannot pass.
  function [7:0] FONT_ROW;
    input [7:0] i_Char;
    input [2:0] i_Row;
    begin
      case (i_Char)
        "F":
          case (i_Row)
            0: FONT_ROW = 8'h7F;  1: FONT_ROW = 8'h46;
            2: FONT_ROW = 8'h16;  3: FONT_ROW = 8'h1E;
            4: FONT_ROW = 8'h16;  5: FONT_ROW = 8'h06;
            6: FONT_ROW = 8'h0F;  7: FONT_ROW = 8'h00;
          endcase
        "L":
          case (i_Row)
            0: FONT_ROW = 8'h0F;  1: FONT_ROW = 8'h06;
            2: FONT_ROW = 8'h06;  3: FONT_ROW = 8'h06;
            4: FONT_ROW = 8'h46;  5: FONT_ROW = 8'h66;
            6: FONT_ROW = 8'h7F;  7: FONT_ROW = 8'h00;
          endcase
        default: FONT_ROW = 8'h00;   // space, and 0x00 at power-up, are blank
      endcase
    end
  endfunction

  // ---------------------------------------------------------------------
  // Checking
  // ---------------------------------------------------------------------

  task MARK;
    input [8*56:1] i_Name;
    begin
      $display("  t=%0d ns : %0s", $time, i_Name);
    end
  endtask

  task CHECK_FRAME;
    input [8*56:1] i_Name;
    integer row, col, cell_num, expect_bit, mismatches;
    reg [7:0] ch;
    begin
      mismatches = 0;
      for (row = 0; row < c_ACTIVE_ROWS; row = row + 1)
        for (col = 0; col < c_ACTIVE_COLS; col = col + 1)
        begin
          cell_num   = (row / 16) * c_COLS + (col / 16);
          ch         = r_Expect[cell_num];
          expect_bit = FONT_ROW(ch, (row / 2) % 8) >> ((col / 2) % 8);

          if (r_Frame[row][col] !== expect_bit[0])
          begin
            if (mismatches < 3)
              $display("FAIL: %0s — pixel (col %0d, row %0d) is %b, expected %b",
                       i_Name, col, row, r_Frame[row][col], expect_bit[0]);
            mismatches = mismatches + 1;
          end
        end

      if (mismatches != 0)
      begin
        $display("FAIL: %0s — %0d pixel(s) wrong at t=%0d ns",
                 i_Name, mismatches, $time);
        r_Errors = r_Errors + 1;
      end
    end
  endtask

  task SHOW_FRAME;
    integer row, col;
    begin
      for (row = 0; row < c_ACTIVE_ROWS; row = row + 1)
      begin
        $write("    ");
        for (col = 0; col < c_ACTIVE_COLS; col = col + 1)
          if (r_Frame[row][col]) $write("#"); else $write(".");
        $display("");
      end
    end
  endtask

  // ---------------------------------------------------------------------
  // Stimulus
  // ---------------------------------------------------------------------

  task SEND;
    input [7:0] i_Data;
    begin
      @(posedge r_Clk);
      r_TX_Byte <= i_Data;
      r_TX_DV   <= 1'b1;
      @(posedge r_Clk);
      r_TX_DV   <= 1'b0;
      @(posedge w_TX_Done);
      repeat (20) @(posedge r_Clk);
    end
  endtask

  // Two whole frames, so the captured image is entirely from after the last
  // byte was acted on.
  task WAIT_FRAMES;
    begin
      repeat (2 * c_FRAME) @(posedge r_Clk);
    end
  endtask

  integer i;

  initial begin
    // Char_RAM comes up zeroed from the bitstream and glyph 0x00 is blank,
    // so an untouched screen is an empty one. See design.md.
    for (i = 0; i < c_CELLS; i = i + 1)
      r_Expect[i] = 8'h00;

    WAIT_FRAMES;

    // -----------------------------------------------------------------
    MARK("1. an untouched screen is blank");
    CHECK_FRAME("power-up blank");

    // -----------------------------------------------------------------
    // The whole system in one test: a byte goes in on a serial wire and a
    // glyph comes out at the right place on the screen.
    MARK("2. two characters land in cells 0 and 1");
    SEND("F");
    SEND("L");
    r_Expect[0] = "F";
    r_Expect[1] = "L";
    WAIT_FRAMES;
    CHECK_FRAME("FL at the origin");

    // -----------------------------------------------------------------
    MARK("3. form feed clears the screen");
    SEND(c_FF);
    for (i = 0; i < c_CELLS; i = i + 1)
      r_Expect[i] = " ";
    WAIT_FRAMES;
    CHECK_FRAME("blank after FF");

    // -----------------------------------------------------------------
    // THE test. Command_Parser turns (col, row) into an address; Char_Generator
    // turns a pixel back into the same address. Both compute
    // row * c_COLS + col from different inputs, and nothing else in the project
    // can catch them disagreeing.
    MARK("4. ESC positions the cursor where the generator reads");
    SEND(c_ESC);
    SEND(8'd2);              // column 2
    SEND(8'd1);              // row 1
    SEND("F");
    r_Expect[1*c_COLS + 2] = "F";
    WAIT_FRAMES;
    CHECK_FRAME("F at (col 2, row 1)");
    SHOW_FRAME;

    // -----------------------------------------------------------------
    MARK("5. a byte with no meaning changes nothing");
    SEND(8'h00);
    SEND(8'h7F);
    WAIT_FRAMES;
    CHECK_FRAME("unchanged by ignored bytes");

    // -----------------------------------------------------------------
    // Writing the last cell in test 4 wrapped the cursor back to (0,0), so
    // this starts from there: write cell 0, return to column 0, overwrite it.
    MARK("6. CR returns to column 0, and writing there overwrites");
    SEND("F");               // cell 0
    SEND(c_CR);              // back to column 0
    SEND("L");               // overwrites cell 0
    r_Expect[0] = "L";
    WAIT_FRAMES;
    CHECK_FRAME("CR overwrote cell 0");

    // -----------------------------------------------------------------
    repeat (8) @(posedge r_Clk);
    if (r_Errors == 0)
      $display("PASS - all checks OK");
    else
      $display("FAIL - %0d error(s)", r_Errors);

    $finish;
  end

endmodule
