module Serial_Display_Top
  (input  i_Clk,       // Main Clock
   input  i_UART_RX,   // UART RX Data
   output o_UART_TX,   // UART TX Data

   // Segment1 is upper digit, Segment2 is lower digit
   output o_Segment1_A,
   output o_Segment1_B,
   output o_Segment1_C,
   output o_Segment1_D,
   output o_Segment1_E,
   output o_Segment1_F,
   output o_Segment1_G,
   //
   output o_Segment2_A,
   output o_Segment2_B,
   output o_Segment2_C,
   output o_Segment2_D,
   output o_Segment2_E,
   output o_Segment2_F,
   output o_Segment2_G,
     
   // VGA
   output o_VGA_HSync,
   output o_VGA_VSync,
   output o_VGA_Red_0,
   output o_VGA_Red_1,
   output o_VGA_Red_2,
   output o_VGA_Grn_0,
   output o_VGA_Grn_1,
   output o_VGA_Grn_2,
   output o_VGA_Blu_0,
   output o_VGA_Blu_1,
   output o_VGA_Blu_2   
   );
    
  // VGA Constants to set Frame Size
  parameter c_VIDEO_WIDTH = 3;
  parameter c_TOTAL_COLS  = 800;
  parameter c_TOTAL_ROWS  = 525;
  parameter c_ACTIVE_COLS = 640;
  parameter c_ACTIVE_ROWS = 480;

  parameter c_COLS = 40;
  parameter c_ROWS = 30;
  parameter c_ADDR_BITS = 11;

  // 25,000,000 / 115,200 = 217. A parameter rather than a literal so the
  // end-to-end testbench can shrink it: at 217 a byte occupies 2170 clocks and
  // one character costs more simulation time than a whole frame.
  parameter c_CLKS_PER_BIT = 217;
   
  wire w_RX_DV;
  wire [7:0] w_RX_Byte;
 
  wire w_Segment1_A, w_Segment2_A;
  wire w_Segment1_B, w_Segment2_B;
  wire w_Segment1_C, w_Segment2_C;
  wire w_Segment1_D, w_Segment2_D;
  wire w_Segment1_E, w_Segment2_E;
  wire w_Segment1_F, w_Segment2_F;
  wire w_Segment1_G, w_Segment2_G;
  
 
  // Common VGA Signals
  wire [c_VIDEO_WIDTH-1:0] w_Red_Video_CG, w_Red_Video_Porch;
  wire [c_VIDEO_WIDTH-1:0] w_Grn_Video_CG, w_Grn_Video_Porch;
  wire [c_VIDEO_WIDTH-1:0] w_Blu_Video_CG, w_Blu_Video_Porch;

  // Char_RAM's two ports. The write side and the read side share nothing but
  // the memory: Test_Writer and Char_Generator never touch each other.
  wire [c_ADDR_BITS-1:0] w_Rd_Addr;    // Char_Generator -> Char_RAM
  wire [7:0]  w_Rd_Data;    // Char_RAM       -> Char_Generator, one clock later
  wire        w_Wr_En;      // Test_Writer    -> Char_RAM
  wire [c_ADDR_BITS-1:0] w_Wr_Addr;
  wire [7:0]  w_Wr_Data;


  // 25,000,000 / 115,200 = 217
  // Initiate UART RX
  UART_RX #(.CLKS_PER_BIT(c_CLKS_PER_BIT)) UART_RX_Inst
  (.i_Clock(i_Clk),
   .i_RX_Serial(i_UART_RX),
   .o_RX_DV(w_RX_DV),
   .o_RX_Byte(w_RX_Byte));
  
   
  // Drive UART line high
  assign o_UART_TX =1'b1; 
   
   
  // Binary to 7-Segment Converter for Upper Digit
  Binary_To_7Segment SevenSeg1_Inst
  (.i_Clk(i_Clk),
   .i_Binary_Num(w_RX_Byte[7:4]),
   .o_Segment_A(w_Segment1_A),
   .o_Segment_B(w_Segment1_B),
   .o_Segment_C(w_Segment1_C),
   .o_Segment_D(w_Segment1_D),
   .o_Segment_E(w_Segment1_E),
   .o_Segment_F(w_Segment1_F),
   .o_Segment_G(w_Segment1_G));
    
  assign o_Segment1_A = ~w_Segment1_A;
  assign o_Segment1_B = ~w_Segment1_B;
  assign o_Segment1_C = ~w_Segment1_C;
  assign o_Segment1_D = ~w_Segment1_D;
  assign o_Segment1_E = ~w_Segment1_E;
  assign o_Segment1_F = ~w_Segment1_F;
  assign o_Segment1_G = ~w_Segment1_G;
   
   
  // Binary to 7-Segment Converter for Lower Digit
  Binary_To_7Segment SevenSeg2_Inst
  (.i_Clk(i_Clk),
   .i_Binary_Num(w_RX_Byte[3:0]),
   .o_Segment_A(w_Segment2_A),
   .o_Segment_B(w_Segment2_B),
   .o_Segment_C(w_Segment2_C),
   .o_Segment_D(w_Segment2_D),
   .o_Segment_E(w_Segment2_E),
   .o_Segment_F(w_Segment2_F),
   .o_Segment_G(w_Segment2_G));
   
  assign o_Segment2_A = ~w_Segment2_A;
  assign o_Segment2_B = ~w_Segment2_B;
  assign o_Segment2_C = ~w_Segment2_C;
  assign o_Segment2_D = ~w_Segment2_D;
  assign o_Segment2_E = ~w_Segment2_E;
  assign o_Segment2_F = ~w_Segment2_F;
  assign o_Segment2_G = ~w_Segment2_G;
   
  //////////////////////////////////////////////////////////////////
  // Character display, with no protocol
  //////////////////////////////////////////////////////////////////
  // Char_Generator sits where Test_Pattern_Gen used to, reading characters out
  // of the real Char_RAM. Test_Writer fills that memory once at power-up with a
  // known message and then stops, so the screen is driven by something whose
  // behaviour is already known and pixel bugs stay separable from protocol bugs.
  //
  // Test_Writer drives exactly the three signals Command_Parser drives. On
  // integration it is deleted and the parser takes its place; nothing else in
  // this section changes.

  // Generates Sync Pulses to run VGA
  VGA_Sync_Pulses #(.TOTAL_COLS(c_TOTAL_COLS),
                    .TOTAL_ROWS(c_TOTAL_ROWS),
                    .ACTIVE_COLS(c_ACTIVE_COLS),
                    .ACTIVE_ROWS(c_ACTIVE_ROWS)) 
  VGA_Sync_Pulses_Inst 
  (.i_Clk(i_Clk),
   .o_HSync(w_HSync_Start),
   .o_VSync(w_VSync_Start),
   .o_Col_Count(),
   .o_Row_Count()
  );
   
  // Char Generator
  Char_Generator #(.VIDEO_WIDTH(c_VIDEO_WIDTH),
                    .TOTAL_COLS(c_TOTAL_COLS),
                    .TOTAL_ROWS(c_TOTAL_ROWS),
                    .ACTIVE_COLS(c_ACTIVE_COLS),
                    .ACTIVE_ROWS(c_ACTIVE_ROWS),
                    .c_COLS(c_COLS),
                    .c_ROWS(c_ROWS),
                    .c_ADDR_BITS(c_ADDR_BITS))
  Char_Generator_Inst
    (.i_Clk(i_Clk),
      .i_HSync(w_HSync_Start),
      .i_VSync(w_VSync_Start),
      .o_Rd_Addr(w_Rd_Addr),
      .i_Rd_Data(w_Rd_Data),
      .o_HSync(w_HSync_CG),
      .o_VSync(w_VSync_CG),
      .o_Red_Video(w_Red_Video_CG),
      .o_Grn_Video(w_Grn_Video_CG),
      .o_Blu_Video(w_Blu_Video_CG));

  Char_RAM #(.c_ADDR_BITS(c_ADDR_BITS), .c_DATA_BITS(8)) Char_RAM_Inst
    (.i_Clk(i_Clk),
     .i_Wr_En(w_Wr_En),
     .i_Wr_Addr(w_Wr_Addr),
     .i_Wr_Data(w_Wr_Data),
     .o_Rd_Data(w_Rd_Data),
     .i_Rd_Addr(w_Rd_Addr));
  
  Command_Parser #(.c_COLS(c_COLS), .c_ROWS(c_ROWS), .c_ADDR_BITS(c_ADDR_BITS)) Command_Parser_Inst
    (.i_Clk(i_Clk),
     .i_RX_DV(w_RX_DV),
     .i_RX_Byte(w_RX_Byte),
     .o_Wr_En(w_Wr_En),
     .o_Wr_Addr(w_Wr_Addr),
     .o_Wr_Data(w_Wr_Data),
     .o_Busy());
     
  VGA_Sync_Porch  #(.VIDEO_WIDTH(c_VIDEO_WIDTH),
                    .TOTAL_COLS(c_TOTAL_COLS),
                    .TOTAL_ROWS(c_TOTAL_ROWS),
                    .ACTIVE_COLS(c_ACTIVE_COLS),
                    .ACTIVE_ROWS(c_ACTIVE_ROWS))
  VGA_Sync_Porch_Inst
   (.i_Clk(i_Clk),
    .i_HSync(w_HSync_CG),
    .i_VSync(w_VSync_CG),
    .i_Red_Video(w_Red_Video_CG),
    .i_Grn_Video(w_Grn_Video_CG),
    .i_Blu_Video(w_Blu_Video_CG),
    .o_HSync(w_HSync_Porch),
    .o_VSync(w_VSync_Porch),
    .o_Red_Video(w_Red_Video_Porch),
    .o_Grn_Video(w_Grn_Video_Porch),
    .o_Blu_Video(w_Blu_Video_Porch));
       
  assign o_VGA_HSync = w_HSync_Porch;
  assign o_VGA_VSync = w_VSync_Porch;
       
  assign o_VGA_Red_0 = w_Red_Video_Porch[0];
  assign o_VGA_Red_1 = w_Red_Video_Porch[1];
  assign o_VGA_Red_2 = w_Red_Video_Porch[2];
   
  assign o_VGA_Grn_0 = w_Grn_Video_Porch[0];
  assign o_VGA_Grn_1 = w_Grn_Video_Porch[1];
  assign o_VGA_Grn_2 = w_Grn_Video_Porch[2];
 
  assign o_VGA_Blu_0 = w_Blu_Video_Porch[0];
  assign o_VGA_Blu_1 = w_Blu_Video_Porch[1];
  assign o_VGA_Blu_2 = w_Blu_Video_Porch[2];
   
endmodule