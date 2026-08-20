// tb_Char_Generator — captures the frame the generator paints and compares it
// against the image those characters should produce.
//
// The property under test is the one a monitor cannot show you: that the video
// and the sync pulses leaving Char_Generator describe the SAME pixel. A three-
// pixel skew out of 640 is an eighth of a character cell, invisible through a
// monitor that does its own centering, so it has to be asserted here.
//
// The trick is that the capture below derives its position from the DUT's OWN
// sync outputs, exactly as VGA_Sync_Porch does downstream. It never assumes a
// pipeline depth. If the video is skewed from the syncs by even one clock, the
// whole captured image shifts and every comparison fails.
//
// Geometry is shrunk to a 3x2 character grid so a frame is 2560 clocks instead
// of 420,000. VGA_Sync_Porch is deliberately NOT instantiated: its porch
// constants are hardcoded at 18/50/10/33, larger than this whole frame, and it
// is not what is under test.

`timescale 1ns/10ps

module tb_Char_Generator ();

  localparam c_CLOCK_PERIOD_NS = 40;

  // Shrunken frame. Cells stay 16 pixels, so 48x32 active = a 3x2 grid.
  localparam c_VIDEO_WIDTH = 3;
  localparam c_TOTAL_COLS  = 64;
  localparam c_TOTAL_ROWS  = 40;
  localparam c_ACTIVE_COLS = 48;
  localparam c_ACTIVE_ROWS = 32;

  localparam c_COLS      = 3;
  localparam c_ROWS      = 2;
  localparam c_ADDR_BITS = 4;               // blanking reaches address 9
  localparam c_CELLS     = c_COLS * c_ROWS; // 6

  localparam c_FRAME = c_TOTAL_COLS * c_TOTAL_ROWS;

  reg r_Clk = 1'b0;
  always #(c_CLOCK_PERIOD_NS/2) r_Clk <= !r_Clk;

  integer r_Errors = 0;

  // ---------------------------------------------------------------------
  // The design under test, with a stand-in for Char_RAM
  // ---------------------------------------------------------------------

  wire w_HSync_Start, w_VSync_Start;

  VGA_Sync_Pulses #(.TOTAL_COLS(c_TOTAL_COLS),
                    .TOTAL_ROWS(c_TOTAL_ROWS),
                    .ACTIVE_COLS(c_ACTIVE_COLS),
                    .ACTIVE_ROWS(c_ACTIVE_ROWS))
  VGA_Sync_Pulses_Inst
    (.i_Clk       (r_Clk),
     .o_HSync     (w_HSync_Start),
     .o_VSync     (w_VSync_Start),
     .o_Col_Count (),
     .o_Row_Count ());

  wire [c_ADDR_BITS-1:0]   w_Rd_Addr;
  wire                     w_HSync_CG, w_VSync_CG;
  wire [c_VIDEO_WIDTH-1:0] w_Red_Video, w_Grn_Video, w_Blu_Video;

  // Stand-in for Char_RAM: a plain array with the same one-clock read latency.
  // Sized to the full address space, because addresses computed during
  // blanking run past the 6 live cells.
  reg [7:0] r_Stub [0:(1<<c_ADDR_BITS)-1];
  reg [7:0] r_Rd_Data;

  always @(posedge r_Clk)
    r_Rd_Data <= r_Stub[w_Rd_Addr];

  Char_Generator #(.VIDEO_WIDTH(c_VIDEO_WIDTH),
                   .TOTAL_COLS(c_TOTAL_COLS),
                   .TOTAL_ROWS(c_TOTAL_ROWS),
                   .ACTIVE_COLS(c_ACTIVE_COLS),
                   .ACTIVE_ROWS(c_ACTIVE_ROWS),
                   .c_COLS(c_COLS),
                   .c_ROWS(c_ROWS),
                   .c_ADDR_BITS(c_ADDR_BITS))
  Char_Generator_Inst
    (.i_Clk       (r_Clk),
     .i_HSync     (w_HSync_Start),
     .i_VSync     (w_VSync_Start),
     .o_Rd_Addr   (w_Rd_Addr),
     .i_Rd_Data   (r_Rd_Data),
     .o_HSync     (w_HSync_CG),
     .o_VSync     (w_VSync_CG),
     .o_Red_Video (w_Red_Video),
     .o_Grn_Video (w_Grn_Video),
     .o_Blu_Video (w_Blu_Video));

  reg r_Armed = 1'b0;

  // ---------------------------------------------------------------------
  // Frame capture, and the sync assertions
  //
  // The position counter is anchored ONLY at the frame boundary (the rising
  // edge of the DUT's VSync) and free-runs from there. An earlier version
  // advanced the column on HSync, which was a mistake: a skewed HSync dragged
  // the capture along with it and hid the very skew being looked for. That
  // version passed a mutation with HSync delayed by two stages instead of
  // three.
  //
  // So HSync is not used to position anything. It is asserted against the
  // counter instead, which tests it directly rather than hoping a shifted
  // image falls out.
  // ---------------------------------------------------------------------

  reg [c_ACTIVE_COLS-1:0] r_Frame [0:c_ACTIVE_ROWS-1];

  reg [9:0] r_Cap_Col = 0;
  reg [9:0] r_Cap_Row = 0;
  reg       r_VSync_D = 1'b1;

  wire w_Frame_Start = w_VSync_CG & ~r_VSync_D;
  wire w_In_Active   = (r_Cap_Col < c_ACTIVE_COLS) && (r_Cap_Row < c_ACTIVE_ROWS);

  always @(posedge r_Clk)
  begin
    r_VSync_D <= w_VSync_CG;

    // r_Cap_Col / r_Cap_Row describe the pixel on THIS clock edge
    if (w_In_Active)
      r_Frame[r_Cap_Row][r_Cap_Col] <= w_Red_Video[0];

    // The syncs must agree with where the counter says we are. This is what
    // catches a sync delayed by the wrong number of pipeline stages.
    if (r_Armed)
    begin
      if (w_HSync_CG !== (r_Cap_Col < c_ACTIVE_COLS))
      begin
        $display("FAIL: HSync is %b at column %0d, expected %b, t=%0d ns",
                 w_HSync_CG, r_Cap_Col, (r_Cap_Col < c_ACTIVE_COLS), $time);
        r_Errors = r_Errors + 1;
        r_Armed  = 1'b0;
      end
      else if (w_VSync_CG !== (r_Cap_Row < c_ACTIVE_ROWS))
      begin
        $display("FAIL: VSync is %b at row %0d, expected %b, t=%0d ns",
                 w_VSync_CG, r_Cap_Row, (r_Cap_Row < c_ACTIVE_ROWS), $time);
        r_Errors = r_Errors + 1;
        r_Armed  = 1'b0;
      end
    end

    // advance
    if (w_Frame_Start)
    begin
      r_Cap_Col <= 1;                       // this cycle was (0,0)
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
  // Continuous check: nothing is ever painted outside the live area.
  //
  // This is the one alignment failure that IS visible on a monitor, as a
  // garbage stripe down a screen edge, and it catches a blanking flag that
  // was delayed by the wrong number of stages.
  // ---------------------------------------------------------------------

  always @(posedge r_Clk)
    if (r_Armed && !(w_HSync_CG && w_VSync_CG) &&
        (w_Red_Video !== 0 || w_Grn_Video !== 0 || w_Blu_Video !== 0))
    begin
      $display("FAIL: video is %b outside the active area at t=%0d ns",
               w_Red_Video, $time);
      r_Errors = r_Errors + 1;
      r_Armed  = 1'b0;          // report once, not every blanked pixel
    end

  // ---------------------------------------------------------------------
  // Continuous check: every channel is fully on or fully off, and all three
  // agree. V1 is monochrome white on black, so 3'b001 -- a bare pixel bit
  // assigned to a 3-bit channel instead of being replicated -- is a bug that
  // shows up as a dim grey image and is easy to blame on the cable.
  // ---------------------------------------------------------------------

  always @(posedge r_Clk)
    if (r_Armed &&
        (w_Red_Video !== w_Grn_Video || w_Red_Video !== w_Blu_Video ||
         (w_Red_Video !== {c_VIDEO_WIDTH{1'b0}} &&
          w_Red_Video !== {c_VIDEO_WIDTH{1'b1}})))
    begin
      $display("FAIL: video is R=%b G=%b B=%b, expected all-on or all-off, t=%0d ns",
               w_Red_Video, w_Grn_Video, w_Blu_Video, $time);
      r_Errors = r_Errors + 1;
      r_Armed  = 1'b0;
    end

  // ---------------------------------------------------------------------
  // Expected data
  //
  // The bitmaps are hardcoded rather than read from Font_ROM. A test that
  // fetches its expectations from the thing under test proves the two agree,
  // not that either is right — and a wrong font ROM is one of the failures
  // this is meant to catch.
  //
  // F and L are both left-right asymmetric on purpose: A, H, I, M, O, T and X
  // all render identically under a reversed bit order and would pass a
  // mirrored implementation.
  // ---------------------------------------------------------------------

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
        "*":
          case (i_Row)
            0: FONT_ROW = 8'h00;  1: FONT_ROW = 8'h66;
            2: FONT_ROW = 8'h3C;  3: FONT_ROW = 8'hFF;
            4: FONT_ROW = 8'h3C;  5: FONT_ROW = 8'h66;
            6: FONT_ROW = 8'h00;  7: FONT_ROW = 8'h00;
          endcase
        "_":
          case (i_Row)
            0: FONT_ROW = 8'h00;  1: FONT_ROW = 8'h00;
            2: FONT_ROW = 8'h00;  3: FONT_ROW = 8'h00;
            4: FONT_ROW = 8'h00;  5: FONT_ROW = 8'h00;
            6: FONT_ROW = 8'h00;  7: FONT_ROW = 8'hFF;
          endcase
        default: FONT_ROW = 8'h00;      // space, and anything else, is blank
      endcase
    end
  endfunction

  // ---------------------------------------------------------------------
  // Checking
  // ---------------------------------------------------------------------

  task MARK;
    input [8*48:1] i_Name;
    begin
      $display("  t=%0d ns : %0s", $time, i_Name);
    end
  endtask

  // Compares the whole captured frame against the image r_Stub should produce.
  // One task covers glyph shape, cell position, blank cells and cell
  // boundaries at once, because every pixel is checked against first
  // principles rather than against a handful of spot values.
  task CHECK_FRAME;
    input [8*48:1] i_Name;
    integer row, col, cell_num, expect_bit, mismatches;
    reg [7:0] ch;
    begin
      mismatches = 0;

      for (row = 0; row < c_ACTIVE_ROWS; row = row + 1)
        for (col = 0; col < c_ACTIVE_COLS; col = col + 1)
        begin
          cell_num = (row / 16) * c_COLS + (col / 16);
          ch   = r_Stub[cell_num];
          expect_bit = FONT_ROW(ch, (row / 2) % 8) >> ((col / 2) % 8);

          if (r_Frame[row][col] !== expect_bit[0])
          begin
            if (mismatches < 4)
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

  // Prints the captured frame, so a failure can be looked at rather than
  // deduced from coordinates.
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

  task LOAD;
    input integer i_Cell;
    input [7:0]   i_Char;
    begin
      r_Stub[i_Cell] = i_Char;
    end
  endtask

  task BLANK_ALL;
    integer i;
    begin
      for (i = 0; i < (1<<c_ADDR_BITS); i = i + 1)
        r_Stub[i] = " ";
    end
  endtask

  // Two whole frames, so the captured image is guaranteed to be entirely
  // from after the stub was last changed.
  task WAIT_FRAMES;
    begin
      repeat (2 * c_FRAME) @(posedge r_Clk);
    end
  endtask

  // ---------------------------------------------------------------------
  // Tests
  // ---------------------------------------------------------------------

  initial begin
    BLANK_ALL;
    WAIT_FRAMES;
    r_Armed = 1'b1;          // registers have settled; start policing blanking

    MARK("1. an empty screen is entirely blank");
    WAIT_FRAMES;
    CHECK_FRAME("all spaces");

    MARK("2. one glyph in the first cell");
    LOAD(0, "F");
    WAIT_FRAMES;
    CHECK_FRAME("F at cell 0");

    MARK("3. a glyph in the last cell, where the address arithmetic ends");
    BLANK_ALL;
    LOAD(c_CELLS-1, "F");
    WAIT_FRAMES;
    CHECK_FRAME("F at the last cell");

    MARK("4. two different glyphs in adjacent cells");
    BLANK_ALL;
    LOAD(0, "F");
    LOAD(1, "L");
    WAIT_FRAMES;
    CHECK_FRAME("F then L");

    // Glyphs chosen for their edges, not their looks. In this font only '*'
    // and '_' ever light a cell's outermost pixel -- every letter leaves
    // column 7 blank for inter-character spacing. With F and L alone, the
    // pixel beside the blanking boundary is always dark, so a blanking flag
    // delayed by the wrong number of stages changes nothing observable. This
    // testbench passed exactly that mutation until these two were added.
    //
    //   '*' row 3 is 0xFF  -> lights glyph columns 0 and 7, so screen columns
    //                         0 and 47: both horizontal blanking boundaries
    //   '_' row 7 is 0xFF  -> lights the last glyph row, so screen rows 30-31:
    //                         the vertical blanking boundary
    MARK("5. every cell filled, with lit pixels against every screen edge");
    LOAD(0, "*"); LOAD(1, "F"); LOAD(2, "*");
    LOAD(3, "_"); LOAD(4, "L"); LOAD(5, "_");
    WAIT_FRAMES;
    CHECK_FRAME("full screen, edges lit");
    SHOW_FRAME;

    MARK("6. the next frame is identical — the generator holds no frame state");
    WAIT_FRAMES;
    CHECK_FRAME("second frame");

    if (r_Errors == 0)
      $display("PASS - all checks OK");
    else
      $display("FAIL - %0d error(s)", r_Errors);

    $finish;
  end

endmodule
