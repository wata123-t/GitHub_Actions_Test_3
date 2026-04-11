-- models/fct_bit_toggles.sql
{{ config(materialized='table') }}

WITH raw_data AS (
    SELECT 
        test_id,
        timestamp,
        ptext_hex
    FROM {{ source('aes_raw', 'verification_results') }}
),

bit_indices AS (
    SELECT i AS bit_index FROM UNNEST(GENERATE_ARRAY(0, 127)) AS i
),

expanded_bits AS (
    SELECT
        r.test_id,
        r.timestamp,
        b.bit_index,
        -- 1文字(4bit)を取り出し、数値化してビット判定。これなら絶対オーバーフローしません。
        CASE WHEN (
          CAST(CONCAT('0x', SUBSTR(r.ptext_hex, DIV(b.bit_index, 4) + 1, 1)) AS INT64) & 
          (8 >> MOD(b.bit_index, 4))
        ) > 0 THEN 1 ELSE 0 END AS bit_value
    FROM raw_data r
    CROSS JOIN bit_indices b
),

bit_changes AS (
    SELECT
        bit_index,
        bit_value,
        LAG(bit_value) OVER(PARTITION BY bit_index ORDER BY timestamp) AS prev_bit_value
    FROM expanded_bits
)

SELECT
    bit_index,
    SUM(CASE WHEN prev_bit_value IS NOT NULL AND bit_value != prev_bit_value THEN 1 ELSE 0 END) AS toggle_count
FROM bit_changes
GROUP BY bit_index
