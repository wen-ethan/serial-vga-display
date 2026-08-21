module Char_RAM
#(parameter c_ADDR_BITS = 11,
  parameter c_DATA_BITS = 8)
(input wire i_Clk,
 input wire i_Wr_En,
 input wire [c_ADDR_BITS-1:0] i_Wr_Addr,
 input wire [c_DATA_BITS-1:0] i_Wr_Data,
 input wire [c_ADDR_BITS-1:0] i_Rd_Addr,
 output reg [c_DATA_BITS-1:0] o_Rd_Data
);

reg [c_DATA_BITS-1:0] r_Mem [0:(1<<c_ADDR_BITS)-1];

// The bitstream loads every cell with zero at configuration -- visible as
// all-zero .ram_data blocks in the .asc -- and font entry 0x00 is blank, which
// is why the screen comes up empty with no power-on clear. Declaring it here
// makes simulation model the hardware instead of starting from X, and makes the
// power-up state a property of the design rather than of the toolchain's
// default. See docs/design.md.
integer i;
initial
  for (i = 0; i < (1<<c_ADDR_BITS); i = i + 1)
    r_Mem[i] = {c_DATA_BITS{1'b0}};

always @(posedge i_Clk) begin
  if (i_Wr_En)
    r_Mem[i_Wr_Addr] <= i_Wr_Data;
  o_Rd_Data <= r_Mem[i_Rd_Addr];
end
endmodule