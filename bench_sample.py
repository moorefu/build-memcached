#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""基准采样: 在 <duration> 秒内统计 memcached 某项 stats 计数器的平均变化速率。

Usage: bench_sample.py <port> <duration-seconds> <stat-name>
输出: 一个整数 (ops/s)
"""
import socket
import sys
import time


def read_stat(port, key):
    s = socket.create_connection(('127.0.0.1', port), 10)
    s.settimeout(10)
    try:
        s.sendall(b'stats\r\n')
        buf = b''
        while b'\r\nEND\r\n' not in buf:
            chunk = s.recv(65536)
            if not chunk:
                raise IOError('connection closed')
            buf += chunk
    finally:
        s.close()
    for line in buf.decode('ascii', 'replace').split('\r\n'):
        parts = line.split(' ')
        if len(parts) == 3 and parts[0] == 'STAT' and parts[1] == key:
            return int(parts[2])
    raise SystemExit('stat %s not found' % key)


def main():
    port = int(sys.argv[1])
    duration = float(sys.argv[2])
    key = sys.argv[3]
    one, t0 = read_stat(port, key), time.time()
    time.sleep(duration)
    two, t1 = read_stat(port, key), time.time()
    print(int((two - one) / (t1 - t0)))


if __name__ == '__main__':
    main()
