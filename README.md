# 1.はじめに
この記事では、Go言語による高速なAPI受付と、PythonのEasyOCRエンジンをgRPCで繋ぐ、スケーラブルなOCRバックエンド基盤を構築しました。
単なるアプリケーションの実装に留まらず、Google Kubernetes Engine（GKE）上でのサイドカー構成を採用。
この基盤構築に関する詳細な説明を行っています。
全体の設計思想や背景については、まず以下の記事をご一読ください。
**・設計ポイント解説：** [ポイント説明編]（リンク）
また、この構成基盤の検証は、以下の記事でまとめています。
**・負荷試験と性能分析：** [検証編]（リンク）


| ◆構成 |
|:---------------|
|[1.はじめに](#1はじめに) |
|[2.技術スタックとシステム構成](#2技術スタックとシステム構成)|
|[3.APIサーバー(Go)](#3apiサーバーgo)|
|[4.推論サーバ(python)](#4推論サーバpython)|
|[5.Terraformによるインフラ自動化](#5terraformによるインフラ自動化)|
|[6.Helmによるワークロード管理](#6helmによるワークロード管理)|
|[7.デプロイ手順](#7デプロイ手順)|
|[8.おわりに](#8おわりに)|

# 2.技術スタックとシステム構成

## 2-1. 技術スタック

本システムでは、以下の技術スタックを採用しています。


| カテゴリ | 技術・ツール | 用途 |
| :--- | :--- | :--- |
| **Frontend API** | **Go (Gin)** | HTTPリクエスト受付、gRPCクライアント、構造化ログ出力 |
| **Inference Engine** | **Python (EasyOCR)** | gRPCサーバー、EasyOCRによる文字認識処理 |
| **Communication** | **gRPC / Protocol Buffers** | Go-Python間の高速・型安全なマイクロサービス通信 |
| **Infrastructure** | **GKE (Standard)** | コンテナオーケストレーション、HPAによるオートスケーリング |
| **IaC** | **Terraform** | VPC, GKE, Artifact Registry, Log Sinkのコード管理 |
| **Observability** | **Cloud Logging / BigQuery** | 構造化ログの集約、およびSQLによる推論精度・性能分析 |
| **Testing** | **k6** | 期待値（正解データ）を用いた高負荷・精度検証試験 |





### 2-2. 主要ライブラリ
特に注目すべき採用ライブラリは以下の通りです。

| 対象 | ライブラリ | 採用理由 |
| :--- | :--- | :--- |
| **Go** | **Gin** | 軽量かつ高速で、構造化ログとの相性が良いため。 |
| **Go** | **gopsutil** | Pod内のリソース使用率をログに含め、分析に活用するため。 |
| **Python** | **EasyOCR** | PyTorchベースで精度が高く、日本語・英語に標準対応しているため。 |
| **Python** | **psutil** | 推論時のCPU負荷を正確に計測し、ログ出力するため。 |
| **Common** | **gRPC** | HTTP/1.1よりも低遅延で、双方向通信やストリーミングにも対応可能なため。 |



## 2-3. ディレクトリ構成
インフラ管理（Terraform）コマンドで、デプロイできる以下の構成となっています。
このデータセットは、[GitHubレポジトリ](https://github.com/wata123-t/go-python-easyocr-gke) に登録しています。


```text
.
├── terraform/          # GKE, VPC, Artifact Registry, Log Sinkの定義
├── chart/              # Kubernetesデプロイ用リソース (Helm Chart形式)
│   └── templates/      # Deployment, Service, HPA, RBACのマニフェスト
├── go-api/             # フロントエンドAPI (Go / Gin)
├── python-api/         # 推論エンジン (Python / EasyOCR / gRPC Server)
├── pb/                 # gRPC定義ファイル (.proto) と自動生成コード
└── k6/                 # 負荷試験スクリプト
    └── test_images/    # 検証用画像および正解データ(mapping.json)
```

## 2-3. システム構成
本プロジェクトは、設計・検証・分析の各工程を GitHub Actions で統合しています。全体のデータの流れと、各記事の解説範囲は以下の通りです。

```mermaid
graph TD
    subgraph Public_Internet
        User([User / k6])
    end

    subgraph GCP_Project
        subgraph GKE_Cluster
            LB[GCP LoadBalancer]
            
            subgraph Go_API_Pod_Group
                HPA_Go[HPA] --> Go[Go API: Gin]
                Go --> |Structured Log| CL[Cloud Logging]
            end

            subgraph Python_OCR_Pod_Group
                HPA_Py[HPA] --> Py[Python API: EasyOCR]
                Py --> |Structured Log| CL
            end

            LB --> Go
            Go --> |gRPC / Client-side LB| Py
        end

        subgraph Data_Analytics
            CL --> |Log Sink| BQ[(BigQuery)]
        end
    end

    style GKE_Cluster fill:#f9f9f9,stroke:#333,stroke-width:2px
    style Data_Analytics fill:#e1f5fe,stroke:#01579b,stroke-width:2px
```
### <ins>_◆関係記事_</ins>

本記事は、以下の内容にも関連しています。

**・1.[【ハード・ソフト協調検証①】Verilog HDLによる暗号化回路(AES-128)の設計](https://qiita.com/watapy/items/cc216b77695b3435f2f5)**



# 3.APIサーバー(Go)
Goを使用したAPIサーバーの構成について解説します。今回、初めてGoを使用するため、AIと相談しながら「GKE上での安定稼働」と「低レイテンシ」を目標に構築しました。
フロントエンドのGo APIと、バックエンドのPython OCRエンジンの通信には、パフォーマンスを最大限に引き出すため **gRPC** を採用しています。


## 3-1.gRPC通信（Protocol Buffers）による最適化
単純なREST（HTTP/1.1）ではなくgRPCを採用した理由は、型定義の厳密さと転送効率です。

**・データ転送の効率化:** 画像のようなバイナリデータは、JSONではBase64エンコードによる肥大化（約1.3倍）を招きますが、gRPCでは bytes 型としてそのまま転送できるため、帯域を節約できます。
**・型安全なインターフェース:** .proto ファイルからGo/Python両方のコードを生成することで、言語間の「解釈の不一致」をコンパイルレベルで排除しています。


```golang:./pb/predict.proto
syntax = "proto3";
package ocr;

service Predictor {
  rpc Predict (ImageRequest) returns (PredictResponse);
}

message ImageRequest {
  bytes image_data = 1; // 画像をバイナリで高速転送
}

message PredictResponse {
  string result = 1;
}

```

## 3-2.プログラム実行フロー

軽量で高速なWebフレームワーク **Gin** を使用し、起動時にgRPCクライアントを初期化した後、リクエストを待ち受けます。

**・起動時のgRPC接続**
リクエストごとに gRPC 接続（grpc.Dial）を作成するのではなく、main 関数で一度だけ接続を確立し、それを各ハンドラで使い回す設計となっています。

**・`r.Run()`による内部的な無限ループ（Listen and Serve）を実行** 
OSからのシグナルやエラーがない限り、プロセスを常駐させてリクエストを待ち受け続けます。


```golang:./go-api/main.go
	log.Printf("Go API Server started on :8080 (Timeout: %ds)", timeoutSec)
    // サーバーを起動し、リクエストをブロッキングして待ち受ける
	r.Run(":8080")
}
```

以下の内容を補足説明願います
## 3-3.GKE環境におけるサイドカー構成と最適化
本システムでは、Go APIとPython推論エンジンを同一Pod内にデプロイする サイドカー構成 を採用しています。これにより、以下の最適化を実現しました。

**・通信の極小化とロードバランシングの簡略化**
通信先が常に localhost（同一Pod内）であるため、複雑なサービスディスカバリやロードバランシング設定をあえて排除し、最小レイテンシでの通信を優先しました。


**・セキュアかつ高速な非暗号化通信**
通信がPod外部に漏れることがないため、SSL/TLSを介さない h2c (HTTP/2 Cleartext) を採用しています。

**・「KeepaliveParams」による接続の安定化**
隣接するコンテナ間であっても、予期せぬプロセスの瞬断は起こり得ます。

**Time (60s):** 通信がない間も「生きてる？」と定期的に確認を送る間隔です。
**Timeout (20s):** 確認に対して返事がない場合に「切断された」と判断するまでの時間です。


```golang:./go-api/main.go
	// 1. Pythonサーバーへの「通信経路」を確立（この時点ではまだ土台作り）
	conn, err := grpc.Dial(
		targetAddr,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		//grpc.WithDefaultServiceConfig(serviceConfig),
		grpc.WithKeepaliveParams(keepalive.ClientParameters{
			Time:                60 * time.Second,	// 60秒ごとに生存確認(ヘルスチェック)
			Timeout:           20 * time.Second,	// 生存確認の応答待機（20秒）
			PermitWithoutStream: true,			// アイドル時も生存確認を許可
		}),
	)
	// 2. 接続そのものに失敗した場合（住所間違いや相手が起動していない等）は即終了
	if err != nil {
		log.Fatalf("gRPC接続失敗: %v", err)
	}
	// 3. 【重要】プログラム終了時（main関数終了時）に必ず回線を閉じるよう予約
	defer conn.Close()
	// 4. 確立した回線(conn)を使い、Pythonの機能を呼び出すための「専用窓口(クライアント)」を作成
	client := pb.NewPredictorClient(conn)
```




## 3-4.POSTリクエスト処理
外部から受け取った画像と検証用の期待値を処理します。
外部からPOSTリクエストを受け取ると、以下の記述部から処理が実行されます。

```golang:./go-api/main.go
	r.POST("/predict", func(c *gin.Context) {
		startTime := time.Now()
        ............
        ............
	})
```

以下の処理内容が実施されます。

|概要|処理内容 |メリット |
| :--- | :--- |:--- |
|相関IDの生成|`X-Correlation-ID`を取得、生成|Go/Pythonを跨いだログの追跡|
|精度計測用データの取得|`X-Expected-Text`の取得|正解率の算出|
|gRPCコンテキスト|タイムアウトとメタデータの埋め込み|障害の隔離と、Python側への相関IDの伝搬|
|推論リクエスト|バイナリデータのままgRPC送信|JSON変換を避け、メモリと帯域の消費を最小化|


これらの実装により、APIサーバーは単なる『窓口』としてだけでなく、システムの信頼性を担保するためのコントローラーとして機能させています。

## 3-5.Cloud Logging への構造化ログ出力
運用監視と分析のため、ログはすべて JSON形式の構造化ログ として標準出力します。
これを Google Cloud Logging が自動回収し、BigQuery へシンク（転送）します。

```golang:./go-api/main.go
// Cloud Logging用の構造化ログ定義
type CloudLog struct {
	Severity   string  `json:"severity"`    // GCPが認識するログレベル
	RequestID  string  `json:"request_id"`  // 相関ID
	Step       string  `json:"step"`        // 処理工程（go-api-complete等）
	LatencyMs  int64   `json:"duration_ms"` // 処理時間（数値で出すことで統計が可能に）
	IsSuccess  bool    `json:"is_success"`  // 成功可否
	CPUUsage   float64 `json:"cpu_usage"`   // Podのリソース状況
	PodName    string  `json:"pod_name"`    // どのPodで処理されたか
	IsMatch    bool    `json:"is_match"`    // OCRの正解判定
	Message    string  `json:"message"`     // 自由記述メッセージ
```


## 3-7.全コード
コード詳細は、こちらを参照して下さい。
<details>
<summary>./go/main.go</summary>

```go
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/shirou/gopsutil/v4/cpu"
	"github.com/google/uuid"
	
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/keepalive"
	"google.golang.org/grpc/metadata"

	"go-api/pb"
)

// Cloud Logging用の構造化ログ
type CloudLog struct {
	Severity   string  `json:"severity"`
	RequestID  string  `json:"request_id"`
	Step       string  `json:"step"`
	LatencyMs  int64   `json:"duration_ms"`
	IsSuccess  bool    `json:"is_success"`
	CPUUsage   float64 `json:"cpu_usage"`
	PodName    string  `json:"pod_name"`
	Message    string  `json:"message"`
	Expected   string  `json:"expected"`
	IsMatch    bool    `json:"is_match"`
	K6SendTime int64   `json:"k6_send_time"` //  k6の送信時刻:時間ずれあり未使用
}

func main() {
	// ホスト名を取得
	podName, _ := os.Hostname()
	if podName == "" {
		podName = "unknown-go-pod"
	}

	// 環境変数からタイムアウト時間を取得(失敗時は15sec)
	timeoutStr := os.Getenv("TIMEOUT_SECONDS")
	timeoutSec, err := strconv.Atoi(timeoutStr)
	if err != nil {
		timeoutSec = 15
	}

	// gRPC 接続設定
	targetAddr := os.Getenv("PYTHON_RPC_ADDR")
	if targetAddr == "" {
		targetAddr = "localhost:50051"
	}

	// 1. Pythonサーバーへの「通信経路」を確立（この時点ではまだ土台作り）
	conn, err := grpc.Dial(
		targetAddr,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		//grpc.WithDefaultServiceConfig(serviceConfig),
		grpc.WithKeepaliveParams(keepalive.ClientParameters{
			Time:                60 * time.Second,	// 60秒ごとに生存確認(ヘルスチェック)
			Timeout:           20 * time.Second,	// 生存確認の応答待機（20秒）
			PermitWithoutStream: true,			// アイドル時も生存確認を許可
		}),
	)
	// 2. 接続そのものに失敗した場合（住所間違いや相手が起動していない等）は即終了
	if err != nil {
		log.Fatalf("gRPC接続失敗: %v", err)
	}
	// 3. 【重要】プログラム終了時（main関数終了時）に必ず回線を閉じるよう予約
	defer conn.Close()
	// 4. 確立した回線(conn)を使い、Pythonの機能を呼び出すための「専用窓口(クライアント)」を作成
	client := pb.NewPredictorClient(conn)

	r := gin.Default()

	r.POST("/predict", func(c *gin.Context) {
		startTime := time.Now()

		// 1. リクエストIDの取得
		requestID := c.GetHeader("X-Correlation-ID")
		
		// もしヘッダーになければ、UUID v4 を新しく生成する
		if requestID == "" {
			// uuid.NewRandom() は高度な乱数生成器を使用する
			newID, err := uuid.NewRandom()
			if err != nil {
				// 万が一生成に失敗した際のフォールバック（極めて稀）
				requestID = fmt.Sprintf("gen-%d", startTime.UnixNano())
			} else {
			 	requestID = newID.String()
			}
		}

		//  k6等から送られてくる正解文字列の取得
		expectedText := c.GetHeader("X-Expected-Text")

		// 2. 画像データの読み込み
		file, header, err := c.Request.FormFile("image")
		if err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "ファイル取得エラー"})
			return
		}
		defer file.Close()

		imageData, _ := io.ReadAll(file)
		log.Printf("[%s] 受信: %s (%d bytes)", requestID, header.Filename, len(imageData))

		// 3. gRPCコンテキストの準備
		ctx := metadata.AppendToOutgoingContext(context.Background(), "x-correlation-id", requestID)
		ctx, cancel := context.WithTimeout(ctx, time.Duration(timeoutSec)*time.Second)
		defer cancel()

		// 4. Python OCRエンジンへリクエスト送信
		res, err := client.Predict(ctx, &pb.ImageRequest{ImageData: imageData})

		// 5. メトリクス収集とログ出力
		percent, _ := cpu.Percent(0, false)
		var cpuVal float64
		if len(percent) > 0 {
			cpuVal = percent[0]
		}

		isSuccess := (err == nil)
		duration := time.Since(startTime).Milliseconds()

		// 正解の合否判定
		isMatch := false
		if isSuccess && expectedText != "" {
			isMatch = strings.Contains(res.Result, expectedText)
		}

		logEntry := CloudLog{
			Severity:   "INFO",
			RequestID:  requestID,
			Step:       "go-api-complete",
			LatencyMs:  duration,
			IsSuccess:  isSuccess,
			CPUUsage:   cpuVal,
			PodName:    podName,
			Expected:   expectedText,
			IsMatch:    isMatch,
			Message:    fmt.Sprintf("OCR Processed by %s", podName),
		}

		if isSuccess {
			logEntry.Message = fmt.Sprintf("Expected: %s, Got: %s", expectedText, res.Result)
		} else {
			logEntry.Severity = "ERROR"
			logEntry.Message = fmt.Sprintf("Predict error: %v", err)
		}

		// 標準出力をJSON化。Cloud Loggingはこれを自動解析してフィールド分割してくれる
		logJSON, _ := json.Marshal(logEntry)
		fmt.Println(string(logJSON))

		//  レスポンス返却-1
		if !isSuccess {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "OCR処理エラーまたはタイムアウト", "id": requestID})
			return
		}


		//  レスポンス返却-2
		c.JSON(http.StatusOK, gin.H{
			"message": "推論完了",
			"result":  res.Result,
			"id":      requestID,
		})
	})

	log.Printf("Go API Server started on :8080 (Timeout: %ds)", timeoutSec)
	r.Run(":8080")
}

```

</details>


# 4.推論サーバ(python)
バックエンドのPython側では、 **EasyOCR** を使用した推論エンジンを構築しました。Go側と同様、gRPCを採用することで「通信」と「ロジック」を分離し、高負荷な処理を安定させています。

## 4-1.gRPCによるリクエスト待ち受け
Python側も `.proto` から生成されたインターフェース（`PredictorServicer`）を継承して実装します。gRPCを採用した最大の理由は、 **「型定義の共有」** と **「シリアル化の高速化」** です。通常、画像のようなバイナリデータをHTTP/JSONで扱うとBase64エンコードによるオーバーヘッドが発生しますが、gRPC（Protocol Buffers）ならバイナリのまま効率的に転送できます。
  


```python:./python-ocr/server.py
class Predictor(pb2_grpc.PredictorServicer):
    def Predict(self, request, context):
        # ここがGoからのリクエストを受け取る「ハンドラ」
        # request.image_data には既に画像バイナリが入っている
        img = Image.open(io.BytesIO(request.image_data))

```

**・インターフェースの強制:** `.proto` で定義した `Predict` メソッドを実装しないとエラーになるため、Go（クライアント）側との仕様のズレがコンパイル段階で防げます。
**・シームレスなバイナリ操作:** Go側で `[]byte` として送った画像データは、Python側ではそのまま `bytes` 型として受け取れるため、パース処理が非常にシンプルになります。

## 4-2.重いモデルのライフサイクル管理
OCRエンジン（モデル）のロードには時間がかかります。リクエストのたびにロードするのではなく、**プロセスの起動時に一度だけロード**し、メモリ上に保持（ホットスタンバイ）事での処理速度の効率化を図っています。

```python:./python-ocr/server.py
# Pod起動時に一度だけ実行（起動時間は長くなるが、リクエスト処理は最速になる）
print(f"[{POD_NAME}] Loading EasyOCR Reader...")
reader = easyocr.Reader(['en', 'ja'], gpu=False)
```

:::note info
GPU=False の意図
今回はGCPの標準的なCPUノードでの動作を想定し、意図的に gpu=False（CPU推論）に設定しています。もしGPU環境へ移行する場合は、ここを環境変数で切り替えられるように設計すると、よりポータビリティ（移植性）が高まります。
:::


## 4-3.サイドカー構成に最適化した設定
同じPod内の localhost で通信するサイドカーの特性を活かし、低レイテンシとリソース効率を両立させる設定を入れています。

**・コネクションの永続化**
サイドカー間は1対1の固定関係であるため、max_connection_age_ms: 0（無制限）に設定。再接続のオーバーヘッドを排除し、通信速度を最大化しています。
**・「1コア制限」に合わせたスレッド調整**
CPUリソースを1個程度に制限している環境では、ワーカー数を増やしすぎるとコンテキストスイッチによる性能低下を招きます。
・`max_workers=3`: 「実行中(1) + 待機(2)」の最小構成に絞り、CPUの奪い合いを防いでいます。
・`max_concurrent_streams`: 同時受付数を制限し、メモリのパンクを防止します。
**・安定性を高めるKeepalive**
推論のような重い処理中でも、`keepalive` を設定することで「通信断」の誤検知を防ぎ、常に安定した接続を維持します。

```python:./python-ocr/server.py
    # サイドカー構成に最適化した設定
    server_options = [
        # localhost間通信なので、接続寿命は長くしてパフォーマンスを優先
        ('grpc.max_connection_age_ms', 0), # 0は無制限（切らない）
        
        # 1つのコネクションで同時に受け付けるリクエスト数
        # 1コア制限なら、窓口は2〜3あれば十分（1つ処理中に次を受付可能にする）
        ('grpc.max_concurrent_streams', 5),
        
        # 通信の安定性を保つためのKeepalive設定
        ('grpc.keepalive_time_ms', 10000),
        ('grpc.keepalive_timeout_ms', 5000),
        ('grpc.permit_keepalive_without_calls', True),
    ]
    
    server = grpc.server(
        # ワーカー数は「2〜3」程度がベスト。
        # 1コア制限下では、これ以上増やしてもCPUの奪い合いで遅くなるだけ。
        futures.ThreadPoolExecutor(max_workers=3),
        options=server_options
    )
```




## 4-4.構造化ログ(分散トレーシング)
複数のコンテナにまたがる処理の「可観測性（Observability）」を高めるため、以下の工夫を行っています。

**・一気通貫のトラッキング**
`context.invocation_metadata()` から Go 側で生成された x-`correlation-id` を抽出しています。これにより、Cloud Logging 上で **「一つのリクエストが両サーバーをどう通ったか」** を同じ ID で一気に検索可能です。

**・分析可能な構造化ログ**
標準出力に JSON 形式でログを流すことで、Cloud Logging に「構造化ログ」として認識させます。


```python:./python-api/server.py
        # Goと共通のIDを付与し、実行時間やリソース状況をJSON出力
        log_entry = {
            "severity": "INFO" if is_success else "ERROR",
            "request_id": request_id,
            "step": "python-ocr-inference",
            "duration_ms": duration_ms,
            "is_success": is_success,
            "detected_count": len(ocr_results) if is_success else 0,
            "cpu_usage": cpu_usage,
            "pid": os.getpid(),
            "pod_name": POD_NAME,
            "message": f"OCR completed: {result_text[:50]}..." # ログが長くなりすぎないよう制限
        }
        print(json.dumps(log_entry))
        sys.stdout.flush() # 即座にログを反映
```


## 4-5.EasyOCRによる推論と結果の整形
ライブラリの出力をそのまま返すのではなく、APIとして扱いやすい形式に加工しています。

**・画像の変換**
gRPCで受け取ったバイナリデータ（bytes）を Pillow で開き、numpy 配列へ変換します。これにより、EasyOCRが解析可能な形式（OpenCV互換の形式）に橋渡しをします。


**・データの抽出と結合**
EasyOCRの戻り値は「座標・テキスト・確信度」を含むリスト形式ですが、本システムでは利用シーンを考慮し、テキスト情報のみを抽出しています。
・リスト内包表記: res[1] でテキスト部分のみを効率的に取得。
・カンマ区切りでの結合: 複数の行や単語が検出された場合も、一つの文字列として連結して Go 側へ返却します。

**・堅牢なエラーハンドリング**
画像破損や予期せぬエラーで推論が失敗した場合も、プロセスを落とさずにエラー内容をログ出力し、Go側へ「エラーメッセージ」として応答を返すことで、システム全体の可用性を維持しています。

```python:./python-api/server.py
            # 2. EasyOCRによる推論
            img = Image.open(io.BytesIO(request.image_data))
            img_np = np.array(img)
            
            # OCR実行
            ocr_results = reader.readtext(img_np, detail=1)
            
            # 結果の整形
            detected_texts = [res[1] for res in ocr_results]
            result_text = ", ".join(detected_texts) if detected_texts else "No text detected"
            is_success = True
            
        except Exception as e:
            result_text = f"Error: {str(e)}"
            print(f"[{POD_NAME}] OCR Error: {e}")
```

## 4-6.全コード
コード詳細は、こちらを参照して下さい。
<details>
<summary>./python-api/server.py</summary>

```python
import grpc
from concurrent import futures
import pb.predict_pb2 as pb2
import pb.predict_pb2_grpc as pb2_grpc
import time
import json
import sys
import os
import psutil
import io
import numpy as np
import easyocr
from PIL import Image

# Pod名は起動時に一度だけ取得
POD_NAME = os.environ.get('HOSTNAME', 'unknown-pod')

# Pod起動時に一度だけ実行（起動時間は長くなるが、リクエスト処理は最速になる）
print(f"[{POD_NAME}] Loading EasyOCR Reader...")
reader = easyocr.Reader(['en', 'ja'], gpu=False)

class Predictor(pb2_grpc.PredictorServicer):
    def Predict(self, request, context):
        # CPU計測リセット
        psutil.cpu_percent(interval=None) 
        start_time = time.time()
        
        # 1. gRPCメタデータからIDを抽出
        metadata = dict(context.invocation_metadata())
        request_id = metadata.get('x-correlation-id', 'unknown')

        result_text = ""
        is_success = False
        
        try:
            # 2. EasyOCRによる推論
            img = Image.open(io.BytesIO(request.image_data))
            img_np = np.array(img)
            
            # OCR実行
            ocr_results = reader.readtext(img_np, detail=1)
            
            # 結果の整形
            detected_texts = [res[1] for res in ocr_results]
            result_text = ", ".join(detected_texts) if detected_texts else "No text detected"
            is_success = True
            
        except Exception as e:
            result_text = f"Error: {str(e)}"
            print(f"[{POD_NAME}] OCR Error: {e}")

        # 3. クラウドロギング用の構造化ログ出力
        duration_ms = int((time.time() - start_time) * 1000)
        cpu_usage = psutil.cpu_percent(interval=None)

        # Goと共通のIDを付与し、実行時間やリソース状況をJSON出力
        log_entry = {
            "severity": "INFO" if is_success else "ERROR",
            "request_id": request_id,
            "step": "python-ocr-inference",
            "duration_ms": duration_ms,
            "is_success": is_success,
            "detected_count": len(ocr_results) if is_success else 0,
            "cpu_usage": cpu_usage,
            "pid": os.getpid(),
            "pod_name": POD_NAME,
            "message": f"OCR completed: {result_text[:50]}..." # ログが長くなりすぎないよう制限
        }
        print(json.dumps(log_entry))
        sys.stdout.flush() # 即座にログを反映

        return pb2.PredictResponse(result=result_text)


def serve():
    # サイドカー構成に最適化した設定
    server_options = [
        # localhost間通信なので、接続寿命は長くしてパフォーマンスを優先
        ('grpc.max_connection_age_ms', 0), # 0は無制限（切らない）
        
        # 1つのコネクションで同時に受け付けるリクエスト数
        # 1コア制限なら、窓口は2〜3あれば十分（1つ処理中に次を受付可能にする）
        ('grpc.max_concurrent_streams', 5),
        
        # 通信の安定性を保つためのKeepalive設定
        ('grpc.keepalive_time_ms', 10000),
        ('grpc.keepalive_timeout_ms', 5000),
        ('grpc.permit_keepalive_without_calls', True),
    ]
    
    server = grpc.server(
        # ワーカー数は「2〜3」程度がベスト。
        # 1コア制限下では、これ以上増やしてもCPUの奪い合いで遅くなるだけ。
        futures.ThreadPoolExecutor(max_workers=3),
        options=server_options
    )
    
    pb2_grpc.add_PredictorServicer_to_server(Predictor(), server)
    
    # サイドカーなので、localhost(127.0.0.1)からの接続のみ受け付ける設定でもOK
    # 汎用性を持たせるなら [::]:50051 のままでも問題ありません
    server.add_insecure_port('[::]:50051')
    
    server.start()
    print(f"[{POD_NAME}] Sidecar OCR Server started on port 50051")
    server.wait_for_termination()

if __name__ == '__main__':
    serve()

```
</details>


# 5.Terraformによるインフラ自動化
システムの土台となるGCPリソースはすべてTerraformで構成（IaC）しています。単にサーバーを立てるのではなく、「安く・止めず・分析しやすく」という3点をコードで定義しました。

## 5-1.可観測性の追求：ログの資産化（Sink to BigQuery）
単なるログ出力を超え、ログをデータとして活用する分析基盤を構築しています。

**・ログフィルタリング:** `google_logging_project_sink` で `request_id` を持つログのみを抽出。ノイズを排除し、必要なデータだけを効率的に蓄積します。

**・詳細分析:** BigQueryへ転送することで、SQLを用いて「OCR成功率」や「処理レイテンシー」を可視化・分析できるようになります。


## 5-2.コスト最適化とオートスケーリング
OCR処理は負荷が高い反面、常にフル稼働させる必要はありません。

**・Spotインスタンスの採用:** spot = true 設定により、通常の3分の1程度のコストで計算リソースを確保します。

**・Cluster Autoscaler:** autoscaling ブロックにより、ノード（マシン）自体も負荷に応じて1台から4台まで自動増減させます。HPA（Podの増減）と連動して、インフラ全体が伸縮します。


## 5-3.ネットワーク設計（VPC & Subnet）
K8sクラスターを構築する際、将来の拡張を見越してセカンダリIP範囲（Pod用・Service用）を明示的に定義しています。

**・IP範囲の分離:** Pod用とService用にそれぞれ /20（約4,000アドレス）の広大なプライベート帯域を確保。将来的なPodの増設やマイクロサービスの追加にも耐えられる設計です。

```hcl
secondary_ip_range {
  range_name    = "pod-ranges"
  ip_cidr_range = "192.168.16.0/20" # Podに割り当てられる広大なIP帯域
}
```



## 5-4.Artifact Registry

ビルドしたGoとPythonのDockerイメージを管理するプライベートリポジトリを定義しています。GKEとの親和性が高く、高速なイメージプルが可能です。

## 5-5. GKEクラスターの最適化設計
クラスター本体の設定にも、運用の安定性とセキュリティを高めるためのベストプラクティスを詰め込んでいます。

**・VPCネイティブクラスター（ip_allocation_policy）:**
ip_allocation_policy を定義し、PodやServiceにVPC内のセカンダリIPを直接割り当てる「VPCネイティブ」構成を採用しました。これにより、ネットワークのルーティングが効率化され、Pod間通信のパフォーマンスが向上します。
**・デフォルトノードプールの分離（remove_default_node_pool）:**
GKEが自動作成するデフォルトノードプールをあえて削除（true）し、独自に定義したノードプール（primary_nodes_hpa）のみで運用しています。理由: 管理外のノードが残るのを防ぎ、今回のように「Spotインスタンス」や「特定のマシンタイプ」を厳密に制御するためです。
**・削除保護（deletion_protection）:**
実運用を想定し、誤操作によるクラスター削除を防ぐ設定（false ※検証時は利便性のため解除）を明示。IaCによる破壊的変更からインフラを守る意識を反映しています。
**・権限の最小化（oauth_scopes）:**
https://googleapis.com を設定することで、ノード上のPodが Artifact Registry や Cloud Logging などのGCPサービスへ、安全かつスムーズにアクセスできるようにしています。











# 6.Helmによるワークロード管理

## 6-1.役割の分離：Terraform vs Helm
インフラのライフサイクルに合わせて管理ツールを使い分けています。

**・Terraform:** ネットワークやGKEクラスターなど、頻繁に変更しない「土台」を管理。

**・Helm:**　アプリのバージョンやリソース割り当てなど、頻繁にデプロイ・変更される「アプリケーション層」をパッケージ管理。



## 6-2. values.yaml
GoとPythonの両コンテナのサイドカー構成を設定しています。

**・Requests (1Gi):** スケジューリング時に確実に 1GB 確保し、動作の安定性を担保（守り）。
**・Limits (2Gi):** 複数のリクエストが重なった際のバーストを許容しつつ、ノード全体のメモリを食い潰さないよう上限を設定（攻め）。
**HPA:** 今回は、この機能は使用しません

:::note info
サイドカー間の疎通設定
GoコンテナからPythonコンテナへの通信先は、同じPod内なので localhost:50051 です。このように、異なる言語のプログラムをネットワーク的に一つの「塊（Pod）」として扱えるのがHelm（Kubernetes）で管理する最大のメリットです。
:::


<details>
<summary>./chart/values.yaml</summary>

```yaml:values.yaml
app:
  name: "ocr-service"
  go:
    image: "asia-northeast1-docker.pkg.dev/acquired-shape-470706-k0/ocr-images/go-api:latest"
    port: 8080
  python:
    image: "asia-northeast1-docker.pkg.dev/acquired-shape-470706-k0/ocr-images/python-api:latest"
    port: 50051
    resources:
      requests:
        cpu: "1000m"
        memory: "1Gi"
      limits:
        cpu: "1000m"
        memory: "2Gi"
  # HPAは全体に対してかける
hpa:
  enabled: false #無効化
  minReplicas: 1
  maxReplicas: 5
  targetCPU: 40  # OCRはCPUを食うため、少し高めに設定してバタつきを抑える
```
</details>

## 6-3. deployment.yaml
一つの Pod 内に Go と Python のコンテナを同居させる「サイドカー構成」を定義しています。

**・サイドカー間の超高速通信**
Go コンテナから Python コンテナへの接続先を `localhost:50051` としています。Pod 内のコンテナ間通信は `localhost` を経由するため、ネットワーク遅延がほぼゼロになります。

**・リソースの独立管理**
同じ Pod 内にありながら、Go と Python で個別に CPU/メモリの制限をかけています。
Python 側の 重いOCR 処理による影響が、go側に伝搬しない様にを遮断しています。

<details>
<summary>./chart/templates/deployment.yaml</summary>

```yaml:deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Values.app.name }}
spec:
  replicas: {{ .Values.hpa.minReplicas }}
  selector:
    matchLabels:
      app: {{ .Values.app.name }}
  template:
    metadata:
      labels:
        app: {{ .Values.app.name }}
    spec:
      containers:
      - name: go-api
        image: {{ .Values.app.go.image | quote }} # ここが重要！
        ports:
        - containerPort: {{ .Values.app.go.port }}
        env:
        - name: PYTHON_RPC_ADDR
          value: "localhost:50051"

      - name: python-api
        image: {{ .Values.app.python.image | quote }} # ここが重要！
        ports:
        - containerPort: {{ .Values.app.python.port }}
        resources:
          requests:
            cpu: "1000m"
            memory: "1Gi"

```
</details>


## 6-4. service.yaml
GoとPython、2つのコンテナが動いていますが、外部に公開する窓口（Service）は **Go API側の1つだけ** に絞っています。

**・単一のエントリポイント:** 外部（k6）からは Go のポート 8080 しか見えません。複雑な OCR 推論サーバー（Python）は Pod 内部に隠蔽されており、セキュリティと管理のしやすさを両立しています。

**・LoadBalancer の活用:** GKE の LoadBalancer を利用することで、GCP から外部 IP が払い出されます。これにより、負荷試験ツール（k6）からインターネット越しに高負荷をかけるリアルな検証環境を構築しています



<details>
<summary>./chart/templates/service.yaml</summary>

```yaml:service.yaml
apiVersion: v1
kind: Service
metadata:
  name: ocr-service-svc # 名前を統合
spec:
  type: LoadBalancer # k6からアクセスするためにLoadBalancer
  selector:
    app: ocr-service # Deployment側のラベルと一致させる
  ports:
    - name: http-go
      port: 8080
      targetPort: 8080

```
</details>


# 7.デプロイ手順(k6テスト前の準備)
本システムのコードは [GitHub](https://github.com/wata123-t/go-python-easyocr-gke) に公開しています。以下の手順で、インフラの構築からアプリケーションのデプロイまでを再現可能です。


## 7-1. インフラの構築 (Terraform)
まず、GCP上にGKEクラスタやArtifact Registryを構築します。
セキュリティ保護のため、プロジェクトID等を含む `terraform.tfvars` は GitHub に含めていません。以下の手順に従って、ご自身の環境に合わせたファイルを作成してください

### 1. terraform.tfvars の作成

`terraform`ディレクトリ直下に`terraform.tfvars`という名前でファイルを作成し、以下の内容を記述します。

```hcl
project_id = "あなたのGCPプロジェクトID"
region     = "asia-northeast1"
dataset_id = "log_dataset" # 任意の名前に変更可能
```
### 2. インフラのデプロイ
準備ができたら、以下のコマンドでリソースを作成します。

```bash
cd terraform

# 初期化
terraform init

# 実行（内容を確認して 'yes' を入力）
terraform apply
```


## 7-2. イメージのビルド・リネーム・プッシュ
GoとPythonの各イメージをビルドし、Artifact Registryへプッシュします。
以下のコマンドの `<PROJECT_ID>` 部分は、ご自身のGCPプロジェクトIDに置き換えて実行してください。

```bash
# go-api, python-api のイメージをbuild
docker-compose build

# Go-API にタグを付ける
docker tag go-python-easyocr-gke-go-api asia-northeast1-docker.pkg.dev/<PROJECT_ID>/ocr-images/go-api:latest

# Python-API にタグを付ける
docker tag go-python-easyocr-gke-python-api asia-northeast1-docker.pkg.dev/<PROJECT_ID>/ocr-images/python-api:latest

# GCP へのプッシュ（アップロード）
docker push asia-northeast1-docker.pkg.dev/<PROJECT_ID>/ocr-images/go-api:latest
docker push asia-northeast1-docker.pkg.dev/<PROJECT_ID>/ocr-images/python-api:latest
```


## 7-3. アプリケーションのデプロイ (Helm)
Helmを使用して、K8sリソース（Deployment, Service, HPAなど）を一括デプロイします。以下のコマンドの `<PROJECT_ID>` 部分は、ご自身のプロジェクトIDに書き換えてください。

```bash
# 接続先クラスタを切り替え
gcloud container clusters get-credentials ocr-cluster --zone asia-northeast1-a --project <PROJECT_ID>

# Helmチャートをインストール（リリース名を ocr-system として実行）
helm install ocr-system ./chart

# Podの起動確認（Running になるまで待ちます）
kubectl get pods

# Serviceの確認（外部IPが割り当てられているか確認）
kubectl get svc

# （参考）アプリケーションを削除する場合
# helm uninstall ocr-system
```

## 7-4. k6 テスト前の準備
テストを実行する前に、接続先のIPアドレスの設定と、テスト用データの生成が必要です。

### 1.接続先IPアドレスの設定
GKE上のServiceに割り当てられた外部IPアドレスを、k6のスクリプトに反映させます。

以下のコマンドで `go-api-service` の **EXTERNAL-IP** を確認します。
```bash
kubectl get svc
```
`./k6/script.js` の 24行目にあるIPアドレスを、確認したIPアドレスに書き換えます。

```js
// 修正前: const url = 'http://35.221.115.130:8080/predict';
const url = 'http://<あなたのEXTERNAL-IP>:8080/predict';
```

### 2. テスト用画像の生成
負荷試験に使用する画像（100枚）はリポジトリに含まれていないため、スクリプトで生成します。
ディレクトリ`./k6`に移動してから以下の作業を実施して下さい。

画像生成に必要なライブラリをインストールします。
```bash
pip install Pillow
```
生成スクリプトを実行します

```bash
python ./gen_image.py
```

実行後、`./test_images`ディレクトリに100枚の画像と、正解ラベルとなる`mapping.json`が作成されれば準備完了です。



# 8.おわりに
本記事では、GoとPython、そしてGKEを組み合わせた **「スケーラブルなOCR基盤」** の詳細な設定やコマンドについて解説しました。
本内容は、全体像を解説しているメイン記事の補足として、構築手順やコードの意図を詳しく掘り下げたものです。ここまでの内容を元に、ぜひ以下の実践編・検証編の記事もあわせてご参照ください。


**・[スケーラブルなOCR基盤(Go×Python×EasyOCR×GKE)の構築](https://github.com/wata123-t/go-python-easyocr-gke)**
→構築に関する重要なポイントをピックアップして説明しています。

**・[スケーラブルなOCR基盤(Go×Python×EasyOCR×GKE)の検証](https://github.com/wata123-t/go-python-easyocr-gke)**
→k6を用いた負荷試験の結果と、オートスケーリングの挙動について検証しています。

これらの記事を組み合わせることで、より深く「スケーラブルなシステム」の実装について理解を深めていただけるはずです。
