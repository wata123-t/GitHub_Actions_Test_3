# --- プロジェクト構成の設定 ---
SIM ?= icarus
TOPLEVEL_LANG ?= verilog

# 1. すべての Verilog ソースファイルを指定
# 画像にあるファイルを全てリストアップします
VERILOG_SOURCES += $(PWD)/verilog/aes_128.v \
                   $(PWD)/verilog/key_expansion.v \
                   $(PWD)/verilog/mixcolumns.v \
                   $(PWD)/verilog/sbox.v \
                   $(PWD)/verilog/shiftrows.v \
                   $(PWD)/verilog/aes_round_logic.v

# 2. Python テストコードの場所を指定
# python/ ディレクトリを検索パスに追加
export PYTHONPATH := $(PWD)/python:$(PYTHONPATH)

# 3. 最上位モジュール名（Verilog内の module aes_128 ...）
TOPLEVEL = aes_128

# 4. Python のテストファイル名（python/test_aes.py の場合）
# .py は含めないで記述します
MODULE = test_aes

# cocotb の Makefile テンプレートを読み込み
include $(shell cocotb-config --makefiles)/Makefile.sim
