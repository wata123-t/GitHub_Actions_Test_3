-- verification_status が 'FAIL' のレコードを抽出
-- 1件でもヒットすれば、dbt test は「失敗」と判定します
SELECT
    test_id,
    verification_status
FROM {{ ref('aes_summary') }}
WHERE verification_status = 'FAIL'
