# 1.はじめに

[前編]では、GoとPythonをgRPCで繋いだGKE上のサイドカー構成OCR基盤を構築しました。
後編となる本記事では、負荷試験ツール k6 を用い、実運用を見据えた「性能」と「精度」の徹底検証を行います。
単なる負荷耐性の確認に留まらず、「インフラの拡張性が、推論品質と処理速度にどう直結するか」を以下の4つの視点で可視化します。
**・スケーラビリティ:** Pod増減に伴うTPSの変化とCluster Autoscalerの挙動推
**・論精度の評価:** テスト画像100枚を用いた、高負荷環境下でのOCR正解率の推移
**・ボトルネック解析:** BigQueryへ集約した構造化ログによる、Go/Python各層の分析
**・分散トレーシング:** Correlation IDを活用した、リクエストから推論完了までの追跡
「設計した理論が、実データでどう証明されるか」―― その検証記録を公開します。



| ◆構成 |
|:---------------|
|[1.はじめに](#1はじめに) |
|[2.技術スタックとシステム構成](#2技術スタックとシステム構成)|
|[3.「GitHub ActionsによるCIの自動化」の環境構築](#3github-actionsによるciの自動化の環境構築)|
|[4.「GitHub Actions」の実行方法](#4github-actionsの実行方法)|
|[5.実行結果](#5実行結果)|
|[6.まとめ](#6まとめ)|




# 2.技術スタックとシステム構成
本検証で使用した基盤の全体像です。

## 2-1. 技術スタック

検証の肝となる「負荷計測」と「ログ分析」のツールを中心に構成しています。


| カテゴリ | 技術・ツール | 用途 |
| :--- | :--- | :--- |
| **負荷試験** | **k6** |本物の画像データを用いたシナリオベースの負荷注入|
| **Frontend API** | **Go (Gin)** |OCR結果と正解データの合否判定、構造化ログ出力|
| **Inference Engine** | **Python (EasyOCR)** |CPU集約型処理（OCR推論）の実行|
| **Infrastructure** | **GKE/HPA** |CPU負荷に応じたPod/ノードの動的スケーリング|
| **Analytics** | **BigQuery** |蓄積された全ログに対するSQLを用いた性能・精度分析|



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
このデータセットは、GitHubレポジトリ登録しています。

https://github.com/wata123-t/AES-128_GitHub_Actions

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
    User([k6 / Test Images]) -->|HTTP| Go[Go API]
    Go -->|gRPC / Client-side LB| Py[Python OCR]
    Go & Py -->|Structured Log| CL[Cloud Logging]
    CL -->|Log Sink| BQ[(BigQuery)]
    
    subgraph GKE_Autoscale
        Go
        Py
    end

```
### <ins>_◆関係記事_</ins>

本記事は、これまでの内容を自動化させるものとなります。

**・1.[【ハード・ソフト協調検証①】Verilog HDLによる暗号化回路(AES-128)の設計](https://qiita.com/watapy/items/cc216b77695b3435f2f5)**
図の Verilog RTL の中身、ハードウェア設計の詳細について解説しています。

これまでの内容を GitHub Actions と Terraform を使用して「プッシュ即検証・分析」が走るパイプラインの構築をしており、今回の記事で説明しています。


# 3.検証環境と計測手法
本システムの実効性を証明するため、負荷試験ツール k6 を活用し、「パフォーマンス」と「推論精度」の両面から検証を行いました

## 3-1. テスト内容と手順
スループットの限界とスケーラビリティを測定するため、同時接続数（VUs）を段階的に引き上げて計測を行っています。

**・手順1:** ベース機能を測定 vus: 1（基準値）
**・手順2:** 限界点を見つける vus: ２～10（細かく観測）
**・手順3:** スケーラブル実行 vsu: 

**・シナリオ:**
以下のパターンを使用して実行する
100枚のテスト画像をループで送信し、各フェーズ10分間の安定負荷を注入。


<details>
<summary>k6 で実行する`JavaScript`(./k6/script.js)</summary>

```js
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
  const url = 'http://35.221.115.130:8080/predict';
  
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

```
</details>

## 3-2. 精度検証の自動化（期待値の突き合わせ）
単なる疎通確認ではなく、**「推論結果が正しいか」をリアルタイムに評価** する仕組みを構築しました。

**・正解データの準備:** 100枚の画像と対応する正解テキストを `mapping.json` で定義。
<details>

<summary>画像を作成したpythonスクリプト(./k6/gen_image.py)</summary>

```python
import os
import json
from PIL import Image, ImageDraw, ImageFont

# フォルダ作成
os.makedirs("./test_images", exist_ok=True)

# 100個の重複のない厳選英単語（3〜6文字）
words = [
    "apple", "bird", "cat", "dog", "fish", "frog", "jump", "blue", 
    "green", "book", "desk", "milk", "moon", "star", "tree", "rose", 
    "lion", "bear", "duck", "king", "queen", "lamp", "fire", "ice", 
    "snow", "rain", "wind", "ship", "boat", "car", "bus", "train",
    "gold", "iron", "wood", "road", "path", "city", "town", "home",
    "door", "wall", "room", "roof", "desk", "pen", "cup", "bowl",
    "rice", "corn", "bean", "soup", "meat", "pork", "beef", "salt",
    "leaf", "root", "stem", "seed", "lily", "pink", "red", "dark",
    "sky", "star", "sun", "cloud", "gray", "gold", "bear", "wolf",
    "deer", "fox", "owl", "hawk", "swan", "lake", "river", "sea",
    "sand", "rock", "clay", "dirt", "hill", "farm", "park", "yard",
    "shoe", "hat", "coat", "bag", "ball", "silver", "bell", "coin",
    "hand", "foot", "eye", "ear", "nose", "face", "hair", "skin"
]

# 単語数が足りない場合の保険（ユニークな100個を確実に取得）
words = list(set(words))[:100]

mapping = {}

# Windows標準のArialフォント（特大サイズ40）
try:
    font = ImageFont.truetype("arial.ttf", 40)
except IOError:
    font = ImageFont.load_default()

# 100枚生成
for i, target_text in enumerate(words, start=1):
    filename = f"{i:03d}.png"
    mapping[filename] = target_text
    
    # 黒背景の画像を作成 (横250px, 縦100px)
    img = Image.new('RGB', (250, 100), color='black')
    draw = ImageDraw.Draw(img)
    
    # 白文字でハッキリと描画
    draw.text((30, 25), target_text, fill='white', font=font)
    
    img.save(f"./test_images/{filename}")

# 正解リストをJSONで保存
with open('./test_images/mapping.json', 'w') as f:
    json.dump(mapping, f)

print(f"100枚の重複のない画像生成が完了しました。 (単語数: {len(words)})")

```
</details>



**・期待値の伝播:** k6からリクエストを送る際、カスタムヘッダー `X-Expected-Text` にその画像の正解文字列をセット。これにより、リクエスト単位での合否判定を可能にしています。
**・判定ロジック:** Go API側で以下の処理を行い、結果を **構造化ログ** として出力します。

|Step|処理|
| :--- | :--- | 
|1| Python（EasyOCR）から返ってきた推論結果を受け取る |
|2| リクエストヘッダーに含まれる「正解文字列」と比較 |
|3| 判定（IsMatch）、処理時間、Correlation IDと共にログ出力 |



## 3-3. 計測指標 (Metrics) と分析基盤
収集した構造化ログを BigQuery へ集約し、以下の多角的な指標でシステムを評価します。

### k6によるフロントエンド指標
k6の `check` 機能を使い、クライアントサイドから見た健全性を測定します。
|項目|内容|
| :--- | :--- | 
|Status is 200|通信が正常終了したか（HTTP 200）|
|Has Result Field|レスポンスのJSON構造が正しいか|
|OCR Content Match|OCR結果が正解データと一致しているか（精度）|

  

### BigQueryによるバックエンド分析
Cloud Logging経由で集約されたデータをSQLで解析し、ボトルのネックを特定します。

|No.|処理|
| :--- | :--- | 
|Latency (ms)|Go API受付からレスポンスまでの全工程時間|
|Accuracy (IsMatch)|OCR正解率の推移|
|Resource Efficiency|1コア制限下での Python Pod の CPU 使用効率|
|Traffic Distribution|Pod名ごとの処理数による、GKE負荷分散の偏り確認|



# 4.検証結果1：基本性能（1 Pod / VU=1）
まずは、インフラへの負荷が最小の状態（同時接続数1）で、1 Podあたりの「理論上の最大性能」を測定しました。これが本システムのパフォーマンスの基準値（ベースライン）となります。


## 4-1.実行内容
1 Pod に対して、k6 を使用して、以下のテストを実施

**・コマンド:** k6 run --vus 1 --duration 10m script.js

|項目|内容|
| :--- | :--- | 
|POD数|1個|
|負荷|1vus|
|時間|10分|
|送付画像|100枚のテスト画像をループで送信|

## 4-2.実行結果(フロントエンド)
このテストを実行した際の k6 の最終結果と、「kubectl」コマンドのログは、以下の通り
kubectl get hpa ocr-service-hpa -w


### k6 での実行結果

![image.png](https://qiita-image-store.s3.ap-northeast-1.amazonaws.com/0/4239579/b6b994d1-f903-4e23-8d57-ca31c4d244d1.png)

|指標|測定値|備考|
| :--- | :--- | :--- | 
|スループット|0.80|req/s1並列時の安定した処理能力|
|平均応答時間(avg)|497.06ms|Go-Python間通信を含めた推論時間|
|95% 応答時間(p95)|571.99ms|遅延の跳ね上がりも極めて少ない|
|成功率(Checks)|100%|全241リクエストで精度・形式ともに正常|

### **・結果の考察**
**・安定した低レイテンシ:** 平均約0.5秒という結果から、サイドカー構成（gRPC）による通信オーバーヘッドが最小限に抑えられ、EasyOCRの推論時間が支配的であることが分かります。
**・高い信頼性:** checks_failed が 0% であり、単一リクエストにおいては期待通りの精度（OCR Content Match）が発揮されています。



## 4-2.サーバー内部のレイテンシ分解（BigQuery分析）
BigQueryに蓄積された構造化ログを分析し、GoレイヤーとPythonレイヤーそれぞれの処理時間を可視化しました。

### **平均CPU使用率=13%～17%**

|指標(ミリ秒)|Python推論|Go全体|通信・その他オーバーヘッド|
| :--- | :--- | :--- | :--- | 
|平均 (avg)|357.82 ms|407.47 ms|49.65 ms|
|最小 (min)|329.00 ms|341.00 ms|12.00 msv|
|最大 (max)|524.00 ms|592.00 ms|68.00 ms|


### 分析から得られた知見

**1.推論処理が支配的:** 
全行程（約407ms）のうち、PythonによるOCR推論が約358msを占めており、全体の約88%が推論処理であることが分かります。
**2.極めて低いサイドカー間通信コスト:**
GoとPythonの差分（約50ms）には、gRPCの通信オーバーヘッド、Go側での画像デコード、およびロギング処理が含まれます。サイドカー構成（localhost通信）により、ネットワーク遅延を最小限に抑えられていることが実証されました。
**3.k6との乖離（ネットワークコスト）:**
k6側の平均（約497ms）とGo全体の平均（約407ms）の差分、約90msがクライアント〜GCP Ingress〜Pod間の往復ネットワーク遅延であると推測できます。


<details>

<summary>使用したSQL</summary>

```sql
WITH request_metrics AS (
  -- まずリクエストごとにGoとPythonの時間を紐付け
  SELECT
    jsonPayload.request_id,
    MAX(IF(jsonPayload.step = 'python-ocr-inference', jsonPayload.duration_ms, 0)) AS python_ms,
    MAX(IF(jsonPayload.step = 'go-api-complete', jsonPayload.duration_ms, 0)) AS go_total_ms
  FROM
    `[プロジェクトID].[テーブル名].stdout_*`
  WHERE
    jsonPayload.request_id IS NOT NULL
  GROUP BY
    1
  HAVING
    python_ms > 0 AND go_total_ms > 0
)
SELECT
  -- Python（OCR処理）の統計
  AVG(python_ms) AS avg_python_ms,
  MIN(python_ms) AS min_python_ms,
  MAX(python_ms) AS max_python_ms,

  -- Go全体（クライアント体感）の統計
  AVG(go_total_ms) AS avg_go_total_ms,
  MIN(go_total_ms) AS min_go_total_ms,
  MAX(go_total_ms) AS max_go_total_ms,

  -- サンプル数（リクエスト総数）
  COUNT(*) AS total_requests
FROM
  request_metrics


```
</details>



# 5.検証結果2：並列処理とスケーラビリティ（Pod=3 / VU=10）

1 Podあたりの限界性能（1.2 TPS）に対し、Pod数を3台に増やし、同時接続数（VU）を10まで引き上げた際の挙動を検証しました。

**・期待値:** 理論上は 1.2 TPS × 3台 ＝ 3.6 TPS 程度までスループットが向上すること。
**・実測値:** 実行結果、システム全体の合計スループットが 3.4 TPS まで向上。

**高いスケーラビリティ:** 理論値に近い性能向上が確認できました。これは、各Podがサイドカー構成によって「自己完結」して推論を行っているため、Podを並べるだけでリニアに性能が伸びることを示しています。

**負荷分散の均一性:** BigQueryで pod_name ごとの処理数を集計したところ、3台のPodにほぼ均等（約33%ずつ）にリクエストが分散されており、GKEのService（LoadBalancer）が正しく機能していることが裏付けられました。


「スケーラビリティ＝並列化の効率」として説明することで、「単にPodを増やした」という結果報告ではなく、「並列化に適したアーキテクチャ（サイドカー＋gRPC）を設計し、それを実証した」というストーリーになります




## 5-1.実行方法
./chart/values.yaml の min 値を変更して測定を行いました。
測定したコマンドは、以下を使用しています。

これを使用して、1,3,5 の並列数で実施しました。

## 5-3.k6 実行結果
3回の結果は以下の通り
図の掲載

表での結果まとめ

1の場合はあくまで比較用に実行しただけで、性能的に無理があるので、詳細原因は追いません

## 5-3.コマンドによる負荷の遷移
kubectl get hpa ocr-service-hpa -w


## 5-4.BigQuery 格納ログの詳細1
「検証結果1：オートスケーリングの挙動」を参照
SQLで出力した内容を表で出力

## 5-5.BigQuery 格納ログの詳細
各処理時間を表で比較

## 5-5.考察
並列数を増やすことで、使用POD数が増え処理能力が向上。
それにより各処理への負荷が分散し、OCRの本来の機能が発揮されている。




# 7.設計を通して



## 7-1.xxxx


## 7-3.設定のポイント

## 7-4.実現でできなかった構成




# 8.文字による影響
現在は、かなり読みやすい形の文字画像としています。


## 8-1.読みずらい文字タイプの結果


## 8-2.読みずらい文字列(toy)




# 9.POD構成の検討と今後の課題
今回の検証では、サイドカー構成かつ静的なPod数指定を採用しました。その背景にある、アーキテクチャ選定の試行錯誤と課題をまとめます。

## 9-1.サイドカー構成の選択理由
当初は、リソース効率の観点からGo（API）とPython（推論）を個別のサービスとしてデプロイする **独立サービス（Microservices）構成** も検討しました。
しかし、GoからPythonへのgRPC接続において、コネクションの維持と再接続のハンドリングに課題が残りました。具体的には、稀に発生する大幅な遅延（テールレイテンシ）の原因が、ネットワーク経路なのかgRPCの再送制御なのかを切り分けきれず、今回は「最も通信が安定し、管理が容易な」同一Pod内のサイドカー構成を選択しました。


## 9-2.負荷に応じたスケーリングの壁（L4負荷分散の課題）
検証過程では、サイドカー構成のままHPAによるオートスケーリングにも挑戦しました。
しかし、ここでもgRPC特有の **「接続の持続性」** が壁となりました。
**・発生した現象:**
負荷に応じてPodは正常に増殖（Scale-out）するものの、既存のGo-APIが最初に確立したPythonとのコネクションを保持し続けてしまい、後から起動したPodへリクエストが分散されない。
**・技術的背景:**
gRPCはHTTP/2をベースにしており、効率化のためにコネクションを長時間維持します。一般的なL4ロードバランサーでは、一度繋がった「土管」を切り替えることが難しいため、特定のPodに負荷が偏る現象が発生しました。この解決には、サービスメッシュ（Istio等）の導入や、クライアントサイド・ロードバランシングの実装、あるいはGoとPythonを完全に疎結合にするメッセージキュー（Pub/Sub）の導入が必要であるとの結論に至りました。






# 10.考察とまとめ
本検証を通じて、GKE上に構築した自動スケール型OCR基盤が、設計通りに高負荷を捌き、かつ高いデータ品質を維持できることを実証しました。

## 10-1.検証から得られた考察
今回の「構築」と「検証」のサイクルから、以下の3つの重要な知見が得られました。

**・インフラの弾力性とコストのバランス**
Spot VMとCluster Autoscaler、そしてHPAを組み合わせることで、「普段は最小構成でコストを抑え、ピーク時のみリソースを自動拡張する」というクラウドネイティブな最適解を実現できました。

**・gRPC通信の安定性**
Headless Serviceを用いたクライアントサイド負荷分散により、特定のPodへの負荷集中を回避できました。これにより、OCRのような重量級の処理でも、スケールアウトによるスループット向上が線形に近い形で得られることが確認できました。

**・「分析可能なログ」がシステムを強くする**
単にログを吐くだけでなく、BigQueryで集計可能な「構造化ログ」として設計したことが、精度のモニタリングやトラブルシューティングの迅速化に直結しました。

## 10-2.今後の展望
今回の基盤をさらに発展させるためのネクストステップとして、以下の改善が考えられます。
**・モデルのGPU活用:** 推論時間をさらに短縮するため、GKEのGPUノードへの切り替え。
**・DLQ（Dead Letter Queue）の導入:** 推論に失敗した画像を自動で別ストレージに隔離し、再学習や詳細解析に回すパイプラインの構築。
**・CI/CDへの負荷試験組み込み:** GitHub Actionsとk6を連携させ、コード変更時に性能劣化（パフォーマンスリグレッション）が発生しないか自動チェックする仕組み。


## 10-3.最後に

本プロジェクトでは、データエンジニアとして「データを扱うための基盤」をいかに堅牢に、かつ観測可能（Observable）な状態で構築・運用するかをテーマに取り組みました。

インフラ、アプリケーション、そしてデータの分析。これらを一気通貫で設計・検証することで、変化に強く、信頼性の高いシステムを提供できると確信しています。

最後までお読みいただき、ありがとうございました。


