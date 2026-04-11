import os
import io
import json
import time
from google.cloud import bigquery
from google.oauth2 import service_account

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
from Crypto.Cipher import AES
import random
import datetime

os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = "./credentials/bq-writer.json"

def send_to_bigquery_batch(results):
    key_path = os.path.join(os.path.dirname(__file__), "credentials/bq-writer.json")
    credentials = service_account.Credentials.from_service_account_file(key_path)
    client = bigquery.Client(credentials=credentials, project=credentials.project_id)

    table_id = f"{credentials.project_id}.aes_verification_dataset.verification_results"

    job_config = bigquery.LoadJobConfig(
        source_format=bigquery.SourceFormat.NEWLINE_DELIMITED_JSON,
        autodetect=True, # 数値カラムを追加するためTrueに変更
        # 重複を防ぐため、実行のたびにテーブルをクリアして書き込む設定
        write_disposition="WRITE_TRUNCATE", 
    )

    job = client.load_table_from_json(results, table_id, job_config=job_config)
    
    try:
        job.result()
        print(f"Success: {job.output_rows} rows loaded to BigQuery (Table Overwritten).")
    except Exception as e:
        print(f"Failed to load data: {e}")

#####################################################
#
#####################################################
@cocotb.test()
async def aes_basic_test(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())

    dut.rst.value = 1
    dut.start.value = 0
    await Timer(20, units="ns")
    dut.rst.value = 0
    await RisingEdge(dut.clk)

    results = [] 
    test_count = 50 
    run_timestamp = datetime.datetime.now().strftime("%Y%m%d%H%M%S")

    for i in range(test_count):
        # 1. データ生成
        ptext_int = random.getrandbits(128)
        key_int = random.getrandbits(128)

        # 2. 疑似エラーの挿入（10%の確率でVerilogへの入力だけ壊す）
        inject_error = True if random.random() < 0.1 else False
        sim_input = ptext_int ^ 1 if inject_error else ptext_int

        # 3. シミュレーション実行
        dut.plaintext.value = sim_input # 壊れた可能性のある値を入力
        dut.key.value = key_int
        dut.start.value = 1
        await RisingEdge(dut.clk)
        dut.start.value = 0

        count = 0
        while not dut.done.value and count < 100:
            await RisingEdge(dut.clk)
            count += 1

        actual_out = int(dut.ciphertext.value)
        
        # 4. 期待値計算（常に「正しい入力」で行う）
        cipher = AES.new(key_int.to_bytes(16, 'big'), AES.MODE_ECB)
        expected_out = int.from_bytes(cipher.encrypt(ptext_int.to_bytes(16, 'big')), 'big')

        # 5. BigQuery送信用データの作成（128bitを0埋め16進数文字列にする）
        res_data = {
            "test_id": f"{run_timestamp}_{i}",
            "ptext_hex": format(ptext_int, '032x'),
            "key_hex": format(key_int, '032x'),
            "actual_out_hex": format(actual_out, '032x'),
            "expected_out_hex": format(expected_out, '032x'),
            "error_injected": inject_error,
            "timestamp": datetime.datetime.now().isoformat()
        }

        results.append(res_data)

        # ログ出力（簡易比較）
        if not inject_error and actual_out == expected_out:
            dut._log.info(f"Test {i}: PASS")
        elif inject_error:
            dut._log.info(f"Test {i}: Error Injected")
        else:
            dut._log.error(f"Test {i}: FAIL")

    if results:
        send_to_bigquery_batch(results)


