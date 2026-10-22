#!/usr/bin/env bash
# kit のテストを実行する。引数でファイルを指定しなければ test_*.sh をすべて実行する。
# 各テストは /bin/bash（3.2）で実行して、古い bash でも動くことを確かめる。
set -u
cd "$(dirname "$0")"
files="${*:-$(ls test_*.sh)}"
fails=0
for t in $files; do
  echo "== $t"
  /bin/bash "$t" || fails=$((fails + 1))
done
if [ "$fails" -eq 0 ]; then echo "ALL PASSED"; else echo "${fails} 個のテストファイルが失敗しました"; exit 1; fi
