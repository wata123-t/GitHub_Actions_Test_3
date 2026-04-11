import os
from google.cloud import bigquery
from google.oauth2 import service_account

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
from Crypto.Cipher import AES
import random
import datetime

os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = "./credentials/bq-writer.json"

def send_to_bigquery(results):
    # 1. 鍵ファイルのパス指定（リネームした名前に合わせてください）
    key_path = os.path.join(os.path.dirname(__file__), "credentials/bq-writer.json")
    
    # 2. 認証情報の読み込み
    credentials = service_account.Credentials.from_service_account_file(key_path)
    client = bigquery.Client(credentials=credentials, project=credentials.project_id)

    # 3. 投入先のテーブル指定 (データセット名.テーブル名)
    # Terraform で作った名前に合わせます
    table_id = f"{credentials.project_id}.aes_verification_dataset.verification_results"

    print(f"Sending {len(results)} rows to BigQuery: {table_id}...")

    # 4. データの挿入 (Streaming Insert)
    errors = client.insert_rows_json(table_id, results)

    if errors == []:
        print("Success: Data uploaded to BigQuery.")
    else:
        print(f"Error occurred while inserting rows: {errors}")
        
##########################################################
# ●検証記述
##########################################################
@cocotb.test()
async def aes_basic_test(dut):
    # クロック開始 (10ns周期)
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())

    # リセット処理
    dut.rst.value = 1
    dut.start.value = 0
    await Timer(20, units="ns")
    dut.rst.value = 0
    await RisingEdge(dut.clk)

    results = [] # BigQuery投入用のデータ格納用

    for i in range(50): # 10回に増やしてみます
        ptext_int = random.getrandbits(128)
        key_int = random.getrandbits(128)

        # Verilog入力
        dut.plaintext.value = ptext_int
        dut.key.value = key_int
        dut.start.value = 1
        await RisingEdge(dut.clk)
        dut.start.value = 0

        # 完了待ち (タイムアウト付きにするとより安全)
        count = 0
        while not dut.done.value and count < 100:
            await RisingEdge(dut.clk)
            count += 1

        actual_out = int(dut.ciphertext.value)
        
        # 期待値計算
        cipher = AES.new(key_int.to_bytes(16, 'big'), AES.MODE_ECB)
        expected_out = int.from_bytes(cipher.encrypt(ptext_int.to_bytes(16, 'big')), 'big')

        # --- BigQuery用のデータ構造を作成 ---
        res_data = {
            "test_id": i,
            "input_hex": hex(ptext_int),
            "key_hex": hex(key_int),
            "expected_hex": hex(expected_out),
            "actual_hex": hex(actual_out),
            "is_match": (actual_out == expected_out),
            "timestamp": datetime.datetime.now().isoformat()
        }
        results.append(res_data)

        # 合否判定
        assert actual_out == expected_out, f"Test {i} Failed! Expected {hex(expected_out)}, got {hex(actual_out)}"
        dut._log.info(f"Test {i}: PASS")

    # --- 修正ポイント：コメントアウトを外して実行させる ---
    send_to_bigquery(results) 
    
    