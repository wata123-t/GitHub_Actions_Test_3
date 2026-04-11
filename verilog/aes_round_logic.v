//////////////////////////////////////////////////
//
/////////////////////////////////////////////////
module aes_round_logic (
	input	[127:0]	state_in ,
	input	[127:0]	round_key ,
	input			is_last_round ,
	output	[127:0]	state_out
);

 wire	[127:0]	sb_out ;
 wire	[127:0]	sr_out ;
 wire	[127:0]	mc_out ;

// 1. SubBytes (S-Boxを16個並列に並べる)
genvar i;
generate
	for (i = 0; i < 16; i = i + 1) begin : sb_loop
		sbox sb_inst (
			 .a	( state_in[i*8 +: 8]	)
			,.q	( sb_out[i*8 +: 8]		)
		);
	end
endgenerate

// 2. ShiftRows
shiftrows sr_inst (
	 . state_in		( sb_out )
	,. state_out	( sr_out )
);

// 3. MixColumns
mixcolumns mc_inst (
	 . state_in		( sr_out )
	,. state_out	( mc_out )
);

// 4. AddRoundKey (XOR)
assign state_out = (is_last_round)? sr_out : mc_out ;

endmodule
