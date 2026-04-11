////////////////////////////////////////////////////
//
////////////////////////////////////////////////////
module mixcolumns (
    input  [127:0] state_in,
    output [127:0] state_out
);
    //
    // 2倍 (xtime) と 3倍 (xtime ^ 原形) を計算する関数
    function [7:0] xtime;
        input [7:0] a;
        begin
            // MSBが1なら左シフトして0x1bとXOR、0なら単に左シフト
            xtime = (a[7]) ? ((a << 1) ^ 8'h1b) : (a << 1);
        end
    endfunction

    // 各列（32ビットずつ）をバラして処理するための変数を生成
    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : col_loop
            // 列の4バイトを抽出 (a0-a3)
            wire [7:0] a0 = state_in[127 - (i*32 + 0)  -: 8];
            wire [7:0] a1 = state_in[127 - (i*32 + 8)  -: 8];
            wire [7:0] a2 = state_in[127 - (i*32 + 16) -: 8];
            wire [7:0] a3 = state_in[127 - (i*32 + 24) -: 8];

            // 各バイトの新値を計算 (行列演算)
            // b0 = (2*a0) ^ (3*a1) ^ a2 ^ a3
            // b1 = a0 ^ (2*a1) ^ (3*a2) ^ a3
            // b2 = a0 ^ a1 ^ (2*a2) ^ (3*a3)
            // b3 = (3*a0) ^ a1 ^ a2 ^ (2*a3)

            assign state_out[127 - (i*32 + 0)  -: 8] = xtime(a0) ^ (xtime(a1) ^ a1) ^ a2 ^ a3;
            assign state_out[127 - (i*32 + 8)  -: 8] = a0 ^ xtime(a1) ^ (xtime(a2) ^ a2) ^ a3;
            assign state_out[127 - (i*32 + 16) -: 8] = a0 ^ a1 ^ xtime(a2) ^ (xtime(a3) ^ a3);
            assign state_out[127 - (i*32 + 24) -: 8] = (xtime(a0) ^ a0) ^ a1 ^ a2 ^ xtime(a3);

        end
    endgenerate

endmodule
