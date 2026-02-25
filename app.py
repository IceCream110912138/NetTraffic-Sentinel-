#!/usr/bin/env python3
"""
NetTraffic-Sentinel - NAS公网流量监控程序
主程序入口：启动抓包线程、数据库持久化、Web API服务
"""

import os
import sys
import threading
import time
import logging
from capture import PacketCapture
from database import Database
from api import create_app

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(name)s: %(message)s'
)
logger = logging.getLogger('sentinel')


def setup_timezone() -> None:
    """
    显式读取 TZ 环境变量并激活时区。
    - 在 Linux/macOS 容器中调用 time.tzset() 让 C 运行时和 Python
      datetime/time 模块立即切换到 TZ 指定的时区。
    - Windows 不支持 tzset()，跳过即可（开发环境兼容）。
    - 若未设置 TZ，程序沿用容器/系统默认时区（通常为 /etc/localtime 指向的区域）。
    """
    tz = os.environ.get('TZ', '')
    if tz:
        logger.info(f"TZ environment variable detected: {tz}")
        if sys.platform != 'win32':
            time.tzset()          # 通知 C 运行时重新读取 TZ，datetime.now() 立即生效
            logger.info(f"Timezone applied via time.tzset(): {tz}")
        else:
            logger.warning("time.tzset() is not available on Windows; "
                           "TZ env var may not take effect automatically.")
    else:
        logger.info("TZ env var not set; using system default timezone.")

    # 打印实际生效的本地时间，便于日志核验
    from datetime import datetime
    logger.info(f"Current local time (post-tzset): {datetime.now().strftime('%Y-%m-%d %H:%M:%S %Z')}")


# 环境变量配置
MONITOR_IFACE    = os.environ.get('MONITOR_IFACE', 'eth0')
EXCLUDE_IPV6_PREFIX = os.environ.get('EXCLUDE_IPV6_PREFIX', '')
WEB_PORT         = int(os.environ.get('WEB_PORT', '8080'))
SAVE_INTERVAL    = int(os.environ.get('SAVE_INTERVAL', '300'))  # 秒
DB_PATH          = os.environ.get('DB_PATH', '/data/traffic.db')

def persistence_loop(db: Database, capture: PacketCapture, interval: int):
    """定期将内存统计数据刷写到数据库"""
    while True:
        time.sleep(interval)
        try:
            stats = capture.flush_stats()
            db.commit_stats(stats)
            logger.info(f"Stats flushed to DB: {len(stats)} records")
        except Exception as e:
            logger.error(f"Persistence error: {e}")

def main():
    # ── 第一步：激活时区（必须在任何 datetime 调用之前执行）──────────────
    setup_timezone()

    logger.info("="*50)
    logger.info("  NetTraffic-Sentinel starting up")
    logger.info(f"  Interface : {MONITOR_IFACE}")
    logger.info(f"  Web Port  : {WEB_PORT}")
    logger.info(f"  DB Path   : {DB_PATH}")
    logger.info(f"  Save Interval: {SAVE_INTERVAL}s")
    logger.info("="*50)

    # 初始化数据库
    db = Database(DB_PATH)
    db.init_schema()

    # 初始化抓包模块
    ipv6_prefixes = [p.strip() for p in EXCLUDE_IPV6_PREFIX.split(',') if p.strip()]
    capture = PacketCapture(
        iface=MONITOR_IFACE,
        exclude_ipv6_prefixes=ipv6_prefixes
    )

    # 启动抓包线程
    capture_thread = threading.Thread(target=capture.start, daemon=True, name='capture')
    capture_thread.start()
    logger.info("Packet capture thread started")

    # 启动持久化线程
    persist_thread = threading.Thread(
        target=persistence_loop,
        args=(db, capture, SAVE_INTERVAL),
        daemon=True,
        name='persistence'
    )
    persist_thread.start()
    logger.info(f"Persistence thread started (interval={SAVE_INTERVAL}s)")

    # 启动 Web API
    app = create_app(db, capture)
    logger.info(f"Web dashboard available at http://0.0.0.0:{WEB_PORT}")
    app.run(host='0.0.0.0', port=WEB_PORT, debug=False, threaded=True)

if __name__ == '__main__':
    main()
