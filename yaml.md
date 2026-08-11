
```text
keda-settings.yaml
```

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: keda-test-apps
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: go-app-sa
  namespace: keda-test-apps
  annotations:
    # 🌟バックスラッシュを削除して正しいキー名に修正しました
    eks.amazonaws.com/role-arn: "arn:aws:iam::778056636793:role/keda-test-app-execution-role"
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: python-app-sa
  namespace: keda-test-apps
  annotations:
    # 🌟こちらも同様に修正しました
    eks.amazonaws.com/role-arn: "arn:aws:iam::778056636793:role/keda-test-app-execution-role"
---
# ==========================================
# Goアプリ（フロントエンド）のデプロイ定義
# ==========================================
apiVersion: apps/v1
kind: Deployment
metadata:
  name: go-app
  namespace: keda-test-apps
  labels:
    app: go-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: go-app
  template:
    metadata:
      labels:
        app: go-app
    spec:
      serviceAccountName: go-app-sa
      containers:
      - name: go-app
        image: 778056636793.dkr.ecr.ap-northeast-1.amazonaws.com/keda-test-go-app:latest
        env:
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name # 👈 EKSが自動的に実際のPod名（例: go-app-7f85fd-abcde）を注入します
        - name: AWS_SQS_QUEUE_URL
          value: "https://sqs.ap-northeast-1.amazonaws.com/778056636793/keda-test-image-queue"
        - name: AWS_S3_BUCKET
          value: "keda-test-raw-images-2026-yourname" # 👈 実際のご自身のバケット名に
        ports:
        - containerPort: 8080
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
          limits:
            cpu: "200m"
            memory: "256Mi"
---

```

```text
keda-python-apps.yaml
```

```yaml
# ==========================================
# Pythonアプリ（ワーカー）のデプロイ定義
# ==========================================
apiVersion: apps/v1
kind: Deployment
metadata:
  name: python-app
  namespace: keda-test-apps
  labels:
    app: python-app
spec:
  # 🌟KEDAに管理を任せるため、初期状態は「1」でOKです（KEDAが自動で0台や複数台に増減させます）
  replicas: 1
  selector:
    matchLabels:
      app: python-app
  template:
    metadata:
      labels:
        app: python-app
    spec:
      serviceAccountName: python-app-sa # 🌟これでPythonアプリにSQS受信権限とS3操作権限が宿ります
      containers:
      - name: python-app
        image: 778056636793.dkr.ecr.ap-northeast-1.amazonaws.com/keda-test-python-app:latest
        env:
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name # 👈 各Podごとに一意のPod名（例: python-app-56cbd-xyz12）が格納されます
        # ⬇️ ここからを追加することで、CPU環境でのPyTorchが劇的に高速化します
#        - name: OMP_NUM_THREADS
#          value: "1"
#        - name: MKL_NUM_THREADS
#          value: "1"
        - name: AWS_SQS_QUEUE_URL
          value: "https://sqs.ap-northeast-1.amazonaws.com/778056636793/keda-test-image-queue"
        - name: AWS_S3_IMAGE_BUCKET # 👈 元の RAW_BUCKET_NAME から、コード側の名前に修正
          value: "keda-test-raw-images-2026-yourname"
        - name: AWS_S3_METADATA_BUCKET # 👈 元の METADATA_BUCKET_NAME から、コード側の名前に修正
          value: "keda-test-metadata-2026-yourname"
        resources:
          requests:
            cpu: "500m"
            memory: "1Gi"
          limits:
#            cpu: "1500m"
            cpu: "1000m"
            memory: "2Gi"
---
# ==========================================
# Pythonアプリ専用：SQSのキュー数と連動させる自動増減ルール
# ==========================================
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: python-app-sqs-autoscaler
  namespace: keda-test-apps
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: python-app # 🌟増減の対象をPythonアプリに指定
  
  # 🌟最小台数を「0」に設定することで、SQSにメッセージが無いときは完全に消滅（節約）させます
  minReplicaCount: 1
  maxReplicaCount: 5
  
  # 🌟メッセージが処理されてキューが空になった後、0台に減らすまでの猶予時間（秒）
  cooldownPeriod: 10
  
  triggers:
    - type: aws-sqs-queue
      metadata:
        queueURL: "https://sqs.ap-northeast-1.amazonaws.com/778056636793/keda-test-image-queue"
        queueLength: "5" # SQSにメッセージが5件溜まるごとにPythonを1台起動・増やす
        awsRegion: "ap-northeast-1"
      authenticationRef:
        # 先ほど作成した共通の認証パーツ（TriggerAuthentication）を使い回します
        name: keda-aws-sqs-auth
---
# ==========================================
# KEDAにIRSAの権限（WebIdentity）を使うよう指示する認証パーツ
# ==========================================
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata:
  name: keda-aws-sqs-auth
  namespace: keda-test-apps # 👈 ScaledObjectと同じネームスペースに配置
spec:
  podIdentity:
    provider: aws
    identityOwner: workload 
---

```

```text
keda-frontend-lb.yaml
```

```yaml
# ==========================================
# Goアプリ（フロントエンド）用の内部通信用サービス定義
# ==========================================
apiVersion: v1
kind: Service
metadata:
  name: go-app-service
  namespace: keda-test-apps # 🌟現在のNamespaceと合わせています
spec:
  type: ClusterIP # ロードバランサー（ALB）が前に立つため、内部IPで問題ありません
  ports:
    - port: 8080      # ALB側からアクセスを受けるポート
      targetPort: 8080 # GoアプリコンテナのcontainerPort（8080）へ転送
      protocol: TCP
  selector:
    app: go-app # 🌟keda-settings.yamlにあるGoアプリのlabels.app（go-app）に紐付け
---
# ==========================================
# インターネット公開用のロードバランサー（ALB）定義
# ==========================================
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: keda-frontend-alb
  namespace: keda-test-apps
  annotations:
    # 🌟AWS Load Balancer ControllerにALBを自動生成させるための設定
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing # インターネット経由のアクセスを許可
    alb.ingress.kubernetes.io/target-type: ip        # EKSのPodへ直接トラフィックを流す（推奨）
spec:
  ingressClassName: alb # 🌟【最重要：ここにこの1行を追記してください】
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: go-app-service # 🌟上で定義したService名に転送
                port:
                  number: 8080

```


