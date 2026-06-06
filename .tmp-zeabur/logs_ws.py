#!/usr/bin/env python3
"""Subscribe to Zeabur runtime + build logs via GraphQL WS."""
import json, sys, time, threading, websocket

TOKEN = "sk-zhw6hjoambkyva6hudyt3twsijjmz"
SVC = "6a1fb1a48197c9aa0ae31d35"

URL = "wss://api.zeabur.com/graphql"
HEADERS = [f"Authorization: Bearer {TOKEN}"]

done = threading.Event()
got_runtime = []
got_build = []

def on_open(ws):
    ws.send(json.dumps({"type":"connection_init","payload":{}}))

def on_message(ws, msg):
    try:
        data = json.loads(msg)
    except Exception:
        return
    t = data.get("type")
    if t == "connection_ack":
        ws.send(json.dumps({
            "id":"1","type":"start",
            "payload":{
                "query":"subscription($sid:ObjectID!){ runtimeLogs(serviceID:$sid){ time data } }",
                "variables":{"sid":SVC}
            }
        }))
        ws.send(json.dumps({
            "id":"2","type":"start",
            "payload":{
                "query":"subscription($sid:ObjectID!){ buildLogs(serviceID:$sid){ time data } }",
                "variables":{"sid":SVC}
            }
        }))
    elif t == "data":
        payload = data.get("payload",{}).get("data") or {}
        sid = data.get("id")
        key = "runtimeLogs" if sid=="1" else "buildLogs"
        items = payload.get(key) or []
        for it in items:
            (got_runtime if sid=="1" else got_build).append(it)
    elif t == "error":
        print("ERROR:", data, file=sys.stderr)
    elif t == "complete":
        pass

def on_error(ws, e):
    print("WS_ERR:", e, file=sys.stderr)

def on_close(ws, code, reason):
    done.set()

ws = websocket.WebSocketApp(URL, header=HEADERS,
                            subprotocols=["graphql-transport-ws"],
                            on_open=on_open, on_message=on_message,
                            on_error=on_error, on_close=on_close)
t = threading.Thread(target=ws.run_forever, daemon=True)
t.start()
time.sleep(20)
ws.close()
done.wait(3)
print("=== RUNTIME LOGS ===")
for it in got_runtime[-100:]:
    print(it.get("time"), "-", it.get("data","").rstrip())
print("=== BUILD LOGS ===")
for it in got_build[-100:]:
    print(it.get("time"), "-", it.get("data","").rstrip())
