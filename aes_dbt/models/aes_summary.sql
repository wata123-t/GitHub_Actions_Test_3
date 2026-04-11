-- models/aes_summary.sql

SELECT
    test_id,
    timestamp,
    error_injected,
    -- 文字列同士の比較に変更（これでout_hi等のエラーが消えます）
    (actual_out_hex = expected_out_hex) AS is_physically_match,
    
    CASE 
        WHEN error_injected = TRUE AND (actual_out_hex != expected_out_hex) THEN 'EXPECTED_FAILURE'
        WHEN error_injected = FALSE AND (actual_out_hex = expected_out_hex) THEN 'PASS'
        ELSE 'FAIL'
    END AS verification_status
FROM {{ source('aes_raw', 'verification_results') }}
