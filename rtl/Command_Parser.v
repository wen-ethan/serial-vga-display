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

  // Internal registers
  reg [1:0] r_SM_Main = IDLE; // current state
  reg [$clog2(c_COLS)-1:0] r_Cursor_Col = 0; // current cursor column
  reg [$clog2(c_ROWS)-1:0] r_Cursor_Row = 0; //current cursor row
  reg [c_ADDR_BITS-1:0] r_Addr = 0; // current address in character RAM
  reg [c_ADDR_BITS-1:0] r_Clear_Addr = 0; // CLEAR counter

  reg [7:0] r_ESC_Col = 0; // temp storage for the column value received after ESC
  wire [7:0] w_Col_Clamped = (r_ESC_Col >= c_COLS) ? c_COLS-1 : r_ESC_Col; // clamp the column value 
  wire [7:0] w_Row_Clamped = (i_RX_Byte >= c_ROWS) ? c_ROWS-1 : i_RX_Byte; // clamp the row value

  // write port signals
  reg r_Wr_En = 1'b0; // write enable signal
  reg [c_ADDR_BITS-1:0] r_Wr_Addr = 0; // write address signal
  reg [7:0] r_Wr_Data = 8'h00; // write data signal

  always @(posedge i_Clk) begin
    r_Wr_En <= 1'b0;          // default: no write this cycle

    case (r_SM_Main)
      IDLE: begin
        if (i_RX_DV) begin
          case (i_RX_Byte)
            c_LF: begin
              r_Cursor_Row <= (r_Cursor_Row == c_ROWS-1) ? 0 : r_Cursor_Row + 1'b1; // row + 1, accounting for wrapping

              r_Addr <= (r_Cursor_Row == c_ROWS-1) ? r_Cursor_Col : r_Addr + c_COLS;  // wrap to next row, accounting for wrapping
              // if r_Cursor_Row is equal to c_ROWS-1, then we are in the last row, and as such we should update the address to the first row (row 0) and the current column address
              // otherwise, we can just ad c_COLS to move onto the next row
            end
            c_CR: begin
              r_Addr <= r_Addr - r_Cursor_Col; // no edge cases with wrapping to rule out; can simply subtract the value of the current column

              r_Cursor_Col <= 0; // now reset the column number to 0

            end
            c_FF: begin
              r_SM_Main <= CLEAR; // set state to CLEAR
              r_Clear_Addr <= {c_ADDR_BITS{1'b0}}; // reset the clear counter
            end
            c_ESC: begin
              r_SM_Main <= ESC_COL; // set state to ESC_COL
            end
            default: begin
              if ((i_RX_Byte >= 8'h20) && (i_RX_Byte <= 8'h7E)) begin // if a valid printable byte
                r_Wr_En   <= 1'b1; // enable write
                r_Wr_Addr <= r_Addr; // set write address
                r_Wr_Data <= i_RX_Byte; // set write data

                // update cursor position and address
                if (r_Cursor_Col == c_COLS-1) begin
                  r_Cursor_Col <= 0;
                  r_Cursor_Row <= (r_Cursor_Row == c_ROWS-1) ? 0 : r_Cursor_Row + 1'b1;
                end else begin
                  r_Cursor_Col <= r_Cursor_Col + 1'b1;
                end

                // update address
                r_Addr <= (r_Addr == c_COLS*c_ROWS-1) ? {c_ADDR_BITS{1'b0}} : r_Addr + 1'b1;
              end
            end
          endcase
        end
      end
      ESC_COL: begin
        if (i_RX_DV) begin
          r_ESC_Col <= i_RX_Byte; // store the column value, without clamping
          r_SM_Main <= ESC_ROW; // move to the next state
        end
      end
      ESC_ROW: begin
        if (i_RX_DV) begin
          // the values of w_Col_Clamped and w_Row_Clamped are already clamped to the valid range of columns and rows, respectively
          // this can be done outside of this block, as the values of r_ESC_Col and i_RX_Byte are always set correctly instantly, as a continuous assignment

          // set the cursor row and column to the clamped values
          r_Cursor_Col <= w_Col_Clamped;
          r_Cursor_Row <= w_Row_Clamped;

          r_Addr <= w_Row_Clamped * c_COLS + w_Col_Clamped; // update the address based on the new cursor position
          // as r_Cursor_Col and r_Cursor_Row are not updated until the next clock cycle, we need to use the clamped wire values


          r_SM_Main <= IDLE; // return to the idle state
        end
      end
      CLEAR: begin
        r_Wr_En <= 1'b1; //enable write
        r_Wr_Addr <= r_Clear_Addr; // set write address to the current CLEAR counter value
        r_Wr_Data <= 8'h20; // write a space character

        if (r_Clear_Addr == c_COLS*c_ROWS-1) begin
          r_SM_Main <= IDLE; // if we have cleared all cells, return to IDLE
          r_Cursor_Col <= 0; // reset cursor column
          r_Cursor_Row <= 0; // reset cursor row
          r_Addr <= 0; // reset address
        end else begin
          r_Clear_Addr <= r_Clear_Addr + 1'b1; // increment the clear counter
        end
      end
    endcase
  end

  assign o_Wr_En   = r_Wr_En;
  assign o_Wr_Addr = r_Wr_Addr;
  assign o_Wr_Data = r_Wr_Data;
  assign o_Busy    = (r_SM_Main == CLEAR);

endmodule
