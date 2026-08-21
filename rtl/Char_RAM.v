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

always @(posedge i_Clk) begin
  if (i_Wr_En)
    r_Mem[i_Wr_Addr] <= i_Wr_Data;
  o_Rd_Data <= r_Mem[i_Rd_Addr];
end
endmodule