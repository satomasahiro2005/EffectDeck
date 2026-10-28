#!/bin/bash
# Mac の今の条件を 1 行で出す（電源・省電力モード・CPU の空き）。測定の前後に run.sh が呼ぶ。
# 電池駆動か電源か、省電力モードかで 1 コマの重さが 4 割変わることがあるので、途中で変わっていないかを見張る。
power="$(pmset -g batt | head -1 | sed "s/.*from '//; s/'.*//; s/ Power//")"
lpm="$(pmset -g | awk '/lowpowermode/{print $2}')"
idle="$(top -l 2 -n 0 -s 1 | grep 'CPU usage' | tail -1 | sed 's/.*, //; s/ idle//')"
echo "power=${power// /_} lpm=${lpm:-?} idle=${idle}"
