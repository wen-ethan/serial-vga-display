// tb_Command_Parser — drives real serial byte streams into UART_RX through an
// instantiated UART_TX, so the receive path under test is the one that ships,
// and checks the write port the parser presents to the character RAM.
//
// Grid is shrunk from 40x30 so addresses stay readable in the waves.
//
// Coverage to build out: nominal text, each control byte, wrap at the last
// column, ESC cursor positioning, and the malformed cases — unknown bytes,
// ESC col/row out of range, an ESC sequence abandoned partway, and a byte
// arriving while the clear walk is busy.
//
// STUB — harness skeleton only.

`timescale 1ns/10ps

module tb_Command_Parser ();

  // 25 MHz clock, 115200 baud => 217 clocks per bit
  localparam c_CLOCK_PERIOD_NS = 40;
  localparam c_CLKS_PER_BIT    = 217;

  localparam c_COLS      = 4;
  localparam c_ROWS      = 3;
  localparam c_ADDR_BITS = 4;

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
     .i_RX_DV   (w_RX_DV),
     .i_RX_Byte (w_RX_Byte),
     .o_Wr_En   (w_Wr_En),
     .o_Wr_Addr (w_Wr_Addr),
     .o_Wr_Data (w_Wr_Data),
     .o_Busy    (w_Busy));

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

  initial begin
    $dumpfile("dump.vcd");
    $dumpvars(0);

    // TODO: stimulus and checks

    $finish;
  end

endmodule
