
[ Local / CI (GitHub Actions) ]

      |
      |-- (1) Terraform: BigQuery インフラ構築 (Dataset/Table)
      |

      |-- (2) Icarus Verilog + cocotb: HDLシミュレーション実行
      |         |-- Python (pycryptodome) によるゴールデンモデル比較
      |         `-- BigQuery への結果ロード (Streaming/Batch)

      |
      |-- (3) dbt (data build tool): データ解析・自動テスト
      |         |-- 期待値一致判定 (正常系/擬似エラー検出)
      |         `-- 128bit トグルカバレッジ集計
      |
      `-- (4) Terraform: インフラの自動破棄 (Destroy)

