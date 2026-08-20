// Char_Generator — VGA coordinates in, character pixels out.
//
// For every pixel the monitor asks for, this module answers "lit or not?" with
// two chained memory lookups:
//
//   where is the beam? -> which cell?      -> Char_RAM -> which character?
//                      -> which font pixel? -> Font_ROM -> is that bit set?
//
// Each lookup costs a clock, so this is a three-stage pipeline: the Char_RAM
// read register, the Font_ROM read register, and the output register here.
// HSync and VSync are delayed by the same three clocks, because every module in
// the video chain has to hand the next one video and syncs that describe the
// same pixel. See docs/design.md.
//
// Font_ROM is instantiated here because nothing else in the design wants glyph
// bits. Char_RAM is external, because Command_Parser writes to it.

`default_nettype none

module Char_Generator
  #(parameter VIDEO_WIDTH = 3,
    parameter TOTAL_COLS  = 800, parameter TOTAL_ROWS  = 525,
    parameter ACTIVE_COLS = 640, parameter ACTIVE_ROWS = 480,
    parameter c_COLS = 40, parameter c_ROWS = 30,
    parameter c_ADDR_BITS = 11)
   (input  wire i_Clk,
    input  wire i_HSync,
    input  wire i_VSync,

    // Character RAM read port
    output wire [c_ADDR_BITS-1:0] o_Rd_Addr,
    input  wire [7:0]             i_Rd_Data,   // arrives one clock after the address

    output reg  o_HSync,
    output reg  o_VSync,
    output reg [VIDEO_WIDTH-1:0] o_Red_Video,
    output reg [VIDEO_WIDTH-1:0] o_Grn_Video,
    output reg [VIDEO_WIDTH-1:0] o_Blu_Video);

  // ---------------------------------------------------------------------
  // Cycle 0 — where the beam is
  // ---------------------------------------------------------------------

  wire       w_HSync, w_VSync;
  wire [9:0] w_Col_Count, w_Row_Count;

  Sync_To_Count #(.TOTAL_COLS(TOTAL_COLS),
                  .TOTAL_ROWS(TOTAL_ROWS))
  Sync_To_Count_Inst
    (.i_Clk       (i_Clk),
     .i_HSync     (i_HSync),
     .i_VSync     (i_VSync),
     .o_HSync     (w_HSync),
     .o_VSync     (w_VSync),
     .o_Col_Count (w_Col_Count),
     .o_Row_Count (w_Row_Count));

  // Cells are 16 pixels wide, so the cell index is the pixel index with the
  // bottom four bits dropped. Those four bits are the position inside the cell;
  // one more is dropped for the 2x glyph scale. Bit [0] is never read by
  // anything, and that is the entire scaler.
  wire [5:0] w_Cell_Col  = w_Col_Count[9:4];   // 0..39 live, up to 49 blanking
  wire [5:0] w_Cell_Row  = w_Row_Count[9:4];   // 0..29 live, up to 32 blanking
  wire [2:0] w_Glyph_Col = w_Col_Count[3:1];   // 0..7
  wire [2:0] w_Glyph_Row = w_Row_Count[3:1];   // 0..7

  // Blanking has to be decided from the counts, never from the address: during
  // horizontal blanking the address below aliases onto real cells of the next
  // row, so a blanking address is indistinguishable from a live one.
  wire w_Blank = (w_Col_Count >= ACTIVE_COLS) || (w_Row_Count >= ACTIVE_ROWS);

  // The beam position is already a counter, so the address is a pure function
  // of it and needs no state of its own — the opposite of Command_Parser,
  // whose address IS state. c_COLS is constant, so row * 40 is row * 32 +
  // row * 8: two shifts and an add, not a multiplier. Widest value is
  // 32 * 40 + 49 = 1329, which fits in 11 bits.
  assign o_Rd_Addr = w_Cell_Row * c_COLS + w_Cell_Col;

  // ---------------------------------------------------------------------
  // The pipeline
  //
  // Everything a later cycle needs is registered forward once per cycle it has
  // to survive:
  //
  //   glyph row     1 register    consumed by the font ROM address
  //   glyph column  2 registers   consumed by the bit select
  //   blanking      2 registers   consumed by the pixel gate
  //   syncs         3 registers   must match the video path exactly
  //
  // The cell column and row need none: they are consumed in cycle 0 to form
  // the address.
  // ---------------------------------------------------------------------

  reg [2:0] r_Glyph_Row_1;
  reg [2:0] r_Glyph_Col_1, r_Glyph_Col_2;
  reg       r_Blank_1,     r_Blank_2;
  reg       r_HSync_1,     r_HSync_2;
  reg       r_VSync_1,     r_VSync_2;

  always @(posedge i_Clk)
  begin
    // cycle 0 -> 1
    r_Glyph_Row_1 <= w_Glyph_Row;
    r_Glyph_Col_1 <= w_Glyph_Col;
    r_Blank_1     <= w_Blank;
    r_HSync_1     <= w_HSync;
    r_VSync_1     <= w_VSync;

    // cycle 1 -> 2  (the glyph row is consumed at cycle 1 and stops here)
    r_Glyph_Col_2 <= r_Glyph_Col_1;
    r_Blank_2     <= r_Blank_1;
    r_HSync_2     <= r_HSync_1;
    r_VSync_2     <= r_VSync_1;
  end

  // ---------------------------------------------------------------------
  // Cycle 1 — the character is in hand, ask the font ROM
  // ---------------------------------------------------------------------

  // A character is 8 bits because bytes are 8 bits; a glyph index is 7 bits
  // because the ROM holds 128 glyphs. Command_Parser only ever writes
  // 0x20..0x7E, so bit 7 is always zero. Pure concatenation, no adder.
  wire [7:0] w_Glyph;

  Font_ROM Font_ROM_Inst
    (.i_Clk  (i_Clk),
     .i_Addr ({i_Rd_Data[6:0], r_Glyph_Row_1}),
     .o_Data (w_Glyph));

  // ---------------------------------------------------------------------
  // Cycle 2 — pick the pixel.  Cycle 3 — drive it.
  // ---------------------------------------------------------------------

  // Bit 0 is the leftmost pixel of a glyph row, so the column index counts up
  // from the left edge of the cell. Indexing [7-col] would mirror every glyph.
  wire w_Pixel = w_Glyph[r_Glyph_Col_2] & ~r_Blank_2;

  always @(posedge i_Clk)
  begin
    // V1 is monochrome: each channel gets the same bit, replicated to fill the
    // width. Assigning the bare bit would give 3'b001 — one seventh brightness
    // — instead of white.
    o_Red_Video <= {VIDEO_WIDTH{w_Pixel}};
    o_Grn_Video <= {VIDEO_WIDTH{w_Pixel}};
    o_Blu_Video <= {VIDEO_WIDTH{w_Pixel}};

    o_HSync     <= r_HSync_2;
    o_VSync     <= r_VSync_2;
  end

endmodule

// Restore the default so designs in common/ and bringup/ that rely on implicit
// net declarations still compile when they are handed to the tools after this
// file.
`default_nettype wire
