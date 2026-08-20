`timescale 1ns/10ps

module tb_Font_ROM ();

  localparam c_CLOCK_PERIOD_NS = 40;

  reg r_Clk = 1'b0;
  always #(c_CLOCK_PERIOD_NS/2) r_Clk <= !r_Clk;

  reg  [9:0] r_Addr = 10'd0;
  wire [7:0] w_Data;

  Font_ROM Font_ROM_Inst
    (.i_Clk  (r_Clk),
     .i_Addr (r_Addr),
     .o_Data (w_Data));

  integer r_Errors = 0;
  reg [7:0] r_Check;

  task CHECK;                    // lifted from tb_Command_Parser
    input [8*48:1] i_Name;
    input i_Cond;
    begin
      if (!i_Cond) begin
        $display("FAIL: %0s at t=%0d ns", i_Name, $time);
        r_Errors = r_Errors + 1;
      end
    end
  endtask

  // --- yours: READ, then SHOW_GLYPH ---
  task READ;
    input [9:0] i_Addr; // input address to read from Font_ROM
    output [7:0] o_Data; // output data read from Font_ROM

    begin
      r_Addr <= i_Addr;  // set the address to read from
      @(posedge r_Clk);  // wait for the next clock edge
      #1;
      o_Data = w_Data; // assign the output data to the value read from Font_ROM
    end
  endtask

  task SHOW_GLYPH;
    input [7:0] i_Char;  // the character to show
    integer row, col; // counteres for row and column
    reg [7:0] r_Glyph_Row; // holds the row data for the glyph

    begin
      $display("SHOW_GLYPH for char %c (0x%02X)", i_Char, i_Char);
      for (row = 0; row < 8; row = row + 1) begin // 8 rows per glyph
        READ({i_Char[6:0], row[2:0]}, r_Glyph_Row); // read the glyph row; drop the leading 0 i_Char, given Font_ROM is 7-bit
        for (col = 0; col < 8; col = col + 1) begin // 8 columns per glyph
          if (r_Glyph_Row[col]) $write("#"); else $write("."); // show the pixel
        end
        $display(""); // ends the line for this row
      end
    end
  endtask

  initial begin
    repeat (10) @(posedge r_Clk);

    // --- show some glyphs ---
    SHOW_GLYPH("F");
    SHOW_GLYPH("L");
    SHOW_GLYPH("p");
    SHOW_GLYPH(" ");

    // --- check glyphs ---
    READ({7'h46, 3'd0}, r_Check);
    CHECK("F row 0 is 7F", r_Check === 8'h7F);

    if (r_Errors == 0)
      $display("PASS - all checks OK");
    else
      $display("FAIL - %0d error(s)", r_Errors);

    $finish;
  end

endmodule
