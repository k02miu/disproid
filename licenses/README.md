# ライセンス原文の出典

- `LGPL-2.1.txt`: vendored libplist の `libcnary/COPYING` を無変更でコピー。
  https://github.com/libimobiledevice/libplist/blob/master/COPYING.LESSER と同じ LGPL 2.1 原文です。
- `Apache-2.0.txt`: 実際にビルドする OpenSSL `openssl-3.3.2` の `LICENSE.txt` を無変更でコピー。
  https://github.com/openssl/openssl/blob/openssl-3.3.2/LICENSE.txt

GPLv3 はルート `LICENSE`、llhttp / playfair の原文と残りの著作権・許諾文は vendor ソースに保持しています。
`scripts/distribution.py` が配布物用にこれらを収集します。
