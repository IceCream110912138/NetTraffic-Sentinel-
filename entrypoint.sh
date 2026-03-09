#!/bin/bash
# entrypoint.sh
# 启动前禁用网卡 Offload 特性，确保 libpcap/raw socket 能抓到完整的每一个 IP 包。
#
# 【为什么需要禁用 Offload？】
# 现代网卡支持 TSO/GSO/GRO/LRO 等卸载特性：
#   - TSO（TX Segmentation Offload）：发送时让网卡把大块数据拆成小包，CPU 只提交一次
#   - GRO（Generic Receive Offload）：接收时内核把多个小包聚合成一个大包再送给应用
#   - LRO（Large Receive Offload）：类似 GRO，但在网卡硬件层面完成
#
# 这些特性会导致 raw socket/libpcap 抓到的"包"与实际网络上传输的包不一致：
#   - 收到 100 个 1460B 的 TCP 段 → GRO 聚合为 1 个 ~146KB 的超大帧
#   - 发送 1 个 10MB 数据块 → TSO 拆成 ~7000 个 1460B 包发出，但抓包只看到 1 个
#
# 在某些内核/网卡组合下，这会导致统计结果偏低 30%~70%。
# 禁用后，每个 IP 报文都会独立经过协议栈，统计更准确。
#
# 注意：禁用 Offload 会略微增加 CPU 占用（通常 < 5%），对 NAS 影响可忽略。

IFACE="${MONITOR_IFACE:-eth0}"

# ── 方案1：通过 ethtool 禁用 offload（最可靠）────────────────────────────────
if command -v ethtool &> /dev/null; then
    echo "[entrypoint] Disabling NIC offload features on ${IFACE} via ethtool..."
    ethtool -K "${IFACE}" gro off    2>/dev/null && echo "  GRO  -> off" || echo "  GRO  -> not supported (skip)"
    ethtool -K "${IFACE}" lro off    2>/dev/null && echo "  LRO  -> off" || echo "  LRO  -> not supported (skip)"
    ethtool -K "${IFACE}" tso off    2>/dev/null && echo "  TSO  -> off" || echo "  TSO  -> not supported (skip)"
    ethtool -K "${IFACE}" gso off    2>/dev/null && echo "  GSO  -> off" || echo "  GSO  -> not supported (skip)"
    ethtool -K "${IFACE}" rx-gro-hw off 2>/dev/null || true
    echo "[entrypoint] Offload settings applied via ethtool."
else
    # ── 方案2：ethtool 不可用时，通过 /sys 接口尝试禁用 GRO ────────────────
    echo "[entrypoint] WARNING: ethtool not found, attempting /sys fallback..."
    GRO_TIMEOUT_PATH="/sys/class/net/${IFACE}/gro_flush_timeout"
    GRO_LIST_PATH="/sys/class/net/${IFACE}/napi_defer_hard_irqs"
    if [ -w "${GRO_TIMEOUT_PATH}" ]; then
        echo 0 > "${GRO_TIMEOUT_PATH}"
        echo "[entrypoint] /sys fallback: gro_flush_timeout set to 0 (GRO disabled)"
    else
        echo "[entrypoint] WARNING: /sys fallback also unavailable for ${IFACE}."
        echo "[entrypoint] WARNING: GRO/LRO/TSO may still be ENABLED."
        echo "[entrypoint] WARNING: Traffic statistics may be undercounted by 30-70%!"
        echo "[entrypoint] WARNING: Install ethtool in the image to fix this:"
        echo "[entrypoint] WARNING:   apt-get install -y ethtool"
    fi
fi

# 尝试调大内核全局的 socket 接收缓冲区上限至 128MB
# docker-compose.yml 的 sysctls 通常已设置此值，此处作为双重保障
if [ -w /proc/sys/net/core/rmem_max ]; then
    echo 134217728 > /proc/sys/net/core/rmem_max
    echo 134217728 > /proc/sys/net/core/rmem_default 2>/dev/null || true
    echo "[entrypoint] net.core.rmem_max set to 128MB"
else
    echo "[entrypoint] WARNING: Cannot write /proc/sys/net/core/rmem_max."
    echo "[entrypoint] WARNING: Add 'sysctls: [net.core.rmem_max=134217728]' to docker-compose.yml"
fi

echo "[entrypoint] Starting NetTraffic-Sentinel..."
exec python app.py
