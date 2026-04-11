FROM python:3.11-slim

# 1. 必要なツールのインストール
RUN apt-get update && apt-get install -y \
    iverilog make gcc g++ \
    git \
    && rm -rf /var/lib/apt/lists/*

# 2. 作業ディレクトリの設定
WORKDIR /app

# 3. ライブラリのインストール (キャッシュ効率のため先に実行)
# python ディレクトリ内にある requirements.txt をコピー
COPY python/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# 4. プロジェクト全ファイルのコピー
# これにより verilog/, python/, Makefile などが /app 内に配置されます
COPY . .

# 5. 実行
CMD ["make"]
