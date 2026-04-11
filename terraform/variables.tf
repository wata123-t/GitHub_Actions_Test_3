#################################################################
# 変数定義 (Variable Declarations)
# 
# このプロジェクトで使用する変数の型やデフォルト値を定義します。
# 実際の値（プロジェクトIDやトークン等）は、本ファイルではなく
# `terraform.tfvars` に記述してください。
#
# 注意:
# 秘密情報（Slackトークン等）を含む変数は `sensitive = true` 
# を設定し、コンソール出力時に値が表示されないようにしています。
#################################################################
variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region" {
  description = "GCP Region"
  type        = string
  default     = "asia-northeast1"
}

variable "dataset_id" {
  description = "BigQuery Dataset ID"
  type        = string
  default     = "aes_verification_dataset"
}
