////////////////////////////////////////////////////////////
//
////////////////////////////////////////////////////////////
module aes_128 (
	input	wire			clk ,
	input	wire			rst ,
	input	wire			start ,
	input	wire	[127:0]	plaintext ,		// 暗号化したいデータ
	input	wire	[127:0]	key ,			// 128ビット鍵
	output	reg		[127:0]	ciphertext ,	// 暗号化後のデータ
	output	reg				done			// 完了フラグ
);

 wire	[127:0]		sub_out ;
 wire	[127:0]		shift_out ;
 wire	[127:0]		mix_out ;
 wire	[127:0]		next_key_out ;

 reg	[3:0]		round_count ;
 reg	[127:0]		round_key_reg ;
 reg	[127:0]		aes_data ;
 reg				round_en ;
 wire				end_flg ;
 wire				out_en ;
 wire				pre_end_flg ;


aes_round_logic round_unit (
	 . state_in			( aes_data	)
	,. is_last_round	( end_flg	)
	,. state_out		( mix_out	)
) ;

key_expansion KE (
	 . round			( round_count	)   
	,. prev_key			( round_key_reg	) 
	,. next_key			( next_key_out	)
) ;


always @(posedge clk or posedge rst) begin
	if (rst)            			aes_data  <= 128'h0 ;
	else if(start)      			aes_data  <= plaintext ;
	else if(round_en) begin
		if(round_count==4'h0)		aes_data  <= aes_data ^ round_key_reg ;	// Round 0
		else						aes_data  <= mix_out  ^ round_key_reg ;	// Round 1-A
	end
end

always @(posedge clk or posedge rst) begin
	if (rst)				round_key_reg  <= 128'h0 ;
	else if(start)			round_key_reg  <= key ;
	else if(round_en) 		round_key_reg  <= next_key_out ;
end

always @(posedge clk or posedge rst) begin
	if (rst)				round_en  <= 1'b0 ;
	else if(start)			round_en  <= 1'b1 ;
	else if(end_flg)		round_en  <= 1'b0 ;
end

always @(posedge clk or posedge rst) begin
	if (rst)			round_count  <= 4'h0 ;
	else if(round_en)	round_count  <= round_count + 1'b1 ;
	else				round_count  <= 4'h0 ;
end

assign end_flg	= ( round_count == 4'hA )? 1'b1 : 1'b0 ;
assign out_en	= ( round_count == 4'hB )? 1'b1 : 1'b0 ;

always @(posedge clk or posedge rst) begin
	if (rst)			done  <= 1'b0 ;
	else				done  <= out_en ;
end

always @(posedge clk or posedge rst) begin
	if (rst)			ciphertext <= 128'h0 ;
	else if(out_en)		ciphertext <= aes_data ;
end

endmodule
