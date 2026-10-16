#!/usr/bin/env bash
# ==============================================================================
# nat-neighbour (nat.sh) — KVM / LXC NAT VPS 鄰居數量普查與活躍度探測工具
# Version: 1.0.0
# License: MIT
# ==============================================================================

set -u

VERSION="1.0.0"
INSTALL_PATH="/usr/local/bin/nat"
SAMPLE_COUNT=50
QUICK_MODE=0
INCLUDE_ALL=0

# 顏色定義（終端機支援時啟用）
if [ -t 1 ]; then
  C_RESET="\033[0m"
  C_BOLD="\033[1m"
  C_DIM="\033[2m"
  C_RED="\033[31m"
  C_GREEN="\033[32m"
  C_YELLOW="\033[33m"
  C_BLUE="\033[34m"
  C_CYAN="\033[36m"
else
  C_RESET=""
  C_BOLD=""
  C_DIM=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
  C_CYAN=""
fi

show_help() {
  cat <<EOF
${C_BOLD}nat-neighbour v${VERSION}${C_RESET} — KVM / LXC 通用 NAT 鄰居人數普查與活躍度探測工具

用法:
  nat [選項]

選項:
  (無參數)        自動執行【階段一：鄰居人數與真實買家識別】+【階段二：活躍度與線路負載排行】
  -q, --quick     僅執行【階段一：鄰居人數與真實買家識別】（約 2 秒快速完成）
  -c, --count N   指定活躍度採樣 Ping 次數（預設: 50 次，約 5 秒）
  -a, --all       將疑似母雞/老闆手動開的系統節點也納入活躍度排行榜
  --install       手動將本腳本安裝/更新至 ${INSTALL_PATH}
  --uninstall     移除已安裝的 ${INSTALL_PATH} 快捷指令
  -h, --help      顯示本幫助說明
  -v, --version   顯示版本號
EOF
}

install_self() {
  local src="${BASH_SOURCE[0]:-$0}"
  if [ ! -f "$src" ]; then
    return 0
  fi
  local real_src
  real_src=$(readlink -f "$src" 2>/dev/null || echo "$src")
  if [ "$real_src" = "$INSTALL_PATH" ]; then
    return 0
  fi

  if [ "$(id -u)" -eq 0 ] || [ -w "$(dirname "$INSTALL_PATH")" ]; then
    tr -d '\r' < "$src" > "$INSTALL_PATH" 2>/dev/null && chmod +x "$INSTALL_PATH" 2>/dev/null
    if [ -x "$INSTALL_PATH" ]; then
      echo -e "${C_GREEN}✅ 已自動註冊快捷指令：之後在終端機直接輸入 ${C_BOLD}nat${C_RESET}${C_GREEN} 即可隨時執行！${C_RESET}"
    fi
  elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    tr -d '\r' < "$src" | sudo tee "$INSTALL_PATH" >/dev/null 2>&1 && sudo chmod +x "$INSTALL_PATH" 2>/dev/null
    if [ -x "$INSTALL_PATH" ]; then
      echo -e "${C_GREEN}✅ 已自動註冊快捷指令：之後在終端機直接輸入 ${C_BOLD}nat${C_RESET}${C_GREEN} 即可隨時執行！${C_RESET}"
    fi
  fi
}

# 解析命令列參數
while [ $# -gt 0 ]; do
  case "$1" in
    -q|--quick)
      QUICK_MODE=1
      shift
      ;;
    -c|--count)
      if [ $# -lt 2 ] || ! [[ "$2" =~ ^[0-9]+$ ]] || [ "$2" -lt 5 ]; then
        echo -e "${C_RED}錯誤: -c/--count 需要大於等於 5 的整數。${C_RESET}" >&2
        exit 1
      fi
      SAMPLE_COUNT="$2"
      shift 2
      ;;
    -a|--all|--include-all)
      INCLUDE_ALL=1
      shift
      ;;
    --install)
      install_self
      exit 0
      ;;
    --uninstall)
      if [ -f "$INSTALL_PATH" ]; then
        rm -f "$INSTALL_PATH" 2>/dev/null || sudo rm -f "$INSTALL_PATH"
        echo -e "${C_GREEN}✅ 已移除 ${INSTALL_PATH}${C_RESET}"
      else
        echo -e "${C_YELLOW}提示: 系統中未找到 ${INSTALL_PATH}${C_RESET}"
      fi
      exit 0
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    -v|--version)
      echo "nat-neighbour v${VERSION}"
      exit 0
      ;;
    *)
      echo -e "${C_RED}未知選項: $1（使用 nat --help 查看說明）${C_RESET}" >&2
      exit 1
      ;;
  esac
done

# 檢查必要依賴
for cmd in ip ping awk sort; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo -e "${C_RED}錯誤: 系統缺少必要指令 '${cmd}'，請先安裝 iproute2 / iputils-ping。${C_RESET}" >&2
    exit 1
  fi
done

# 若首次透過 bash nat.sh 執行，自動安裝至 /usr/local/bin/nat
install_self

# 偵測虛擬化架構 (KVM / LXC / OpenVZ 等)
detect_virt() {
  local virt="Unknown"
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    virt=$(systemd-detect-virt 2>/dev/null || echo "Unknown")
  fi
  if [ "$virt" = "Unknown" ] || [ -z "$virt" ]; then
    if grep -qa "container=lxc" /proc/1/environ 2>/dev/null; then
      virt="lxc"
    elif [ -d /proc/vz ] && [ ! -d /proc/bc ]; then
      virt="openvz"
    elif [ -f /sys/class/dmi/id/product_name ]; then
      local prod
      prod=$(cat /sys/class/dmi/id/product_name 2>/dev/null)
      case "$prod" in
        *KVM*|*QEMU*|*Standard\ PC*) virt="kvm" ;;
        *VMware*) virt="vmware" ;;
        *Virtual\ Machine*) virt="microsoft" ;;
        *) virt="$prod" ;;
      esac
    fi
  fi
  echo "${virt^^}"
}

VIRT_TYPE=$(detect_virt)

# 偵測預設網卡、內網 IP、網關與 MAC
RAW_IFACE=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')
if [ -z "$RAW_IFACE" ]; then
  RAW_IFACE=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $2; exit}')
fi
IFACE="${RAW_IFACE%%@*}"

if [ -z "$IFACE" ]; then
  echo -e "${C_RED}錯誤: 無法偵測到有效的 IPv4 網路介面。${C_RESET}" >&2
  exit 1
fi

MY_CIDR=$(ip -4 -o addr show dev "$IFACE" scope global 2>/dev/null | awk '{print $4; exit}')
MY_IP="${MY_CIDR%/*}"
PREFIX_LEN="${MY_CIDR#*/}"
NET="${MY_IP%.*}"

GW_IP=$(ip -4 route show default dev "$IFACE" 2>/dev/null | awk '{print $3; exit}')
[ -z "$GW_IP" ] && GW_IP="${NET}.1"

MY_MAC=""
if [ -f "/sys/class/net/${IFACE}/address" ]; then
  MY_MAC=$(tr '[:upper:]' '[:lower:]' < "/sys/class/net/${IFACE}/address" 2>/dev/null)
fi
if [ -z "$MY_MAC" ]; then
  MY_MAC=$(ip link show dev "$IFACE" 2>/dev/null | awk '/link\/ether/ {print tolower($2); exit}')
fi

# 嘗試獲取外部共享公網 IPv4（限時 2 秒，失敗不阻塞）
PUB_IP=""
if command -v curl >/dev/null 2>&1; then
  PUB_IP=$(curl -4 -fsS --max-time 2 https://ip.sb 2>/dev/null || curl -4 -fsS --max-time 2 https://api.ipify.org 2>/dev/null || true)
elif command -v wget >/dev/null 2>&1; then
  PUB_IP=$(wget -4 -qO- --timeout=2 https://ip.sb 2>/dev/null || true)
fi
PUB_IP=$(echo "$PUB_IP" | tr -d '[:space:]')

# 檢查 ping 是否支援小數間隔 (-i 0.1)
PING_INTERVAL="0.1"
if ! ping -c 1 -i 0.1 -W 1 127.0.0.1 >/dev/null 2>&1; then
  if ping -c 1 -i 0.2 -W 1 127.0.0.1 >/dev/null 2>&1; then
    PING_INTERVAL="0.2"
  else
    PING_INTERVAL="1"
    [ "$SAMPLE_COUNT" -gt 10 ] && SAMPLE_COUNT=10
  fi
fi

TMP_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t natscan)
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

echo -e "${C_BOLD}========================================================================${C_RESET}"
echo -e "🛰️  ${C_BOLD}NAT 鄰居普查與活躍度探測工具 v${VERSION}${C_RESET}  (架構: ${C_CYAN}${VIRT_TYPE}${C_RESET} | 介面: ${C_CYAN}${IFACE}${C_RESET})"
echo -e "${C_BOLD}========================================================================${C_RESET}"
echo -e "📍 本機內網 IP : ${C_GREEN}${MY_IP}${C_RESET} (/${PREFIX_LEN})   MAC: ${C_DIM}${MY_MAC:-未知}${C_RESET}"
echo -e "🛣️  內網預設網關: ${C_YELLOW}${GW_IP}${C_RESET}           共享公網 IPv4: ${C_CYAN}${PUB_IP:-未檢出}${C_RESET}"
echo -e "------------------------------------------------------------------------"
echo -e "🔍 ${C_BOLD}[階段一] 正在併發掃描 ${NET}.0/24 二層 ARP 與存活主機（約 2 秒）...${C_RESET}"

# 子程序併發 Ping 觸發同網段 ARP 解析與存活檢測
(
  mkdir -p "${TMP_DIR}/alive"
  if [ -n "$GW_IP" ]; then
    ping -c 1 -W 1 "$GW_IP" >/dev/null 2>&1 &
  fi
  for i in $(seq 1 254); do
    target="${NET}.${i}"
    if [ "$target" = "$MY_IP" ]; then
      continue
    fi
    (
      if ping -c 1 -W 1 "$target" >/dev/null 2>&1; then
        touch "${TMP_DIR}/alive/${target}"
      fi
    ) &
  done
  wait
)

# 讀取 ARP 鄰居表（僅保留成功解析出 lladdr MAC 的條目）
ARP_RAW=$(ip -4 neigh show dev "$IFACE" 2>/dev/null | awk '
  /lladdr/ {
    ip = $1
    mac = ""
    for (i = 1; i <= NF; i++) {
      if ($i == "lladdr" && (i + 1) <= NF) {
        mac = tolower($(i + 1))
      }
    }
    state = $NF
    is_router = ($0 ~ /router/) ? 1 : 0
    if (mac != "" && state != "FAILED" && state != "INCOMPLETE") {
      print ip, mac, state, is_router
    }
  }' | sort -V)

GW_MAC=$(echo "$ARP_RAW" | awk -v gw="$GW_IP" '$1 == gw {print $2; exit}')
GW_OUI="${GW_MAC:0:8}"

# ------------------------------------------------------------------------------
# 真實買家識別邏輯 (Real-User Identification Engine)
# ------------------------------------------------------------------------------
# 判斷 MAC 是否為本地隨機管理位址 (Locally Administered MAC, LAA: 第二碼為 2, 6, a, e)
# 大多數現代面板 (Paymenter / Virtualizor / Convoy) 自動開機時會產生 LAA 隨機 MAC，
# 而管理員在 PVE / KVM 手動建立的軟路由、探針或測試機則會使用虛擬化官方固定 OUI (如 bc:24:11)。
is_laa_mac() {
  local m="$1"
  local sec="${m:1:1}"
  [[ "$sec" =~ ^[26ae]$ ]]
}

is_hypervisor_oui() {
  local oui="${1:0:8}"
  case "$oui" in
    bc:24:11|52:54:00|00:16:3e|00:15:5d|00:50:56|00:0c:29|00:1c:42|08:00:27)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

MY_IS_LAA=0
if [ -n "$MY_MAC" ] && is_laa_mac "$MY_MAC"; then
  MY_IS_LAA=1
fi

# 統計非網關節點中 LAA 隨機 MAC 與標準 OUI 的數量分佈
LAA_COUNT=0
NON_GW_COUNT=0
while read -r ip mac state is_router; do
  [ -z "$ip" ] && continue
  [ "$ip" = "$GW_IP" ] || [ "$ip" = "$MY_IP" ] && continue
  NON_GW_COUNT=$((NON_GW_COUNT + 1))
  if is_laa_mac "$mac"; then
    LAA_COUNT=$((LAA_COUNT + 1))
  fi
done <<< "$ARP_RAW"

# 若本機為 LAA 隨機 MAC，或網段內存在 >=2 台 LAA 面板自動開通實例，則啟用「面板 LAA vs 手動 OUI」識別模式
PANEL_USES_LAA=0
if [ "$MY_IS_LAA" -eq 1 ] || [ "$LAA_COUNT" -ge 2 ]; then
  PANEL_USES_LAA=1
fi

REAL_USERS_FILE="${TMP_DIR}/real_users.txt"
SYSTEM_NODES_FILE="${TMP_DIR}/system_nodes.txt"
: > "$REAL_USERS_FILE"
: > "$SYSTEM_NODES_FILE"

while read -r ip mac state is_router; do
  [ -z "$ip" ] && continue
  [ "$ip" = "$MY_IP" ] && continue

  last_octet="${ip##*.}"
  oui="${mac:0:8}"
  ping_ok=0
  [ -f "${TMP_DIR}/alive/${ip}" ] && ping_ok=1

  reason=""
  # 規則 1: 預設網關或宣告為 Router 的節點
  if [ "$ip" = "$GW_IP" ] || [ "$is_router" -eq 1 ]; then
    reason="網關/路由節點 (Gateway)"
  # 規則 2: 常見保留網關尾號 (.1 / .254)
  elif [ "$last_octet" -eq 1 ] || [ "$last_octet" -eq 254 ]; then
    reason="網段保留網關位 (.${last_octet})"
  # 規則 3: 在面板使用 LAA 隨機 MAC 的環境中，出現宿主機原生固定 OUI (如 PVE bc:24:11)
  elif [ "$PANEL_USES_LAA" -eq 1 ] && ! is_laa_mac "$mac"; then
    if [ -n "$GW_OUI" ] && [ "$oui" = "$GW_OUI" ]; then
      reason="老闆/系統手動機 (與網關同為原生 ${oui})"
    elif is_hypervisor_oui "$mac"; then
      reason="母雞手動建立節點 (原生虛擬化 OUI ${oui})"
    else
      reason="實體網卡/基礎設施設備 (硬體 OUI ${oui})"
    fi
  # 規則 4: 純固定 OUI 環境下的特殊管理位 (.2 橋接位，或 .100 探針位且 OUI 與本機不同)
  elif [ "$last_octet" -eq 2 ] && [ "${MY_IP##*.}" -ge 100 ]; then
    reason="母雞內網橋接/管理位 (.2)"
  elif [ "$last_octet" -eq 100 ] && [ "${MY_IP##*.}" -gt 100 ] && [ -n "$MY_MAC" ] && [ "$oui" != "${MY_MAC:0:8}" ]; then
    reason="疑似母雞探針/管理機 (.100)"
  fi

  if [ -n "$reason" ]; then
    echo "${ip}|${mac}|${state}|${ping_ok}|${reason}" >> "$SYSTEM_NODES_FILE"
  else
    echo "${ip}|${mac}|${state}|${ping_ok}|真實買家" >> "$REAL_USERS_FILE"
  fi
done <<< "$ARP_RAW"

REAL_COUNT=$(wc -l < "$REAL_USERS_FILE" | tr -d '[:space:]')
SYS_COUNT=$(wc -l < "$SYSTEM_NODES_FILE" | tr -d '[:space:]')
TOTAL_SHARING=$((REAL_COUNT + 1))

echo ""
echo -e "👥 ${C_BOLD}【真實買家鄰居清單】（共 ${C_GREEN}${REAL_COUNT}${C_RESET}${C_BOLD} 位鄰居，含你共 ${C_GREEN}${TOTAL_SHARING}${C_RESET}${C_BOLD} 人共用此 IP）：${C_RESET}"
echo -e "  序號  內網 IP          MAC 位址            ARP 狀態    回應類型"
echo -e "  ----------------------------------------------------------------------"

if [ "$REAL_COUNT" -eq 0 ]; then
  echo -e "  ${C_GREEN}🎉 目前整個網段沒有任何其他買家鄰居在線（你獨享此 IP）！${C_RESET}"
else
  awk -F'|' '{
    ping_str = ($4 == 1) ? "✅ Ping 正常" : "🛡️ 禁Ping(ARP在線)"
    printf "  #%2d   %-15s  %-18s  %-10s  %s\n", NR, $1, $2, $3, ping_str
  }' "$REAL_USERS_FILE"
fi

if [ "$SYS_COUNT" -gt 0 ]; then
  echo ""
  echo -e "🛠️  ${C_BOLD}【已自動排除的母雞 / 老闆 / 系統節點】（共 ${SYS_COUNT} 台，不計入買家）：${C_RESET}"
  awk -F'|' '{
    printf "   • %-15s (MAC: %s) -> %s\n", $1, $2, $5
  }' "$SYSTEM_NODES_FILE"
fi

echo -e "------------------------------------------------------------------------"
echo -e "📌 ${C_BOLD}階段一結論${C_RESET}: 當前同區真實買家鄰居 ${C_GREEN}${C_BOLD}${REAL_COUNT}${C_RESET} 人 | 實際共用此 IP 買家總數: ${C_GREEN}${C_BOLD}${TOTAL_SHARING}${C_RESET} 人"
echo -e "${C_BOLD}========================================================================${C_RESET}"

# 若為快速模式 (-q) 則到此結束
if [ "$QUICK_MODE" -eq 1 ]; then
  exit 0
fi

# ------------------------------------------------------------------------------
# 階段二：鄰居活躍度與線路負載排行 (RTT Micro-Jitter Profiling)
# ------------------------------------------------------------------------------
TARGET_FILE="$REAL_USERS_FILE"
if [ "$INCLUDE_ALL" -eq 1 ]; then
  cat "$REAL_USERS_FILE" "$SYSTEM_NODES_FILE" > "${TMP_DIR}/all_targets.txt"
  TARGET_FILE="${TMP_DIR}/all_targets.txt"
fi

TARGET_COUNT=$(wc -l < "$TARGET_FILE" | tr -d '[:space:]')
if [ "$TARGET_COUNT" -eq 0 ]; then
  exit 0
fi

# 自動挑選距離最近的外網基準節點 (比較 168.95.1.1 / 1.1.1.1 / 8.8.8.8)
select_wan_anchor() {
  local best_ip="1.1.1.1"
  local best_label="Cloudflare Anycast"
  local best_rtt=999999

  for cand in "168.95.1.1:HiNet 台灣機房" "1.1.1.1:Cloudflare 節點" "8.8.8.8:Google 節點"; do
    local cip="${cand%%:*}"
    local clabel="${cand#*:}"
    local rtt
    rtt=$(ping -c 1 -W 1 "$cip" 2>/dev/null | awk -F'=' '/rtt|round-trip/ {split($2, a, "/"); gsub(/ /, "", a[2]); printf "%d", a[2]*1000}')
    if [ -n "$rtt" ] && [ "$rtt" -gt 0 ] && [ "$rtt" -lt "$best_rtt" ]; then
      best_rtt="$rtt"
      best_ip="$cip"
      best_label="$clabel"
    fi
  done
  echo "${best_ip}|${best_label}"
}

WAN_INFO=$(select_wan_anchor)
WAN_IP="${WAN_INFO%%|*}"
WAN_LABEL="${WAN_INFO#*|}"

EST_SEC=$(awk -v c="$SAMPLE_COUNT" -v i="$PING_INTERVAL" 'BEGIN {printf "%.1f", c * i + 0.8}')
echo ""
echo -e "⚡ ${C_BOLD}[階段二] 正在進行鄰居活躍度與微抖動採樣（每台 ${SAMPLE_COUNT} 次，約需 ${EST_SEC} 秒）...${C_RESET}"

(
  mkdir -p "${TMP_DIR}/pings"
  ping -c "$SAMPLE_COUNT" -i "$PING_INTERVAL" -W 1 "$GW_IP" > "${TMP_DIR}/pings/gw" 2>/dev/null &
  ping -c "$SAMPLE_COUNT" -i "$PING_INTERVAL" -W 1 "$WAN_IP" > "${TMP_DIR}/pings/wan" 2>/dev/null &

  while IFS='|' read -r ip mac state ping_ok role; do
    [ -z "$ip" ] && continue
    if [ "$ping_ok" -eq 1 ]; then
      ping -c "$SAMPLE_COUNT" -i "$PING_INTERVAL" -W 1 "$ip" > "${TMP_DIR}/pings/${ip}" 2>/dev/null &
      sleep 0.01 2>/dev/null || true
    fi
  done < "$TARGET_FILE"
  wait
)

parse_ping_file() {
  local file="$1"
  [ ! -f "$file" ] && return 0
  awk -F'=' '/rtt|round-trip/ {
    gsub(/ /, "", $2)
    split($2, a, "/")
    gsub(/[a-zA-Z ]/, "", a[4])
    if (a[2] != "" && a[4] != "") {
      printf "%.3f %.3f %.3f %.3f", a[1], a[2], a[3], a[4]
    }
  }' "$file"
}

GW_STAT=$(parse_ping_file "${TMP_DIR}/pings/gw")
WAN_STAT=$(parse_ping_file "${TMP_DIR}/pings/wan")
GW_MDEV=$(echo "$GW_STAT" | awk '{print ($4 != "") ? $4 : 0.050}')

echo -e "------------------------------------------------------------------------"
echo -e "🌐 ${C_BOLD}【本區母雞與外網負載基準】${C_RESET} (平均延遲 avg / 最大峰值 max / 抖動 mdev)"
if [ -n "$GW_STAT" ]; then
  echo "$GW_STAT" | awk -v gw="$GW_IP" '{
    printf "  • 內網網關 (%-13s) : avg %6.3f ms | max %6.3f ms | 抖動 %6.3f ms\n", gw, $2, $3, $4
  }'
fi
if [ -n "$WAN_STAT" ]; then
  echo "$WAN_STAT" | awk -v wip="$WAN_IP" -v wlbl="$WAN_LABEL" '{
    if ($4 >= 3.0 || $2 >= 25.0) {
      tag = "🔥 外網高峰擁擠 (有鄰居正在跑大流量)"
    } else if ($4 >= 1.2 || $2 >= 12.0) {
      tag = "⚡ 外網輕度負載 (有鄰居間歇使用)"
    } else {
      tag = "✅ 外網非常空閒 (頻寬充裕)"
    }
    printf "  • 外網基準 (%-13s) : avg %6.3f ms | max %6.3f ms | 抖動 %6.3f ms [%s]\n", wip, $2, $3, $4, tag
  }'
fi

echo -e "------------------------------------------------------------------------"
echo -e "📊 ${C_BOLD}【買家鄰居活躍度排行榜】${C_RESET}（依微延遲抖動 mdev 由高至低排序）："
echo -e "  排名  內網 IP          平均延遲    最大峰值    抖動(mdev)   活躍度狀態"
echo -e "  ----------------------------------------------------------------------"

RANK_DATA="${TMP_DIR}/rank_data.txt"
: > "$RANK_DATA"

while IFS='|' read -r ip mac state ping_ok role; do
  [ -z "$ip" ] && continue
  if [ "$ping_ok" -eq 1 ]; then
    stat=$(parse_ping_file "${TMP_DIR}/pings/${ip}")
    if [ -n "$stat" ]; then
      echo "${ip} ${stat} 1 ${role}" >> "$RANK_DATA"
    else
      echo "${ip} 0.000 0.000 0.000 0.000 0 ${role}" >> "$RANK_DATA"
    fi
  else
    echo "${ip} 0.000 0.000 0.000 0.000 0 ${role}" >> "$RANK_DATA"
  fi
done < "$TARGET_FILE"

SORTED_RANK=$(sort -k6,6nr -k5,5nr -k4,4nr "$RANK_DATA")

echo "$SORTED_RANK" | awk -v gw_mdev="$GW_MDEV" '
BEGIN {
  active_cnt = 0
  light_cnt = 0
  idle_cnt = 0
  stealth_cnt = 0
}
{
  ip = $1; min = $2; avg = $3; max = $4; mdev = $5; ok = $6
  if (ok == 0) {
    stealth_cnt++
    printf "  #%2d   %-15s    --        --        --       🛡️ 禁Ping防火牆 (ARP在線)\n", NR, ip
    next
  }

  # 綜合絕對抖動閾值與相對網關基準倍數判定活躍度
  active_thresh = (gw_mdev * 2.5 > 0.140) ? gw_mdev * 2.5 : 0.140
  light_thresh  = (gw_mdev * 1.4 > 0.060) ? gw_mdev * 1.4 : 0.060

  if (mdev >= active_thresh || max >= 1.500) {
    tag = "🔥 活躍跑流量中"
    active_cnt++
  } else if (mdev >= light_thresh || max >= 0.700) {
    tag = "⚡ 輕度活動/間歇連線"
    light_cnt++
  } else {
    tag = "💤 吃灰閒置 (靜止)"
    idle_cnt++
  }
  printf "  #%2d   %-15s %6.3f ms   %6.3f ms   %6.3f ms    %s\n", NR, ip, avg, max, mdev, tag
}
END {
  printf "  ----------------------------------------------------------------------\n"
  printf "  📈 鄰居狀態統計: 🔥 活躍 %d 人 | ⚡ 輕度 %d 人 | 💤 吃灰 %d 人", active_cnt, light_cnt, idle_cnt
  if (stealth_cnt > 0) {
    printf " | 🛡️ 禁Ping %d 人", stealth_cnt
  }
  printf "\n"
}'

echo -e "${C_BOLD}========================================================================${C_RESET}"
