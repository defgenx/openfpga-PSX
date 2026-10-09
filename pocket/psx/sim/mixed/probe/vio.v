module vio(input wire en, input wire d, inout wire pin);
  assign pin = en ? d : 1'bz;
endmodule
