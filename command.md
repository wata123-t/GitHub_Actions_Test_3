```text
/////////////////////////////////////////////////////////////////
// outpout.tf
/////////////////////////////////////////////////////////////////
```

```hcl
output "sqs_url" {
  value       = aws_sqs_queue.image_queue.id
  description = "後続処理で利用するAWS SQSキューのURL"
}

output "ecr_go_app_url" {
  value       = aws_ecr_repository.go_app.repository_url
  description = "Goフロントエンド用ECRリポジトリURL"
}

output "app_execution_role_arn" {
  value       = aws_iam_role.app_role.arn
  description = "Go/PythonアプリのServiceAccountに割り当てるIAMロールARN"
}

output "keda_operator_role_arn" {
  value       = aws_iam_role.keda_operator.arn
  description = "KEDAオペレーターに割り当てるIAMロールARN"
}

output "eks_vpc_id" {
  value       = aws_vpc.eks_vpc.id
  description = "EKSクラスターを配置したVPCのID"
}

output "aws_load_balancer_controller_role_arn" {
  value       = aws_iam_role.lb_controller.arn
  description = "AWS Load Balancer Controllerに割り当てるIAMロールARN"
}
```

```text
/////////////////////////////////////////////////////////////////
// providers.tf
/////////////////////////////////////////////////////////////////
```

```hcl
provider "aws" {
  region = "ap-northeast-1" # 東京リージョン
}
```

```text
/////////////////////////////////////////////////////////////////
// main.tf
/////////////////////////////////////////////////////////////////
```

```hcl
# ----------------------------------------------------
# データの保管と通信（S3バケット / SQSキュー）
# ----------------------------------------------------
resource "aws_s3_bucket" "raw_images" {
  bucket        = "keda-test-raw-images-2026-yourname"
  force_destroy = true
}

resource "aws_s3_bucket" "metadata" {
  bucket        = "keda-test-metadata-2026-yourname"
  force_destroy = true
}

resource "aws_sqs_queue" "image_queue" {
  name                      = "keda-test-image-queue"
  delay_seconds             = 0
  max_message_size          = 262144
  message_retention_seconds = 86400
  receive_wait_time_seconds = 10
}

# ----------------------------------------------------
# コンテナイメージの保管場所（ECR）
# ----------------------------------------------------
resource "aws_ecr_repository" "go_app" {
  name                 = "keda-test-go-app"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
  image_scanning_configuration { scan_on_push = true }
}

resource "aws_ecr_repository" "python_app" {
  name                 = "keda-test-python-app"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
  image_scanning_configuration { scan_on_push = true }
}

# ----------------------------------------------------
# EKS用のネットワーク基盤（VPC / Subnet）
# ----------------------------------------------------
resource "aws_vpc" "eks_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "keda-test-eks-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.eks_vpc.id
  tags   = { Name = "keda-test-igw" }
}

resource "aws_subnet" "public_1" {
  vpc_id                  = aws_vpc.eks_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-northeast-1a"
  map_public_ip_on_launch = true
  tags = {
    Name                                      = "keda-test-public-1",
    "kubernetes.io/role/elb"                  = "1",
    "kubernetes.io/cluster/keda-test-cluster" = "shared"
  }
}

resource "aws_subnet" "public_2" {
  vpc_id                  = aws_vpc.eks_vpc.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "ap-northeast-1c"
  map_public_ip_on_launch = true
  tags = {
    Name                                      = "keda-test-public-2",
    "kubernetes.io/role/elb"                  = "1",
    "kubernetes.io/cluster/keda-test-cluster" = "shared"
  }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.eks_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "keda-test-public-rt" }
}

resource "aws_route_table_association" "public_1" {
  subnet_id      = aws_subnet.public_1.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "public_2" {
  subnet_id      = aws_subnet.public_2.id
  route_table_id = aws_route_table.public_rt.id
}
```

```text
/////////////////////////////////////////////////////////////////
// iam.tf
/////////////////////////////////////////////////////////////////
```

```hcl
# ----------------------------------------------------
# A. Go/PythonアプリがSQSとS3にアクセスするための設定
# ----------------------------------------------------
resource "aws_iam_policy" "app_sqs_s3" {
  name        = "keda-test-app-policy"
  description = "Policy for Go/Python apps to access SQS and S3"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:SendMessage",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:ChangeMessageVisibility"
        ]
        Resource = aws_sqs_queue.image_queue.arn
      },
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.raw_images.arn,
          "${aws_s3_bucket.raw_images.arn}/*",
          aws_s3_bucket.metadata.arn,
          "${aws_s3_bucket.metadata.arn}/*"
        ]
      }
    ]
  })
}


# ==========================================
#  Go/Pythonアプリ用 IAMロール (app_role)
# ==========================================

# 現在実行中のAWSアカウントIDを動的に取得する
data "aws_caller_identity" "current" {}

resource "aws_iam_role" "app_role" {
  name = "keda-test-app-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # 1. EKS（OIDC）からの認証を許可
        Effect    = "Allow"
        Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(aws_eks_cluster.eks.identity[0].oidc[0].issuer, "https://", "")}:sub" = [
              "system:serviceaccount:keda-test-apps:go-app-sa",
              "system:serviceaccount:keda-test-apps:python-app-sa"
            ]
          }
        }
      },
      {
        # 2. 修正箇所：Principal を root に書き換えます（role/... の記述を完全に消す）
        Effect    = "Allow"
        #Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/keda-test-operator-role" }
        Action    = "sts:AssumeRole"
#        Condition = {
#          ArnEquals = {
#            "aws:PrincipalArn" = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/keda-test-operator-role"
#          }
#        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "app_execution" {
  policy_arn = aws_iam_policy.app_sqs_s3.arn
  role       = aws_iam_role.app_role.name
}

# ==========================================
# B. KEDA(本体)がSQSキューの深さを監視するための設定
# ==========================================
resource "aws_iam_policy" "keda_operator_sqs" {
  name        = "keda-operator-sqs-policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
      Resource = aws_sqs_queue.image_queue.arn
    }]
  })
}

# ==========================================
# 🌟 KEDAオペレーター用 IAMロール (keda_operator)
# ==========================================
resource "aws_iam_role" "keda_operator" {
  name = "keda-test-operator-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # 1. EKS（OIDC）からの認証を許可
        Effect    = "Allow"
        Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(aws_eks_cluster.eks.identity[0].oidc[0].issuer, "https://", "")}:sub" = "system:serviceaccount:keda:keda-operator"
            "${replace(aws_eks_cluster.eks.identity[0].oidc[0].issuer, "https://", "")}:aud" = "sts.amazonaws.com"
          }
        }
      },
      {
        # 2. 修正箇所：Principal を root に書き換えます（role/... の記述を完全に消す）
        Effect    = "Allow"
        #Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/keda-test-app-execution-role" }
        Action    = "sts:AssumeRole"
#        Condition = {
#          ArnEquals = {
#            "aws:PrincipalArn" = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/keda-test-app-execution-role"
#          }
#        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "keda_operator" {
  policy_arn = aws_iam_policy.keda_operator_sqs.arn
  role       = aws_iam_role.keda_operator.name
}


# ----------------------------------------------------
# C. AWS Load Balancer Controller（ALB制御）用の設定
# ----------------------------------------------------
data "http" "lb_controller_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json"
}

resource "aws_iam_policy" "aws_load_balancer_controller" {
  name        = "AWSLoadBalancerControllerIAMPolicy"
  description = "Policy for AWS Load Balancer Controller in EKS"
  policy      = data.http.lb_controller_policy.response_body
}

data "aws_iam_policy_document" "lb_controller_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_eks_cluster.eks.identity[0].oidc[0].issuer, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_eks_cluster.eks.identity[0].oidc[0].issuer, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }

    principals {
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
      type        = "Federated"
    }
  }
}

resource "aws_iam_role" "lb_controller" {
  name               = "keda-test-aws-load-balancer-controller"
  assume_role_policy = data.aws_iam_policy_document.lb_controller_assume_role.json
}

resource "aws_iam_role_policy_attachment" "lb_controller" {
  role       = aws_iam_role.lb_controller.name
  policy_arn = aws_iam_policy.aws_load_balancer_controller.arn
}

/////////////////////////////////////////////////////////////////
// eks.tf
/////////////////////////////////////////////////////////////////
# ----------------------------------------------------
# EKS クラスターコントロールプレーン
# ----------------------------------------------------
resource "aws_iam_role" "eks_cluster_role" {
  name = "keda-test-eks-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster_role.name
}

resource "aws_eks_cluster" "eks" {
  name                      = "keda-test-cluster"
  role_arn                  = aws_iam_role.eks_cluster_role.arn
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  vpc_config {
    endpoint_private_access = true
    endpoint_public_access  = true
    subnet_ids              = [aws_subnet.public_1.id, aws_subnet.public_2.id]
  }
  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]
}

# ----------------------------------------------------
# EKS ワーカーノードグループ（Managed Node Group）
# ----------------------------------------------------
resource "aws_iam_role" "node_role" {
  name = "keda-test-eks-node-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.node_role.name
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.node_role.name
}

resource "aws_iam_role_policy_attachment" "node_AmazonEC2ContainerRegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.node_role.name
}

resource "aws_iam_role_policy_attachment" "node_AmazonAdministratorAccess" {
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
  role       = aws_iam_role.node_role.name
}

resource "aws_eks_node_group" "nodes" {
  cluster_name    = aws_eks_cluster.eks.name
  node_group_name = "keda-test-node-group"
  node_role_arn   = aws_iam_role.node_role.arn
  subnet_ids      = [aws_subnet.public_1.id, aws_subnet.public_2.id]
  instance_types  = ["t3.small"]

  scaling_config {
    desired_size = 5 # EasyOCR（Python）用にリソースを多めに確保
    max_size     = 7 # KEDAのスパイクに備えて最大数を広げる
    min_size     = 1
  }
}

# ----------------------------------------------------
# OIDCプロバイダー (IRSA：ServiceAccount連携用の認証基盤)
# ----------------------------------------------------
data "tls_certificate" "eks" {
  url = aws_eks_cluster.eks.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.eks.identity[0].oidc[0].issuer
}
```

