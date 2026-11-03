# xcodebuild に App Store Connect の API キーを渡す。
# build.sh / archive.sh / ship.sh が頭で読み込む（単体では走らせない）。
#
# **-allowProvisioningUpdates を直に書かず "${PROVISIONING[@]}" を渡す。**
# 素のままだと Xcode は Accounts（ログインキーチェーンの Apple ID）で署名の準備をする。
# 画面がロックされているとそこが読めず "No Accounts" で落ちる。
# 鍵を渡すと Accounts を見ずに、その鍵で開発者サイトに入る。
#
# 鍵は ~/.appstoreconnect/private_keys/ にだけ置く（Mac の手元と、GitHub Actions の
# release ジョブが回の間だけ置く）。**リポジトリに写さない。**
# 無ければ何も足さず、今まで通り Accounts を使う。
# KEY_ID と ISSUER は Tools/asc.py と同じもの（鍵ではない）。環境変数 ASC_KEY_ID・
# ASC_ISSUER_ID があればそちらを使う（release.yml が Environment の secret から渡す）。
#
# 配列を空にしないのは、Mac の /bin/bash が 3.2 で、set -u の下では
# 空の "${a[@]}" が unbound variable で落ちるから。
KEY_ID="${ASC_KEY_ID:-JYMYS92KUB}"
ISSUER="${ASC_ISSUER_ID:-175cb308-6a31-42f0-970a-e72757f60bde}"
KEY="$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8"
PROVISIONING=(-allowProvisioningUpdates)
if [ -f "$KEY" ]; then
  PROVISIONING+=(-authenticationKeyPath "$KEY"
                 -authenticationKeyID "$KEY_ID"
                 -authenticationKeyIssuerID "$ISSUER")
fi
