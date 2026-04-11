module aes_128 (
    input  wire         clk,
    input  wire         rst,
    input  wire         start,
    input  wire [127:0] plaintext, // 暗号化したいデータ
    input  wire [127:0] key,       // 128ビット鍵
    output reg  [127:0] ciphertext,// 暗号化後のデータ
    output reg          done       // 完了フラグ
);

    // 状態定義
    localparam IDLE  = 2'd0, ROUND0 = 2'd1, MAIN = 2'd2, FINAL = 2'd3;
    reg [1:0] state;
    reg [3:0] round_count;

    // 内部データバス
    reg  [127:0] state_reg;      // 現在処理中のデータ
    reg  [127:0] round_key_reg;  // 現在のラウンドキー
    wire [127:0] sub_out, shift_out, mix_out, next_key_out;

    // --- 各パーツのインスタンス化 ---
    subbytes_128  SB (.state_in(state_reg),  .state_out(sub_out));
    shiftrows     SR (.state_in(sub_out),    .state_out(shift_out));
    mixcolumns    MC (.state_in(shift_out),  .state_out(mix_out));
    key_expansion KE (.round(round_count),   .prev_key(round_key_reg), .next_key(next_key_out));

    // --- 制御ロジックとステートマシン ---
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= IDLE;
            done  <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        state_reg     <= plaintext; // データの取り込み
                        round_key_reg <= key;       // 初期鍵の取り込み
                        round_count   <= 4'd0;      // カウンタのリセット
                        state         <= ROUND0;    // 次のクロックで ROUND0 へ
                    end
                end

                ROUND0: begin // 最初はAddRoundKeyのみ
                    state_reg     <= state_reg ^ round_key_reg;
                    round_key_reg <= next_key_out; // 次の鍵を準備
                    round_count   <= 4'd1;
                    state         <= MAIN;
                end

/*
                MAIN: begin
                    state_reg     <= mix_out ^ round_key_reg;
                    round_key_reg <= next_key_out;
                    round_count   <= round_count + 1;
                    
                    // 9 ではなく 10 になった時に FINAL へ行くように変更
                    if (round_count == 4'd10) begin
                        state <= FINAL;
                    end
                end
*/
MAIN: begin
    if (round_count < 10) begin
        state_reg     <= mix_out ^ round_key_reg;
        round_key_reg <= next_key_out;
        round_count   <= round_count + 1;
    end else begin
        state <= FINAL;
    end
end



                FINAL: begin
                    // ここで sub_out や shift_out を使うと
                    // すでに MAIN で計算された後の値（state_reg）を元に計算してしまいます。
                    // 最終ラウンドは state_reg に対して SubBytes -> ShiftRows -> AddRoundKey を行います。
                    ciphertext <= shift_out ^ round_key_reg;
                    done       <= 1'b1;
                    state      <= IDLE;
                end



            endcase
        end
    end
endmodule
