module subbytes_128 (
    input  [127:0] state_in,  // 入力データ（128ビット）
    output [127:0] state_out  // 変換後データ（128ビット）
);

    // generate文を使って16個のS-Boxを自動で並べる
    genvar i;
    generate
        for (i = 0; i < 16; i = i + 1) begin : sbox_loop
            sbox sb_inst (
//                .a(state_in[i*8 +: 8]), // 8ビットずつ取り出す
//                .q(state_out[i*8 +: 8]) // 8ビットずつ出力する
                .a(state_in[127 - (i*8) -: 8]), 
                .q(state_out[127 - (i*8) -: 8])

            );
        end
    endgenerate

endmodule
