import socket, base64, os, struct, json, sys, uuid, time

host, port, path = "127.0.0.1", 18765, "/chat"

def ws_connect():
    s = socket.create_connection((host, port), timeout=5)
    key = base64.b64encode(os.urandom(16)).decode()
    s.send((f"GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\n"
            f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
    assert "101" in s.recv(4096).decode(errors="replace").split("\r\n")[0]
    return s

def send_text(sock, text):
    p = text.encode(); h = bytearray([0x81]); m = os.urandom(4); ln = len(p)
    if ln < 126: h.append(0x80|ln)
    elif ln < 65536: h.append(0x80|126); h += struct.pack(">H", ln)
    else: h.append(0x80|127); h += struct.pack(">Q", ln)
    h += m
    sock.send(bytes(h) + bytes(b^m[i%4] for i,b in enumerate(p)))

def recv_frame(sock, timeout=6):
    sock.settimeout(timeout)
    try:
        b0 = sock.recv(1)
        if not b0: return None
        b1 = sock.recv(1)[0]; ln = b1 & 0x7F
        if ln == 126: ln = struct.unpack(">H", sock.recv(2))[0]
        elif ln == 127: ln = struct.unpack(">Q", sock.recv(8))[0]
        d = b""
        while len(d) < ln:
            c = sock.recv(ln-len(d))
            if not c: break
            d += c
        return d
    except socket.timeout:
        return None

s = ws_connect()
send_text(s, json.dumps({"type":"resume","sessionId":None,"lastRevision":None}))
for _ in range(5):
    f = recv_frame(s, 6)
    if f is None: break
    j = json.loads(f.decode(errors="replace"))
    if j.get("type") == "panel_state":
        snap = j.get("snapshot") or {}
        comp = snap.get("composer") or {}
        print(f"initial sessionId={j.get('sessionId')} status={snap.get('status')!r} "
              f"composer.cli={comp.get('cli')!r} composer.modelID={comp.get('modelID')!r} "
              f"caps={len(snap.get('capabilities',[]))} msgs={len(snap.get('messages',[]))}")
        break

cid_set = str(uuid.uuid4()); cid_send = str(uuid.uuid4())
send_text(s, json.dumps({"type":"command","commandId":cid_set,"op":"composerSet","args":{"text":"自动化测试消息"}}))
time.sleep(0.4)
send_text(s, json.dumps({"type":"command","commandId":cid_send,"op":"composerSend","args":{}}))
print(f"composerSet cid={cid_set[:8]}  composerSend cid={cid_send[:8]}")

for i in range(16):
    f = recv_frame(s, 6)
    if f is None:
        print(f"  [{i}] <timeout>"); break
    j = json.loads(f.decode(errors="replace"))
    t = j.get("type")
    if t == "command_ack":
        cid = str(j.get("commandId","")).lower()[:8]
        which = "composerSet" if cid == cid_set.lower()[:8] else ("composerSend" if cid == cid_send.lower()[:8] else "?")
        print(f"  command_ack [{which}] status={j.get('status')!r} message={j.get('message')!r}")
    elif t == "panel_state":
        b = j.get("snapshot") or j.get("patch") or {}
        m = b.get("messages")
        last = m[-1] if m else None
        print(f"  panel_state kind={j.get('kind')} rev={j.get('revision')} "
              f"messages={len(m) if m is not None else 'unchanged'}"
              + (f" last.kind={last.get('kind')!r} text={str(last.get('text',''))[:40]!r}" if last else ""))
    else:
        print(f"  [{i}] {t} status={j.get('status')!r} message={str(j.get('message',''))[:60]!r}")
s.close()
