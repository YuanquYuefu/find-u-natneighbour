# find-u-natneighbour 項目約定

倉庫地址：[https://github.com/YuanquYuefu/find-u-natneighbour](https://github.com/YuanquYuefu/find-u-natneighbour)

## 版本與入口

| 版本 | 腳本 | 說明文檔 | 適用範圍 |
| --- | --- | --- | --- |
| 通用版 1.2.0 | [nat.sh](nat.sh) | [README.md](README.md) | 通用於 KVM / LXC / OpenVZ 架構之 NAT VPS，提供 `0~5` 互動菜單與免菜單快捷模式，支援 IPv6/IPv4 自動容錯下載更新，完成同區鄰居人數普查、真實買家識別與活躍鄰居排行 |

## 設計目標與行為規範

1. **一鍵安裝與互動菜單呼叫**：
   - 支援使用者透過單行非靜默 `wget` 指令（強制 `wget -6 ... || wget -4 ...` IPv6/IPv4 自動容錯並顯示即時進度）從 `https://raw.githubusercontent.com/YuanquYuefu/find-u-natneighbour/main/nat.sh` 下載至 `/usr/local/bin/nat`（或下載為 `nat.sh` 首次執行時自動安裝至 `/usr/local/bin/nat`）。
   - 在 LXC / KVM 終端機中直接輸入 `nat` 無參數執行時，喚出互動式數字菜單：
     - `0. 退出`：退出工具
     - `1. 看看你有多少鄰居`：執行階段一（同網段二層 ARP 鄰居人數普查與真實買家過濾）
     - `2. 看看此時你有多少活躍鄰居`：執行階段二（自動定位在線鄰居，進行母雞外網負載基準測試與鄰居活躍度排行榜，統計當下活躍鄰居人數）
     - `3. 先執行1再執行2`：先執行選項 `1` 輸出完整鄰居清單，再直接沿用該次掃描名單無縫執行選項 `2` 活躍度排行
     - `4. 檢查並更新`：強制透過 IPv6 / IPv4 自動容錯連線 GitHub 拉取最新版本的 `nat.sh` 並自動覆蓋更新
     - `5. 刪除`：移除 `/usr/local/bin/nat` 全局快捷指令與本地腳本
   - 同時支援命令列快捷參數（`nat 1` / `nat -q`、`nat 2` / `nat --active`、`nat 3` / `nat --both`、`nat 4` / `nat -u`、`nat 5` / `nat --uninstall`）免菜單直接執行。

2. **跨環境通用性（KVM / LXC / 多系統相容）**：
   - 自動偵測預設路由網卡（相容 `eth0`、`ens18`、`enp0s3` 及 LXC 的 `eth0@if...` 格式）、內網網段、預設網關與公網出口 IPv4，不硬編碼特定網段（如 `192.168.30.x`）。
   - 自動檢測系統 `ping` 對小數秒間隔（`-i 0.1`）的支援度；若遇非 root 權限或精簡版 BusyBox（如 Alpine LXC），自動降級採樣間隔，確保腳本不報錯中斷。
   - 外網基準節點自動從 `168.95.1.1`（台灣 HiNet）、`1.1.1.1`（Cloudflare）、`8.8.8.8`（Google）中實測選取最低延遲節點，適配全球不同地區的 NAT 機房。

3. **真實買家識別邏輯（排除老闆 / 母雞 / 探針節點）**：
   - **網關排除**：自動排除 `ip route` 預設網關、ARP `router` 標記節點及 `.1` / `.254` 網段邊界位。
   - **MAC 位址特徵分群（LAA vs OUI）**：
     - 識別面板自動開通的 **本地隨機管理 MAC（LAA，第一字節第二碼為 `2 / 6 / a / e`）** 與母雞後台手動建立的 **虛擬化原生 OUI（如 Proxmox VE `bc:24:11`、QEMU `52:54:00`、Xen/LXC `00:16:3e`）**。
     - 當本機或網段買家群聚採用 LAA 隨機 MAC 時，凡帶有網關相同 OUI 或原生虛擬化固定 OUI 的節點（如老闆在 PVE 手動開的測試機、軟路由、探針機 `.100` / `.102`），一律歸入「母雞 / 老闆 / 系統節點」單獨列出，不計入真實買家鄰居數。
   - **禁 Ping 鄰居捕捉**：結合併發 Ping 觸發與 `ip neigh` 二層 `lladdr` 狀態，即使鄰居開啟防火牆阻擋 ICMP，只要二層 ARP 存活即納入真實買家統計（標記為 `🛡️ 禁Ping(ARP在線)`）。

4. **檔案格式與維護約定**：
   - 倉庫內所有 Shell 腳本（`*.sh`）必須保持 **UTF-8 無 BOM** 與 **LF（`\n`）** 換行符（由 [`.gitattributes`](.gitattributes) 強制約束，並在自安裝流程中透過 `tr -d '\r'` 保底過濾），防止從 Windows 提交至 GitHub 後在 Linux 下執行出現 `$'\r': command not found` 錯誤。
   - 每次更新功能或調整判定閾值時，必須同步更新 `nat.sh` 內部的 `VERSION`、本檔案版本表以及 [README.md](README.md) 的變更記錄。
