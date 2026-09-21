#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""memcached 构建冒烟测试客户端 (Linux/Windows 共用, python2/3 兼容)。

由 smoke-test.sh 调用, 对已启动的实例按模式做协议级断言:
  text      ASCII 协议全套操作 + 二进制协议 + 大 value 边界 (普通实例)
  eviction  LRU 逐出触发断言 (小内存实例)
  tls       TLS 连接上的 set/get/version (TLS 实例)
  sasl      SASL PLAIN 三断言: 机制内置 / 正确密码 / 错误密码 (SASL 实例)
  basic     基本设置/获取/删除 (seccomp 沙箱实例)

Usage: smoke_test.py <mode> <host> <port>
"""
import socket
import ssl
import struct
import sys
import time


class SmokeError(Exception):
    pass


def check(cond, msg):
    if not cond:
        raise SmokeError(msg)


def recv_line(s):
    """读一行 (\r\n 结尾, 返回时不带 \r\n)。逐字节读以兼容 SSL 套接字。"""
    buf = b''
    while not buf.endswith(b'\r\n'):
        c = s.recv(1)
        if not c:
            raise SmokeError('等待响应时连接被关闭, 已收到: %r' % buf)
        buf += c
    return buf[:-2]


def recv_exact(s, n):
    buf = b''
    while len(buf) < n:
        c = s.recv(n - len(buf))
        if not c:
            raise SmokeError('等待 %d 字节时连接被关闭' % n)
        buf += c
    return buf


def connect(host, port):
    return socket.create_connection((host, port), 5)


# ---------- ASCII 协议 helper ----------

def store(s, op, key, val, exptime=0, cas=None):
    """执行 set/add/replace/append/prepend/cas, 返回第一响应行。"""
    if cas is None:
        line = '%s %s 0 %d %d\r\n' % (op, key, exptime, len(val))
    else:
        line = '%s %s 0 %d %d %d\r\n' % (op, key, exptime, len(val), cas)
    s.sendall(line.encode('ascii') + val + b'\r\n')
    return recv_line(s)


def fetch(s, key, cmd='get'):
    """get/gets, 返回 (value, cas); miss 返回 None。"""
    s.sendall(('%s %s\r\n' % (cmd, key)).encode('ascii'))
    line = recv_line(s)
    if line == b'END':
        return None
    parts = line.split(b' ')
    check(parts[0] == b'VALUE', '%s 响应异常: %r' % (cmd, line))
    n = int(parts[3])
    buf = recv_exact(s, n + 2)
    check(buf[n:] == b'\r\n', 'value 末尾缺少 CRLF')
    check(recv_line(s) == b'END', '%s 缺少 END 结束行' % cmd)
    cas = parts[4] if len(parts) > 4 else None
    return (buf[:n], cas)


def simple(s, line):
    """发送单行命令, 返回单行响应。"""
    s.sendall(line.encode('ascii') + b'\r\n')
    return recv_line(s)


# ---------- 二进制协议 helper ----------

def bin_send(s, opcode, key=b'', val=b'', extra=b''):
    total = len(key) + len(extra) + len(val)
    hdr = struct.pack('!BBHBBHIIQ', 0x80, opcode, len(key), len(extra), 0, 0,
                      total, 0, 0)
    s.sendall(hdr + extra + key + val)


def bin_recv(s):
    hdr = recv_exact(s, 24)
    magic, op, keyl, extl, dtype, status, rest, opaque, cas = \
        struct.unpack('!BBHBBHIIQ', hdr)
    body = recv_exact(s, rest)
    return status, body


# ---------- 各模式 ----------

def mode_text(host, port):
    # version
    s = connect(host, port)
    check(simple(s, 'version').startswith(b'VERSION '), 'version 命令响应异常')
    s.close()

    # set/get/add/replace/append/prepend
    s = connect(host, port)
    check(store(s, 'set', 'sm:foo', b'bar') == b'STORED', 'set 失败')
    check(fetch(s, 'sm:foo')[0] == b'bar', 'get 取回值不符')
    check(store(s, 'add', 'sm:foo', b'xx') == b'NOT_STORED', 'add 不应覆盖已存在的 key')
    check(store(s, 'add', 'sm:new', b'yy') == b'STORED', 'add 新 key 失败')
    check(store(s, 'replace', 'sm:none', b'zz') == b'NOT_STORED', 'replace 不应创建不存在的 key')
    check(store(s, 'replace', 'sm:foo', b'bar') == b'STORED', 'replace 已存在 key 失败')
    check(store(s, 'append', 'sm:foo', b'BA') == b'STORED', 'append 失败')
    check(store(s, 'prepend', 'sm:foo', b'PRE') == b'STORED', 'prepend 失败')
    check(fetch(s, 'sm:foo')[0] == b'PREbarBA', 'append/prepend 后取值不符')

    # gets + cas
    _, cas = fetch(s, 'sm:foo', 'gets')
    check(cas is not None and int(cas) > 0, 'gets 未返回 cas 值')
    check(store(s, 'cas', 'sm:foo', b'new', cas=int(cas)) == b'STORED', 'cas 正确版本应 STORED')
    check(store(s, 'cas', 'sm:foo', b'bad', cas=int(cas)) == b'EXISTS', 'cas 过期版本应 EXISTS')

    # delete
    check(simple(s, 'delete sm:new') == b'DELETED', 'delete 失败')
    check(simple(s, 'delete sm:new') == b'NOT_FOUND', '删除不存在的 key 应 NOT_FOUND')

    # incr/decr
    check(store(s, 'set', 'sm:num', b'5') == b'STORED', '写入数字 key 失败')
    check(simple(s, 'incr sm:num 3') == b'8', 'incr 计算错误')
    check(simple(s, 'decr sm:num 2') == b'6', 'decr 计算错误')

    # touch
    check(simple(s, 'touch sm:num 100') == b'TOUCHED', 'touch 失败')
    check(simple(s, 'touch sm:none 100') == b'NOT_FOUND', 'touch 不存在的 key 应 NOT_FOUND')

    # stats
    s.sendall(b'stats\r\n')
    saw_stat = False
    while True:
        line = recv_line(s)
        if line == b'END':
            break
        if line.startswith(b'STAT '):
            saw_stat = True
    check(saw_stat, 'stats 未返回 STAT 行')

    # TTL 过期
    check(store(s, 'set', 'sm:ttl', b'gone', exptime=1) == b'STORED', '写入 TTL key 失败')
    check(fetch(s, 'sm:ttl') is not None, 'TTL key 写入后应立即可读')
    time.sleep(1.5)
    check(fetch(s, 'sm:ttl') is None, 'TTL 过期后值未被回收')
    s.close()

    # flush_all
    s = connect(host, port)
    check(store(s, 'set', 'sm:fl', b'x') == b'STORED', 'flush 前写入失败')
    check(simple(s, 'flush_all') == b'OK', 'flush_all 失败')
    check(fetch(s, 'sm:fl') is None, 'flush_all 后值仍存在')
    s.close()

    # 大 value 边界: 默认 1MB item 上限
    s = connect(host, port)
    big = b'B' * 1000000
    check(store(s, 'set', 'sm:big', big) == b'STORED', '1MB 级大 value 写入失败')
    check(fetch(s, 'sm:big')[0] == big, '大 value 取回不一致')
    try:
        resp = store(s, 'set', 'sm:toobig', b'B' * (1048576 + 1024))
    except SmokeError:
        resp = b'<server closed>'  # 超限时服务端可能直接断连, 同样视为拒绝
    check(resp != b'STORED', '超过 1MB 的 value 不应被接受, 响应: %r' % resp)
    s.close()

    # 二进制协议 set/get/delete (SET 需带 8 字节 extras: flags+expiry)
    s = connect(host, port)
    bin_send(s, 0x01, b'sm:bin', b'binval', extra=struct.pack('!II', 0, 0))  # SET
    status, _ = bin_recv(s)
    check(status == 0, '二进制协议 set 失败, status=%d' % status)
    bin_send(s, 0x00, b'sm:bin')  # GET
    status, body = bin_recv(s)
    check(status == 0 and body.endswith(b'binval'), '二进制协议 get 失败, status=%d' % status)
    bin_send(s, 0x04, b'sm:bin')  # DELETE
    status, _ = bin_recv(s)
    check(status == 0, '二进制协议 delete 失败, status=%d' % status)
    s.close()


def mode_eviction(host, port):
    """向小内存实例灌固定大小 value, 断言 LRU 逐出计数增长。"""
    s = connect(host, port)
    val = b'x' * 1024
    evictions = 0
    for i in range(200000):
        resp = store(s, 'set', 'ev%08d' % i, val)
        check(resp == b'STORED', '灌数据 set 失败: %r' % resp)
        if i % 1000 == 999:
            s.sendall(b'stats\r\n')
            while True:
                line = recv_line(s)
                if line == b'END':
                    break
                if line.startswith(b'STAT evictions '):
                    evictions = int(line.split(b' ')[2])
            if evictions > 0:
                break
    check(evictions > 0, '灌入大量 key 后 evictions 仍为 0, LRU 逐出未生效')
    s.close()


def mode_tls(host, port):
    raw = connect(host, port)
    try:
        proto = getattr(ssl, 'PROTOCOL_TLS', None)
        if proto is None:
            proto = ssl.PROTOCOL_SSLv23
        ctx = ssl.SSLContext(proto)
        ctx.verify_mode = ssl.CERT_NONE  # 自签测试证书, 免校验
        s = ctx.wrap_socket(raw)
    except AttributeError:
        # 极老 python2 无 SSLContext, 退回 wrap_socket
        s = ssl.wrap_socket(raw)
    check(store(s, 'set', 'sm:tls', b'secret') == b'STORED', 'TLS 连接上 set 失败')
    check(fetch(s, 'sm:tls')[0] == b'secret', 'TLS 连接上 get 取回值不符')
    check(simple(s, 'version').startswith(b'VERSION '), 'TLS 连接上 version 响应异常')
    s.close()


def mode_sasl(host, port):
    # 1) 机制列表必须包含静态编入的 PLAIN
    s = connect(host, port)
    bin_send(s, 0x20)  # SASL_LIST_MECHS
    status, body = bin_recv(s)
    check(status == 0, 'list mechanisms 失败, status=%d' % status)
    check(b'PLAIN' in body.split(), 'PLAIN 机制缺失(静态编入失败): %r' % body)
    s.close()

    # 2) 正确密码必须通过
    s = connect(host, port)
    bin_send(s, 0x21, b'PLAIN', b'\x00testuser\x00testpass')  # SASL_AUTH
    status, _ = bin_recv(s)
    check(status == 0, '正确密码 PLAIN 认证失败, status=%d' % status)
    s.close()

    # 3) 错误密码必须被拒
    s = connect(host, port)
    bin_send(s, 0x21, b'PLAIN', b'\x00testuser\x00wrongpass')
    status, _ = bin_recv(s)
    check(status != 0, '错误密码被接受')
    s.close()


def mode_basic(host, port):
    s = connect(host, port)
    check(simple(s, 'version').startswith(b'VERSION '), 'version 响应异常')
    check(store(s, 'set', 'sm:basic', b'v') == b'STORED', 'set 失败')
    check(fetch(s, 'sm:basic')[0] == b'v', 'get 取回值不符')
    check(simple(s, 'delete sm:basic') == b'DELETED', 'delete 失败')
    s.close()


MODES = {
    'text': mode_text,
    'eviction': mode_eviction,
    'tls': mode_tls,
    'sasl': mode_sasl,
    'basic': mode_basic,
}


def main():
    if len(sys.argv) != 4 or sys.argv[1] not in MODES:
        sys.exit('Usage: %s <text|eviction|tls|sasl|basic> <host> <port>'
                 % sys.argv[0])
    mode = sys.argv[1]
    host, port = sys.argv[2], int(sys.argv[3])
    try:
        MODES[mode](host, port)
    except SmokeError as e:
        sys.exit('FAIL[%s]: %s' % (mode, e))
    print('PASS[%s]' % mode)


if __name__ == '__main__':
    main()
