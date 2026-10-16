#!/usr/bin/env bash
# ==============================================================================
# nat-neighbour (nat.sh) — KVM / LXC NAT VPS 鄰居數量普查與活躍度探測工具
# Repository: https://github.com/YuanquYuefu/find-u-natneighbour
# Version: 1.2.1
# License: MIT
# ==============================================================================

set -u

VERSION="1.2.1"
INSTALL_PATH="/usr/local/bin/nat"
REPO_RAW_URL="https://raw.githubusercontent.com/YuanquYuefu/find-u-natneighbour/main/nat.sh"
SAMPLE_COUNT=50
RUN_MODE=""
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
項目地址: https://github.com/YuanquYuefu/find-u-natneighbour

用法:
  nat             喚出互動式菜單（0.退出 / 1.查鄰居 / 2.查活躍鄰居 / 3.先1後2 / 4.檢查並更新 / 5.刪除）
  nat [1|2|3|4|5] 免菜單直接執行對應功能
  nat [選項]

菜單與快捷模式:
  0                 退出程式
  1, -q, --quick    看看你有多少鄰居（僅執行階段一：二層 ARP 普查與真實買家識別，約 2 秒）
  2, --active       看看此時你有多少活躍鄰居（執行階段二：微延遲抖動採樣與活躍排行，約 7 秒）
  3, --both         先執行 1 再執行 2（完整執行階段一與階段二）
  4, -u, --update   檢查並更新（強制透過 IPv4 / IPv6 自動容錯從 GitHub 拉取最新版）
  5, --uninstall    刪除（移除已安裝的 ${INSTALL_PATH} 快捷指令與本地腳本）

進階選項:
  -c, --count N     指定活躍度採樣 Ping 次數（預設: 50 次，約 5 秒）
  -a, --all         將疑似母雞/老闆手動開的系統節點也納入活躍度排行榜
  --install         手動將本腳本安裝/更新至 ${INSTALL_PATH}
  -h, --help        顯示本幫助說明
  -v, --version     顯示版本號
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
      echo -e "${C_GREEN}✅ 已自動註冊快捷指令：之後在終端機直接輸入 ${C_BOLD}nat${C_RESET}${C_GREEN} 即可喚出菜單！${C_RESET}"
    fi
  elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    tr -d '\r' < "$src" | sudo tee "$INSTALL_PATH" >/dev/null 2>&1 && sudo chmod +x "$INSTALL_PATH" 2>/dev/null
    if [ -x "$INSTALL_PATH" ]; then
      echo -e "${C_GREEN}✅ 已自動註冊快捷指令：之後在終端機直接輸入 ${C_BOLD}nat${C_RESET}${C_GREEN} 即可喚出菜單！${C_RESET}"
    fi
  fi
}

# 強制使用 IPv4 / IPv6 自動容錯且顯示進度下載（先 IPv4 再 IPv6）
download_with_fallback() {
  local url="$1"
  local out="$2"
  if command -v wget >/dev/null 2>&1; then
    echo -e "🌐 正在透過 wget (先 IPv4 後 IPv6 自動容錯) 下載: ${C_CYAN}${url}${C_RESET}"
    if wget -4 --timeout=10 --tries=2 -O "$out" "$url" || wget -6 --timeout=10 --tries=1 -O "$out" "$url"; then
      return 0
    fi
  fi
  if command -v curl >/dev/null 2>&1; then
    echo -e "🌐 正在透過 curl (先 IPv4 後 IPv6 自動容錯) 下載: ${C_CYAN}${url}${C_RESET}"
    if curl -4 -fL --connect-timeout 10 -o "$out" "$url" || curl -6 -fL --connect-timeout 10 -o "$out" "$url"; then
      return 0
    fi
  fi
  return 1
}

# 選項 4：檢查並更新
run_stage4() {
  echo -e "🔄 ${C_BOLD}[4. 檢查並更新] 當前版本: v${VERSION}，正在連線 GitHub 檢查並拉取最新版本...${C_RESET}"
  local tmp_new
  tmp_new=$(mktemp 2>/dev/null || echo "/tmp/nat_update_$$.sh")

  if ! download_with_fallback "$REPO_RAW_URL" "$tmp_new"; then
    rm -f "$tmp_new" "${tmp_new}.lf" 2>/dev/null
    echo -e "${C_RED}❌ 下載失敗：IPv4 與 IPv6 均無法連線至 GitHub Raw，請檢查本機網路或 DNS 設定。${C_RESET}" >&2
    echo -e "${C_BOLD}========================================================================${C_RESET}"
    return 1
  fi

  if [ ! -s "$tmp_new" ] || ! grep -q '^VERSION=' "$tmp_new" 2>/dev/null; then
    rm -f "$tmp_new" "${tmp_new}.lf" 2>/dev/null
    echo -e "${C_RED}❌ 校驗失敗：下載的檔案內容不完整或非有效腳本，已中止更新。${C_RESET}" >&2
    echo -e "${C_BOLD}========================================================================${C_RESET}"
    return 1
  fi

  tr -d '\r' < "$tmp_new" > "${tmp_new}.lf"
  local remote_ver
  remote_ver=$(grep -m1 '^VERSION=' "${tmp_new}.lf" | awk -F'"' '{print $2}')
  [ -z "$remote_ver" ] && remote_ver="未知"

  local updated_ok=0
  if [ "$(id -u)" -eq 0 ] || [ -w "$(dirname "$INSTALL_PATH")" ] || [ -w "$INSTALL_PATH" ]; then
    cp -f "${tmp_new}.lf" "$INSTALL_PATH" 2>/dev/null && chmod +x "$INSTALL_PATH" 2>/dev/null && updated_ok=1
  elif command -v sudo >/dev/null 2>&1; then
    sudo cp -f "${tmp_new}.lf" "$INSTALL_PATH" 2>/dev/null && sudo chmod +x "$INSTALL_PATH" 2>/dev/null && updated_ok=1
  fi

  local src="${BASH_SOURCE[0]:-$0}"
  local real_src
  real_src=$(readlink -f "$src" 2>/dev/null || echo "$src")
  if [ -f "$real_src" ] && [ "$real_src" != "$INSTALL_PATH" ] && [ -w "$real_src" ]; then
    cp -f "${tmp_new}.lf" "$real_src" 2>/dev/null && chmod +x "$real_src" 2>/dev/null && updated_ok=1
  fi

  rm -f "$tmp_new" "${tmp_new}.lf" 2>/dev/null

  if [ "$updated_ok" -eq 1 ]; then
    if [ "$remote_ver" != "$VERSION" ]; then
      echo -e "🎉 ${C_GREEN}${C_BOLD}發現新版本並完成更新：v${VERSION} -> v${remote_ver}（路徑: ${INSTALL_PATH}）！${C_RESET}"
      VERSION="$remote_ver"
    else
      echo -e "✅ ${C_GREEN}${C_BOLD}當前已是最新版本 (v${remote_ver})，已重新同步覆蓋至最新腳本！${C_RESET}"
    fi
    echo -e "${C_BOLD}========================================================================${C_RESET}"
    return 0
  else
    echo -e "${C_RED}❌ 權限不足：無法寫入 ${INSTALL_PATH}，請使用 root 或 sudo 權限執行。${C_RESET}" >&2
    echo -e "${C_BOLD}========================================================================${C_RESET}"
    return 1
  fi
}

# 選項 5：刪除
run_stage5() {
  echo -e "🗑️  ${C_BOLD}[5. 刪除] 正在從系統中移除 nat-neighbour...${C_RESET}"
  local removed_any=0

  if [ -f "$INSTALL_PATH" ]; then
    if rm -f "$INSTALL_PATH" 2>/dev/null || (command -v sudo >/dev/null 2>&1 && sudo rm -f "$INSTALL_PATH" 2>/dev/null); then
      echo -e "${C_GREEN}✅ 已移除全局快捷指令: ${INSTALL_PATH}${C_RESET}"
      removed_any=1
    else
      echo -e "${C_RED}❌ 無法移除 ${INSTALL_PATH}，請使用 root 或 sudo 權限執行。${C_RESET}" >&2
      return 1
    fi
  fi

  local src="${BASH_SOURCE[0]:-$0}"
  local real_src
  real_src=$(readlink -f "$src" 2>/dev/null || echo "$src")
  if [ -f "$real_src" ] && [ "$real_src" != "$INSTALL_PATH" ]; then
    if rm -f "$real_src" 2>/dev/null; then
      echo -e "${C_GREEN}✅ 已移除本地腳本檔案: ${real_src}${C_RESET}"
      removed_any=1
    fi
  fi

  if [ "$removed_any" -eq 0 ]; then
    echo -e "${C_YELLOW}提示: 系統中未找到已安裝的 ${INSTALL_PATH}${C_RESET}"
  else
    echo -e "${C_GREEN}${C_BOLD}👋 刪除完成，感謝使用！${C_RESET}"
  fi
  echo -e "${C_BOLD}========================================================================${C_RESET}"
  exit 0
}

# 解析命令列參數
while [ $# -gt 0 ]; do
  case "$1" in
    0)
      exit 0
      ;;
    1|-q|--quick)
      RUN_MODE="1"
      shift
      ;;
    2|--active)
      RUN_MODE="2"
      shift
      ;;
    3|--both)
      RUN_MODE="3"
      shift
      ;;
    4|-u|--update)
      run_stage4
      exit $?
      ;;
    5|--uninstall|--remove)
      run_stage5
      exit $?
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

REAL_USERS_FILE="${TMP_DIR}/real_users.txt"
SYSTEM_NODES_FILE="${TMP_DIR}/system_nodes.txt"
REAL_COUNT=0
SYS_COUNT=0
TOTAL_SHARING=1

print_banner() {
  echo -e "${C_BOLD}========================================================================${C_RESET}"
  echo -e "🛰️  ${C_BOLD}NAT 鄰居普查與活躍度探測工具 v${VERSION}${C_RESET}  (架構: ${C_CYAN}${VIRT_TYPE}${C_RESET} | 介面: ${C_CYAN}${IFACE}${C_RESET})"
  echo -e "${C_BOLD}========================================================================${C_RESET}"
  echo -e "📍 本機內網 IP : ${C_GREEN}${MY_IP}${C_RESET} (/${PREFIX_LEN})   MAC: ${C_DIM}${MY_MAC:-未知}${C_RESET}"
  echo -e "🛣️  內網預設網關: ${C_YELLOW}${GW_IP}${C_RESET}           共享公網 IPv4: ${C_CYAN}${PUB_IP:-未檢出}${C_RESET}"
  echo -e "------------------------------------------------------------------------"
}

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

scan_neighbours() {
  rm -rf "${TMP_DIR}/alive"
  mkdir -p "${TMP_DIR}/alive"

  # 子程序併發 Ping 觸發同網段 ARP 解析與存活檢測
  (
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
  local arp_raw
  arp_raw=$(ip -4 neigh show dev "$IFACE" 2>/dev/null | awk '
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

  local gw_mac gw_oui
  gw_mac=$(echo "$arp_raw" | awk -v gw="$GW_IP" '$1 == gw {print $2; exit}')
  gw_oui="${gw_mac:0:8}"

  local my_is_laa=0
  if [ -n "$MY_MAC" ] && is_laa_mac "$MY_MAC"; then
    my_is_laa=1
  fi

  # 統計非網關節點中 LAA 隨機 MAC 與標準 OUI 的數量分佈
  local laa_count=0
  local non_gw_count=0
  while read -r ip mac state is_router; do
    [ -z "$ip" ] && continue
    [ "$ip" = "$GW_IP" ] || [ "$ip" = "$MY_IP" ] && continue
    non_gw_count=$((non_gw_count + 1))
    if is_laa_mac "$mac"; then
      laa_count=$((laa_count + 1))
    fi
  done <<< "$arp_raw"

  # 若本機為 LAA 隨機 MAC，或網段內存在 >=2 台 LAA 面板自動開通實例，則啟用「面板 LAA vs 手動 OUI」識別模式
  local panel_uses_laa=0
  if [ "$my_is_laa" -eq 1 ] || [ "$laa_count" -ge 2 ]; then
    panel_uses_laa=1
  fi

  : > "$REAL_USERS_FILE"
  : > "$SYSTEM_NODES_FILE"

  while read -r ip mac state is_router; do
    [ -z "$ip" ] && continue
    [ "$ip" = "$MY_IP" ] && continue

    local last_octet="${ip##*.}"
    local oui="${mac:0:8}"
    local ping_ok=0
    [ -f "${TMP_DIR}/alive/${ip}" ] && ping_ok=1

    local reason=""
    # 規則 1: 預設網關或宣告為 Router 的節點
    if [ "$ip" = "$GW_IP" ] || [ "$is_router" -eq 1 ]; then
      reason="網關/路由節點 (Gateway)"
    # 規則 2: 常見保留網關尾號 (.1 / .254)
    elif [ "$last_octet" -eq 1 ] || [ "$last_octet" -eq 254 ]; then
      reason="網段保留網關位 (.${last_octet})"
    # 規則 3: 在面板使用 LAA 隨機 MAC 的環境中，出現宿主機原生固定 OUI (如 PVE bc:24:11)
    elif [ "$panel_uses_laa" -eq 1 ] && ! is_laa_mac "$mac"; then
      if [ -n "$gw_oui" ] && [ "$oui" = "$gw_oui" ]; then
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
  done <<< "$arp_raw"

  REAL_COUNT=$(wc -l < "$REAL_USERS_FILE" | tr -d '[:space:]')
  SYS_COUNT=$(wc -l < "$SYSTEM_NODES_FILE" | tr -d '[:space:]')
  TOTAL_SHARING=$((REAL_COUNT + 1))
}

# ------------------------------------------------------------------------------
# 選項 1：看看你有多少鄰居（階段一：二層 ARP 普查與真實買家識別）
# ------------------------------------------------------------------------------
run_stage1() {
  echo -e "🔍 ${C_BOLD}[1. 看看你有多少鄰居] 正在併發掃描 ${NET}.0/24 二層 ARP 與存活主機（約 2 秒）...${C_RESET}"
  scan_neighbours

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
  echo -e "📌 ${C_BOLD}鄰居普查結論${C_RESET}: 當前同區真實買家鄰居 ${C_GREEN}${C_BOLD}${REAL_COUNT}${C_RESET} 人 | 實際共用此 IP 買家總數: ${C_GREEN}${C_BOLD}${TOTAL_SHARING}${C_RESET} 人"
  echo -e "${C_BOLD}========================================================================${C_RESET}"
}

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

parse_ping_file() {
  local file="$1"
  [ ! -f "$file" ] && return 0
  awk '
    /time=[0-9.]+/ {
      if (match($0, /time=[0-9.]+/)) {
        val = substr($0, RSTART + 5, RLENGTH - 5) + 0
        n++
        samples[n] = val
      }
    }
    /rtt|round-trip/ {
      split($0, parts, "=")
      if (parts[2] != "") {
        gsub(/ /, "", parts[2])
        split(parts[2], a, "/")
        gsub(/[a-zA-Z ]/, "", a[4])
        s_min = a[1]; s_avg = a[2]; s_max = a[3]; s_mdev = a[4]
      }
    }
    END {
      if (s_avg == "" || s_mdev == "") exit 0
      trim_mdev = s_mdev + 0
      if (n >= 10) {
        for (i = 2; i <= n; i++) {
          key = samples[i]
          j = i - 1
          while (j >= 1 && samples[j] > key) {
            samples[j + 1] = samples[j]
            j--
          }
          samples[j + 1] = key
        }
        drop = (n >= 20) ? 2 : 1
        k = n - drop
        sum = 0
        for (i = 1; i <= k; i++) sum += samples[i]
        mean = sum / k
        sq = 0
        for (i = 1; i <= k; i++) sq += (samples[i] - mean) * (samples[i] - mean)
        trim_mdev = sqrt(sq / k)
      }
      printf "%.3f %.3f %.3f %.3f %.3f", s_min, s_avg, s_max, s_mdev, trim_mdev
    }
  ' "$file"
}

# ------------------------------------------------------------------------------
# 選項 2：看看此時你有多少活躍鄰居（階段二：RTT Micro-Jitter Profiling）
# 參數 $1: reuse_scan (1=直接沿用剛完成之階段一掃描結果, 0=先自動掃描在線鄰居)
# ------------------------------------------------------------------------------
run_stage2() {
  local reuse_scan="${1:-0}"
  if [ "$reuse_scan" -ne 1 ]; then
    echo -e "🔍 ${C_BOLD}[2. 看看此時你有多少活躍鄰居] 正在定位 ${NET}.0/24 在線鄰居（約 2 秒）...${C_RESET}"
    scan_neighbours
  fi

  local target_file="$REAL_USERS_FILE"
  if [ "$INCLUDE_ALL" -eq 1 ]; then
    cat "$REAL_USERS_FILE" "$SYSTEM_NODES_FILE" > "${TMP_DIR}/all_targets.txt"
    target_file="${TMP_DIR}/all_targets.txt"
  fi

  local target_count
  target_count=$(wc -l < "$target_file" | tr -d '[:space:]')
  if [ "$target_count" -eq 0 ]; then
    echo ""
    echo -e "🎉 ${C_GREEN}${C_BOLD}目前整個網段沒有任何其他鄰居在線，此時活躍鄰居為 0 人（你獨享此 IP）！${C_RESET}"
    echo -e "${C_BOLD}========================================================================${C_RESET}"
    return 0
  fi

  local wan_info wan_ip wan_label est_sec
  wan_info=$(select_wan_anchor)
  wan_ip="${wan_info%%|*}"
  wan_label="${wan_info#*|}"

  est_sec=$(awk -v c="$SAMPLE_COUNT" -v i="$PING_INTERVAL" 'BEGIN {printf "%.1f", c * i + 0.8}')
  echo ""
  echo -e "⚡ ${C_BOLD}[2. 看看此時你有多少活躍鄰居] 正在進行微延遲抖動採樣（每台 ${SAMPLE_COUNT} 次，約需 ${est_sec} 秒）...${C_RESET}"

  rm -rf "${TMP_DIR}/pings"
  (
    mkdir -p "${TMP_DIR}/pings"
    ping -c "$SAMPLE_COUNT" -i "$PING_INTERVAL" -W 1 "$GW_IP" > "${TMP_DIR}/pings/gw" 2>/dev/null &
    ping -c "$SAMPLE_COUNT" -i "$PING_INTERVAL" -W 1 "$wan_ip" > "${TMP_DIR}/pings/wan" 2>/dev/null &

    while IFS='|' read -r ip mac state ping_ok role; do
      [ -z "$ip" ] && continue
      if [ "$ping_ok" -eq 1 ]; then
        ping -c "$SAMPLE_COUNT" -i "$PING_INTERVAL" -W 1 "$ip" > "${TMP_DIR}/pings/${ip}" 2>/dev/null &
        sleep 0.01 2>/dev/null || true
      fi
    done < "$target_file"
    wait
  )

  local gw_stat wan_stat gw_mdev gw_trim_mdev active_thresh_str light_thresh_str
  gw_stat=$(parse_ping_file "${TMP_DIR}/pings/gw")
  wan_stat=$(parse_ping_file "${TMP_DIR}/pings/wan")
  gw_mdev=$(echo "$gw_stat" | awk '{print ($4 != "") ? $4 : 0.060}')
  gw_trim_mdev=$(echo "$gw_stat" | awk '{print ($5 != "") ? $5 : 0.045}')

  active_thresh_str=$(awk -v g="$gw_mdev" 'BEGIN {printf "%.3f", (g * 2.2 > 0.220) ? g * 2.2 : 0.220}')
  light_thresh_str=$(awk -v g="$gw_mdev" 'BEGIN {printf "%.3f", (g * 1.5 > 0.120) ? g * 1.5 : 0.120}')

  echo -e "------------------------------------------------------------------------"
  echo -e "🌐 ${C_BOLD}【本區母雞與外網負載基準】${C_RESET} (平均延遲 avg / 最大峰值 max / 抖動 mdev)"
  if [ -n "$gw_stat" ]; then
    echo "$gw_stat" | awk -v gw="$GW_IP" '{
      printf "  • 內網網關 (%-13s) : avg %6.3f ms | max %6.3f ms | 抖動 %6.3f ms\n", gw, $2, $3, $4
    }'
  fi
  if [ -n "$wan_stat" ]; then
    echo "$wan_stat" | awk -v wip="$wan_ip" -v wlbl="$wan_label" '{
      if ($4 >= 3.0) {
        tag = "🔥 外網高峰擁擠 (有鄰居正在跑大流量)"
      } else if ($4 >= 1.0) {
        tag = "⚡ 外網輕度波動 (有鄰居間歇使用)"
      } else {
        tag = "✅ 外網非常空閒 (頻寬充裕)"
      }
      printf "  • 外網基準 (%-13s) : avg %6.3f ms | max %6.3f ms | 抖動 %6.3f ms [%s]\n", wip, $2, $3, $4, tag
    }'
  fi

  echo -e "------------------------------------------------------------------------"
  echo -e "📊 ${C_BOLD}【買家鄰居活躍度排行榜】${C_RESET}（共 ${C_GREEN}${target_count}${C_RESET}${C_BOLD} 人 | 動態抖動門檻: ⚡輕度≥${light_thresh_str}ms / 🔥活躍≥${active_thresh_str}ms）："
  echo -e "  排名  內網 IP          平均延遲    最大峰值    抖動(mdev)   活躍度狀態"
  echo -e "  ----------------------------------------------------------------------"

  local rank_data="${TMP_DIR}/rank_data.txt"
  : > "$rank_data"

  while IFS='|' read -r ip mac state ping_ok role; do
    [ -z "$ip" ] && continue
    if [ "$ping_ok" -eq 1 ]; then
      local stat
      stat=$(parse_ping_file "${TMP_DIR}/pings/${ip}")
      if [ -n "$stat" ]; then
        echo "${ip} ${stat} 1 ${role}" >> "$rank_data"
      else
        echo "${ip} 0.000 0.000 0.000 0.000 0.000 0 ${role}" >> "$rank_data"
      fi
    else
      echo "${ip} 0.000 0.000 0.000 0.000 0.000 0 ${role}" >> "$rank_data"
    fi
  done < "$target_file"

  local sorted_rank
  sorted_rank=$(sort -k7,7nr -k5,5nr -k4,4nr "$rank_data")

  echo "$sorted_rank" | awk -v gw_mdev="$gw_mdev" -v gw_trim="$gw_trim_mdev" '
  BEGIN {
    active_cnt = 0
    light_cnt = 0
    idle_cnt = 0
    stealth_cnt = 0
    active_thresh = (gw_mdev * 2.2 > 0.220) ? gw_mdev * 2.2 : 0.220
    light_thresh  = (gw_mdev * 1.5 > 0.120) ? gw_mdev * 1.5 : 0.120
    trim_active_thresh = (gw_trim * 1.8 > 0.100) ? gw_trim * 1.8 : 0.100
    trim_light_thresh  = (gw_trim * 1.35 > 0.065) ? gw_trim * 1.35 : 0.065
  }
  {
    ip = $1; min = $2; avg = $3; max = $4; mdev = $5; trim_mdev = $6; ok = $7
    if (ok == 0) {
      stealth_cnt++
      printf "  #%2d   %-15s    --        --        --       🛡️ 禁Ping防火牆 (ARP在線)\n", NR, ip
      next
    }

    # 依據相對網關基準抖動 (mdev) 與去極值抖動 (trim_mdev) 雙重確認，避免單次 max 尖峰誤判
    if (mdev >= active_thresh && trim_mdev >= trim_active_thresh) {
      tag = "🔥 活躍跑流量中"
      active_cnt++
    } else if (mdev >= light_thresh && trim_mdev >= trim_light_thresh) {
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
    printf "  📌 活躍探測結論: 此時正在跑流量的活躍鄰居 %d 人 | 輕度間歇活動 %d 人 | 吃灰閒置 %d 人\n", active_cnt, light_cnt, idle_cnt
  }'

  echo -e "${C_BOLD}========================================================================${C_RESET}"
}

# ------------------------------------------------------------------------------
# 選項 3：先執行 1 再執行 2
# ------------------------------------------------------------------------------
run_stage3() {
  run_stage1
  run_stage2 1
}

# ------------------------------------------------------------------------------
# 主流程：命令列直接執行 或 喚出互動式菜單
# ------------------------------------------------------------------------------
if [ -n "$RUN_MODE" ]; then
  print_banner
  case "$RUN_MODE" in
    1) run_stage1 ;;
    2) run_stage2 0 ;;
    3) run_stage3 ;;
  esac
  exit 0
fi

# 互動式菜單模式（直接輸入 nat 時喚出）
print_banner
while true; do
  echo -e "  ${C_YELLOW}0.${C_RESET} 退出"
  echo -e "  ${C_GREEN}1.${C_RESET} 看看你有多少鄰居"
  echo -e "  ${C_CYAN}2.${C_RESET} 看看此時你有多少活躍鄰居"
  echo -e "  ${C_BLUE}3.${C_RESET} 先執行1再執行2"
  echo -e "  ${C_GREEN}4.${C_RESET} 檢查並更新"
  echo -e "  ${C_RED}5.${C_RESET} 刪除"
  echo -e "------------------------------------------------------------------------"
  printf "請輸入選項 [0-5]: "

  if [ -t 0 ]; then
    if ! read -r choice; then
      echo ""
      exit 0
    fi
  elif [ -e /dev/tty ]; then
    if ! read -r choice < /dev/tty; then
      echo ""
      exit 0
    fi
  else
    echo "3"
    run_stage3
    exit 0
  fi

  choice=$(echo "$choice" | tr -d '[:space:]')
  case "$choice" in
    0)
      echo -e "${C_GREEN}👋 已退出。${C_RESET}"
      exit 0
      ;;
    1)
      echo -e "------------------------------------------------------------------------"
      run_stage1
      echo ""
      ;;
    2)
      echo -e "------------------------------------------------------------------------"
      run_stage2 0
      echo ""
      ;;
    3)
      echo -e "------------------------------------------------------------------------"
      run_stage3
      echo ""
      ;;
    4)
      echo -e "------------------------------------------------------------------------"
      run_stage4
      echo ""
      ;;
    5)
      echo -e "------------------------------------------------------------------------"
      run_stage5
      ;;
    *)
      echo -e "${C_RED}⚠️  無效選項 '${choice}'，請輸入 0 ~ 5 之間的數字。${C_RESET}"
      echo -e "------------------------------------------------------------------------"
      ;;
  esac
done

