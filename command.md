///////////////////////////////////////////////////////////////////////////////////////////////////////////
// ●k6 (script.js)
///////////////////////////////////////////////////////////////////////////////////////////////////////////
import http from 'k6/http';
import { check, sleep } from 'k6';
//import { uuidv4 } from 'https://jslib.k6.io/k6-utils/1.4.0/index.js';
import { uuidv4 } from './k6-utils.js';


// 1. Pythonが作った正解リスト(JSON)を読み込む
const mapping = JSON.parse(open('./test_images/mapping.json'));
const imageFiles = [];

// 2. 100枚の画像をメモリに読み込む
for (let i = 1; i <= 100; i++) {
  const filename = `${String(i).padStart(3, '0')}.png`;
  
  imageFiles.push({
    name: filename,
    expected: mapping[filename], // JSONから正解を取得
    bin: open(`./test_images/${filename}`, 'b')
  });
}


export default function () {
  const url = 'http://35.189.130.119:8080/predict';
  
  // ★ 4. 順番に1枚選ぶ (0, 1, 2... 99, 0, 1...)
  // execution.instance.iterationInTest を使う方法もありますが、簡易的には __ITER を使用します
  const index = __ITER % imageFiles.length; 
  const targetImage = imageFiles[index];

  const data = {
    image: http.file(targetImage.bin, targetImage.name, 'image/png'),
  };

  const k6SendTime = Date.now();

  const params = {
    headers: {
      'X-Correlation-ID': uuidv4(),
      'X-Expected-Text': targetImage.expected,
      'X-K6-Send-Time': k6SendTime.toString(),
      'X-Image-Index': index.toString(), // デバッグ用に何番目か送るのもアリ
    },
  };

  const res = http.post(url, data, params);

  // （以下、check処理はそのまま）
  check(res, {
    'Status is 200': (r) => r.status === 200,
    'OCR Content Match': (r) => {
      try {
        const body = r.json();
        const match = body.result.includes(targetImage.expected);
        // ★ 失敗した時にログを出すと特定が捗ります
        if (!match) {
           console.log(`Failed! Index: ${index}, File: ${targetImage.name}, Expected: ${targetImage.expected}, Got: ${body.result}`);
        }
        return match;
      } catch (e) {
        return false;
      }
    },
  });

  sleep(1); // 待機時間
//  sleep(2); // 待機時間
}

///////////////////////////////////////////////////////////////////////////////////////////////////////////
// go-api.yaml
///////////////////////////////////////////////////////////////////////////////////////////////////////////
apiVersion: apps/v1
kind: Deployment
metadata:
  name: go-api
  namespace: default
spec:
  replicas: {{ .Values.goApi.replicaCount }}
  selector:
    matchLabels:
      app: go-api
  template:
    metadata:
      labels:
        app: go-api
    spec:
      # 🌟【最重要追加】GCPの権限とリンクした会員証（ServiceAccount）を指定します
      serviceAccountName: ocr-app-sa
      containers:
      - name: go-api
        image: {{ .Values.goApi.image }}
        imagePullPolicy: Always
        ports:
        - containerPort: 8080
        env:
        - name: GCP_PROJECT_ID
          value: {{ .Values.gcp.projectId }}
        # ⚠️ GOOGLE_APPLICATION_CREDENTIALS などの環境変数、volumeMounts、volumes はすべて不要になったため消去しました！
        
---
apiVersion: v1
kind: Service
metadata:
  name: go-api-service
  namespace: default
spec:
  type: ClusterIP
  ports:
  - port: 8080
    targetPort: 8080
  selector:
    app: go-api



///////////////////////////////////////////////////////////////////////////////////////////////////////////
// keda-scaler
///////////////////////////////////////////////////////////////////////////////////////////////////////////
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata:
  name: keda-gcp-auth
  namespace: default
spec:
  # 🌟【最重要変更】Secretではなく、Pod自身の持つWorkload Identity（gcp）を使うように指定します
  podIdentity:
    provider: gcp
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: python-worker-scaler
  namespace: default
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: python-worker
    
  # キューが空なら0台、初動を早くしたい場合は1に変更
  minReplicaCount: 1
  maxReplicaCount: 5
  cooldownPeriod: 30
  
  triggers:
  - type: gcp-pubsub
    metadata:
      value: "2"
      subscriptionName: "projects/{{ .Values.gcp.projectId }}/subscriptions/ocr-task-sub"
      # 🌟【最適化有効化】Monitoring経由ではなく、直接の生件数を見る
      subscriptionSizeMetricsMode: "pubsub"
      # 🌟【最適化有効化】10秒間の平均を見て超高感度に検知
      subscriptionSizeSamplePeriod: "10"
    authenticationRef:
      name: keda-gcp-auth




///////////////////////////////////////////////////////////////////////////////////////////////////////////
// python-worker
///////////////////////////////////////////////////////////////////////////////////////////////////////////
apiVersion: apps/v1
kind: Deployment
metadata:
  name: python-worker
  namespace: default
spec:
  replicas: {{ .Values.pythonWorker.replicaCount }}
  selector:
    matchLabels:
      app: python-worker
  template:
    metadata:
      labels:
        app: python-worker
    spec:
      # 🌟【最重要追加】GCPの権限とリンクした会員証（ServiceAccount）を指定します
      serviceAccountName: ocr-app-sa
      containers:
      - name: python-worker
        image: {{ .Values.pythonWorker.image }}
        imagePullPolicy: Always
        env:
        - name: GCP_PROJECT_ID
          value: {{ .Values.gcp.projectId }}
        # ⚠️ GOOGLE_APPLICATION_CREDENTIALS、volumeMounts、volumes はすべて消去しました！




///////////////////////////////////////////////////////////////////////////////////////////////////////////
// ●Go(main.go)
///////////////////////////////////////////////////////////////////////////////////////////////////////////
package main

import (
	"context"
	"fmt"
	"io"
	"log" // 🌟 log パッケージを追加しました
	"net/http"
	"os"
	"path/filepath"
	"time"

	"cloud.google.com/go/pubsub"
	"cloud.google.com/go/storage"
)

func main() {
	http.HandleFunc("/upload", uploadHandler)
	fmt.Println("[Go API] サーバーがポート 8080 で起動しました。")
	if err := http.ListenAndServe(":8080", nil); err != nil {
		fmt.Printf("サーバー起動エラー: %v\n", err)
	}
}

func uploadHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POSTメソッドのみ受け付けます", http.StatusMethodNotAllowed)
		return
	}

	projectID := os.Getenv("GCP_PROJECT_ID")
	topicID := "ocr-task-topic"
	bucketName := fmt.Sprintf("ocr-images-bucket-%s", projectID)

	// 🌟 1. プロジェクトIDのチェック（サーバーを落とさず、ユーザーにエラーを返します）
	if projectID == "" {
		log.Println("❌ エラー: 環境変数 GCP_PROJECT_ID が設定されていません")
		http.Error(w, "サーバー設定エラー (GCP_PROJECT_ID が不足しています)", http.StatusInternalServerError)
		return
	}

	// 🌟 2. 認証方式のログ案内（厳密なチェックはせず、案内のみにします）
	if os.Getenv("GOOGLE_APPLICATION_CREDENTIALS") == "" {
		log.Println("💡 GOOGLE_APPLICATION_CREDENTIALS が空のため、GKEの Workload Identity (キーレス認証) を自動適用します。")
	} else {
		log.Println("🔑 秘密鍵ファイルを使用した認証を使用します。パス:", os.Getenv("GOOGLE_APPLICATION_CREDENTIALS"))
	}

	// リクエストから画像ファイル（キー名: "image"）を取り出す
	file, header, err := r.FormFile("image")
	if err != nil {
		http.Error(w, "ファイルの取得に失敗しました: "+err.Error(), http.StatusBadRequest)
		return
	}
	defer file.Close()

	fileName := fmt.Sprintf("%d_%s", time.Now().Unix(), filepath.Base(header.Filename))
	ctx := context.Background()

	// 1. GCSへのアップロード（SDKが自動で環境変数またはWorkload Identityを判別します）
	storageClient, err := storage.NewClient(ctx)
	if err != nil {
		log.Printf("❌ GCSクライアント作成失敗: %v\n", err)
		http.Error(w, "GCSクライアント作成失敗: "+err.Error(), http.StatusInternalServerError)
		return
	}
	defer storageClient.Close()

	gcsObject := storageClient.Bucket(bucketName).Object(fileName)
	gcsWriter := gcsObject.NewWriter(ctx)
	if _, err := io.Copy(gcsWriter, file); err != nil {
		log.Printf("❌ GCS書き込み失敗: %v\n", err)
		http.Error(w, "GCS書き込み失敗", http.StatusInternalServerError)
		return
	}
	gcsWriter.Close()

	realGCSPath := fmt.Sprintf("gs://%s/%s", bucketName, fileName)
	fmt.Printf("[Go API] GCS保存成功: %s\n", realGCSPath)

	// 2. Pub/Sub公式ライブラリを使ってメッセージを送信
	pubsubClient, err := pubsub.NewClient(ctx, projectID)
	if err != nil {
		log.Printf("❌ Pub/Subクライアント作成失敗: %v\n", err)
		http.Error(w, "Pub/Subクライアント作成失敗: "+err.Error(), http.StatusInternalServerError)
		return
	}
	defer pubsubClient.Close()

	t := pubsubClient.Topic(topicID)
	result := t.Publish(ctx, &pubsub.Message{
		Data: []byte(realGCSPath),
	})

	// 送信完了を待機
	_, err = result.Get(ctx)
	if err != nil {
		fmt.Printf("[Go API] Pub/Sub送信失敗: %v\n", err)
		http.Error(w, "Pub/Sub送信失敗", http.StatusInternalServerError)
		return
	}

	fmt.Println("[Go API] Pub/Subへのパス送信に成功しました！")
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("画像アップロード & パイプライン投入 成功！\n"))
}


///////////////////////////////////////////////////////////////////////////////////////////////////////////
// ●Python(worker.py)
///////////////////////////////////////////////////////////////////////////////////////////////////////////
import os
import time
import signal
import sys
from google.cloud import storage
from google.cloud import pubsub_v1

# グローバルでクライアントを1度だけ初期化（使い回して高速化）
PROJECT_ID = os.environ.get("GCP_PROJECT_ID")
SUBSCRIBER = pubsub_v1.SubscriberClient()
STORAGE_CLIENT = storage.Client()

def receive_sigterm(signum, frame):
    print("[Python Worker] KEDAからの終了シグナルを検知しました。安全に停止します。")
    sys.exit(0)

def pull_message():
    subscription_id = "ocr-task-sub"
    subscription_path = SUBSCRIBER.subscription_path(PROJECT_ID, subscription_id)

    try:
        response = SUBSCRIBER.pull(
            request={"subscription": subscription_path, "max_messages": 1, "return_immediately": True}
        )
    except Exception as e:
        print(f"Pub/Subからの受信エラー: {e}")
        return False

    if not response.received_messages:
        return False

    received_message = response.received_messages[0]
    ack_id = received_message.ack_id
    gcs_path = received_message.message.data.decode("utf-8")
    
    print(f"\n[Python Worker] 受信成功！ GCSパス: {gcs_path}")
    
    try:
        # ダウンロード処理
        download_image_from_gcs(gcs_path)
        
        # メイン処理（仮のOCR処理）
        print("[Python Worker] 仮OCRモデルで処理中 (5秒)...")
        time.sleep(5) 
        
        # 成果物保存
        save_result_to_gcs(gcs_path)
        
        # 成功時のみAckを送信
        SUBSCRIBER.acknowledge(request={"subscription": subscription_path, "ack_ids": [ack_id]})
        print("[Python Worker] Ack送信完了。キューから削除されました。\n")
        return True

    except Exception as e:
        print(f"[重大エラー] 処理全体、またはGCS操作でエラーが発生: {e}")
        # 🌟 失敗時は即座にキューに戻して他のワーカーに再処理させる（Nack）
        SUBSCRIBER.modify_ack_deadline(
            request={"subscription": subscription_path, "ack_ids": [ack_id], "ack_deadlines": [0]}
        )
        print("[Python Worker] エラーのためメッセージをキューに即座に返却しました。\n")
        return False

def download_image_from_gcs(gcs_path):
    path_without_scheme = gcs_path.replace("gs://", "")
    parts = path_without_scheme.split("/", 1)
    bucket_name, blob_name = parts[0], parts[1]
    local_filename = os.path.basename(blob_name)
    
    bucket = STORAGE_CLIENT.bucket(bucket_name)
    blob = bucket.blob(blob_name)
    blob.download_to_filename(local_filename)
    print(f"[Python Worker] ダウンロード完了: {os.path.abspath(local_filename)}")

def save_result_to_gcs(gcs_path):
    result_bucket_name = f"ocr-results-bucket-{PROJECT_ID}"
    original_filename = os.path.basename(gcs_path)
    
    # 🌟 拡張子に関わらず安全に「_result.txt」を組み立てる
    base, _ = os.path.splitext(original_filename)
    result_filename = f"{base}_result.txt"
    
    bucket = STORAGE_CLIENT.bucket(result_bucket_name)
    blob = bucket.blob(result_filename)
    
    log_content = f"Timestamp: {time.strftime('%Y-%m-%d %H:%M:%S')}\nFileName: {gcs_path}\nStatus: SUCCESS\n"
    blob.upload_from_string(log_content, content_type="text/plain")
    print(f"[Python Worker] 成果物をGCSに保存しました: gs://{result_bucket_name}/{result_filename}")

def main():
    """プログラム全体のメインエントリーポイント"""
    signal.signal(signal.SIGTERM, receive_sigterm)
    print("[Python Worker] 起動しました。ループを開始します。")
    
    while True:
        has_message = pull_message()
        if has_message:
            continue
        time.sleep(2)

if __name__ == "__main__":
    main() # 👈 直接実行された時だけ main() を呼び出す


///////////////////////////////////////////////////////////////////////////////////////////////////////////
// ●Terraform(main)
///////////////////////////////////////////////////////////////////////////////////////////////////////////
##########################################################
# 1. プロバイダー & 共通データ定義
##########################################################
provider "google" {
  project = var.project_id
  region  = var.region
}

data "google_client_config" "default" {}

provider "kubernetes" {
  host                   = "https://${google_container_cluster.primary.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(google_container_cluster.primary.master_auth[0].cluster_ca_certificate)
}

# GKEノードプールが使用するデフォルトのコンピュートサービスアカウント
data "google_compute_default_service_account" "default" {}

##########################################################
# 2. クラウドストレージ (GCS バケット)
##########################################################
# 画像保存用バケット
resource "google_storage_bucket" "ocr_images" {
  name                     = "ocr-images-bucket-${var.project_id}"
  location                 = "ASIA-NORTHEAST1"
  force_destroy            = true
  public_access_prevention = "enforced"
}

# 処理結果（テキスト）保存用バケット
resource "google_storage_bucket" "ocr_results" {
  name                     = "ocr-results-bucket-${var.project_id}"
  location                 = "ASIA-NORTHEAST1"
  force_destroy            = true
  public_access_prevention = "enforced"
}

##########################################################
# 3. メッセージング (Pub/Sub)
##########################################################
resource "google_pubsub_topic" "ocr_task" {
  name = "ocr-task-topic"
}

resource "google_pubsub_subscription" "ocr_task_sub" {
  name                 = "ocr-task-sub"
  topic                = google_pubsub_topic.ocr_task.name
  ack_deadline_seconds = 60
}

##########################################################
# 4. コンテナレジストリ (Artifact Registry)
##########################################################
resource "google_artifact_registry_repository" "ocr_repo" {
  location      = var.region
  repository_id = "ocr-pipeline-repo"
  format        = "DOCKER"
}

# ==============================================================================
# 5. GKE クラスター（★Workload Identity設定を追加）
# ==============================================================================
resource "google_container_cluster" "primary" {
  name     = "ocr-pipeline-cluster"
  location = "${var.region}-a"
  
  deletion_protection = false
  remove_default_node_pool = true
  initial_node_count       = 1

  # 🌟 Workload Identityを有効化する設定
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }
}

# ==============================================================================
# 5.5 GKE カスタムノードプール（🌟これが必要でした！）
# ==============================================================================
resource "google_container_node_pool" "primary_nodes" {
  name       = "ocr-node-pool"
  location   = google_container_cluster.primary.location
  cluster    = google_container_cluster.primary.name
  
  autoscaling {
    min_node_count = 1
    max_node_count = 5
  }

  node_config {
    machine_type = "e2-standard-2" 
    
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
}

# ==============================================================================
# 6. IAM (サービスアカウントとGCP権限の定義)
# ==============================================================================

# --- 6-1. KEDA専用サービスアカウント（変更なし） ---
resource "google_service_account" "keda_sa" {
  account_id   = "keda-metrics-scaler"
  display_name = "KEDA Metrics Scaler Service Account"
}

resource "google_project_iam_member" "keda_pubsub_viewer" {
  project = var.project_id
  role    = "roles/pubsub.viewer"
  member  = "serviceAccount:${google_service_account.keda_sa.email}"
}

resource "google_project_iam_member" "keda_pubsub_subscriber" {
  project = var.project_id
  role    = "roles/pubsub.subscriber"
  member  = "serviceAccount:${google_service_account.keda_sa.email}"
}

resource "google_project_iam_member" "keda_monitoring_viewer" {
  project = var.project_id
  role    = "roles/monitoring.viewer"
  member  = "serviceAccount:${google_service_account.keda_sa.email}"
}

# --- 6-2. アプリケーション専用サービスアカウント（変更なし） ---
resource "google_service_account" "app_sa" {
  account_id   = "ocr-app-worker"
  display_name = "OCR Application App Worker Service Account"
}

resource "google_project_iam_member" "app_pubsub_publisher" {
  project = var.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.app_sa.email}"
}

resource "google_project_iam_member" "app_storage_admin" {
  project = var.project_id
  role    = "roles/storage.objectAdmin"
  member  = "serviceAccount:${google_service_account.app_sa.email}"
}

resource "google_project_iam_member" "app_pubsub_subscriber" {
  project = var.project_id
  role    = "roles/pubsub.subscriber"
  member  = "serviceAccount:${google_service_account.app_sa.email}"
}

# ------------------------------------------------------------------------------
# 🌟【最重要追加】GKEの世界とGCPの世界を紐付ける架け橋（Workload Identity User）
# ------------------------------------------------------------------------------

# ① KEDA用の紐付け（kedaネームスペースの「keda-operator」という名前のK8sアカウントと結合）
resource "google_service_account_iam_member" "keda_wi" {
  service_account_id = google_service_account.keda_sa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[keda/keda-operator]"
  
  # 🌟【追記】GKEクラスターとノードプールが完全に出来上がってから作らせる
  depends_on = [
    google_container_cluster.primary,
    google_container_node_pool.primary_nodes
  ]
  
}

# ② アプリ用の紐付け（defaultネームスペースの「ocr-app-sa」という名前のK8sアカウントと結合）
resource "google_service_account_iam_member" "app_wi" {
  service_account_id = google_service_account.app_sa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[default/ocr-app-sa]"
  
  # 🌟【追記】GKEクラスターとノードプールが完全に出来上がってから作らせる
  depends_on = [
    google_container_cluster.primary,
    google_container_node_pool.primary_nodes
  ]
  
}

# ==============================================================================
# 7. Kubernetes 内部設定 (Namespace & 🌟ServiceAccountの作成)
# ==============================================================================
# ※ 以前あった「google_service_account_key」と「kubernetes_secret」は跡形もなく消去しました！

resource "kubernetes_namespace" "keda" {
  metadata {
    name = "keda"
  }
  depends_on = [google_container_node_pool.primary_nodes]
}

# 🌟【追加】defaultネームスペース側に、アプリが身分を証明するための会員証（ServiceAccount）を作成
resource "kubernetes_service_account" "app_k8s_sa" {
  metadata {
    name      = "ocr-app-sa"
    namespace = "default"
    annotations = {
      # この注釈（アノテーション）を入れることで、GCPのSAとガチッとリンクします
      "iam.gke.io/gcp-service-account" = google_service_account.app_sa.email
    }
  }
  depends_on = [google_container_node_pool.primary_nodes]
}




