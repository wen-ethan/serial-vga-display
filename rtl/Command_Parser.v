// Command_Parser — UART bytes in, cursor state and character-RAM writes out.
//
// Protocol:
//   0x20..0x7E     write char at cursor, advance, wrap at the last column
//   0x0A LF        cursor to next row
//   0x0D CR        cursor to column 0
//   0x0C FF        clear screen (walks every cell; parser is busy while it does)
//   0x1B ESC       followed by col, then row — set cursor position
//   anything else  ignored
//
// FSM: IDLE -> ESC_COL -> ESC_ROW, plus CLEAR for the busy walk.
//
// The write port drives Char_RAM once that module exists; until then the
// testbench observes these outputs directly.
//
// STUB — ports and encodings only, logic still to be written.

module Command_Parser
  #(parameter c_COLS      = 40,
    parameter c_ROWS      = 30,
    parameter c_ADDR_BITS = 11)   // 2048 cells
   (input                    i_Clk,
    // From UART_RX
    input                    i_RX_DV,
    input  [7:0]             i_RX_Byte,
    // Character RAM write port
    output                   o_Wr_En,
    output [c_ADDR_BITS-1:0] o_Wr_Addr,
    output [7:0]             o_Wr_Data,
    // High while the clear-screen walk is in progress
    output                   o_Busy
    );

  // Control bytes
  localparam c_LF  = 8'h0A;
  localparam c_CR  = 8'h0D;
  localparam c_FF  = 8'h0C;
  localparam c_ESC = 8'h1B;

  // FSM states
  localparam IDLE    = 2'b00;
  localparam ESC_COL = 2'b01;
  localparam ESC_ROW = 2'b10;
  localparam CLEAR   = 2'b11;

  // TODO: r_SM_Main, r_Cursor_Col, r_Cursor_Row, clear-walk address counter
  // TODO: write address = r_Cursor_Row * c_COLS + r_Cursor_Col
  // TODO: ESC col/row out of range — clamp or ignore, pick one and record it
  // TODO: byte arriving while o_Busy — drop or queue, pick one and record it

  assign o_Wr_En   = 1'b0;
  assign o_Wr_Addr = {c_ADDR_BITS{1'b0}};
  assign o_Wr_Data = 8'h00;
  assign o_Busy    = 1'b0;

endmodule
