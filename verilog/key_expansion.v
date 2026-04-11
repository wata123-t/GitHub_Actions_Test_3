//////////////////////////////////////////////////////////
//
//////////////////////////////////////////////////////////
module key_expansion (
    input  [3:0]   round,        // 現在のラウンド番号 (0-10)
    input  [127:0] prev_key,     // 1つ前のラウンドキー
    output [127:0] next_key      // 次のラウンドキー
);

    wire [31:0] w0, w1, w2, w3;
    assign {w0, w1, w2, w3} = prev_key;

    // 特殊な加工を行うワード (g関数)
    wire [31:0] g_out;
    wire [31:0] rot_w = {w3[23:0], w3[31:24]}; // RotWord
    
    // SubWord (S-Boxを4つ並列で使用)
    wire [31:0] sub_w;
    sbox sb0(.a(rot_w[31:24]), .q(sub_w[31:24]));
    sbox sb1(.a(rot_w[23:16]), .q(sub_w[23:16]));
    sbox sb2(.a(rot_w[15:8]),  .q(sub_w[15:8]));
    sbox sb3(.a(rot_w[7:0]),   .q(sub_w[7:0]));

    // Rcon (ラウンド定数)
    reg [7:0] rcon;
    always @(*) begin
        case(round)
            4'd0: rcon = 8'h01; // Round 0 の鍵から Round 1 の鍵を作るとき
            4'd1: rcon = 8'h02; // Round 1 の鍵から Round 2 の鍵を作るとき
            4'd2: rcon = 8'h04;
            4'd3: rcon = 8'h08;
            4'd4: rcon = 8'h10;
            4'd5: rcon = 8'h20;
            4'd6: rcon = 8'h40;
            4'd7: rcon = 8'h80;
            4'd8: rcon = 8'h1b;
            4'd9: rcon = 8'h36;
    default: rcon = 8'h00;
        endcase
    end

    assign g_out = sub_w ^ {rcon, 24'b0};

    // 新しい4つのワードを生成
    wire [31:0] next_w0 = w0 ^ g_out;
    wire [31:0] next_w1 = w1 ^ next_w0;
    wire [31:0] next_w2 = w2 ^ next_w1;
    wire [31:0] next_w3 = w3 ^ next_w2;

    assign next_key = {next_w0, next_w1, next_w2, next_w3};

endmodule
