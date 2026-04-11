# 2. プロバイダーの設定
provider "google" {
  project = var.project_id
  region  = var.region
}

resource "google_bigquery_dataset" "aes_verification" {
  dataset_id                  = var.dataset_id
  friendly_name               = "AES Verification Logs"
  location                    = var.region
  delete_contents_on_destroy = true
}


resource "google_bigquery_table" "verification_results" {
  dataset_id = google_bigquery_dataset.aes_verification.dataset_id
  table_id   = "verification_results"
  deletion_protection = false

# google_bigquery_table.verification_results の schema 部分を差し替え
  schema = <<EOF
[
  { "name": "test_id",        "type": "STRING",    "mode": "REQUIRED" },
  { "name": "ptext_hex",      "type": "STRING",    "mode": "REQUIRED" },
  { "name": "key_hex",        "type": "STRING",    "mode": "REQUIRED" },
  { "name": "actual_out_hex", "type": "STRING",    "mode": "REQUIRED" },
  { "name": "expected_out_hex","type": "STRING",    "mode": "REQUIRED" },
  { "name": "error_injected", "type": "BOOLEAN",   "mode": "REQUIRED" },
  { "name": "timestamp",      "type": "TIMESTAMP", "mode": "REQUIRED" }
]
EOF
}
