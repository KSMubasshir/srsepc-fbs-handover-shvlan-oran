#!/usr/bin/env python3
#
# mobmon: Near-RT RIC xApp that subscribes to the E2SM-MOB service model on
# every connected E2 node and logs the handover KPIs it reports.
#
# Each RIC indication is printed as one JSON line ("kind": "report"), and each
# handover/re-establishment event in it as another ("kind": "event"), so
# `kubectl logs` (and ric-trace.sh) capture them.  The latest report per node
# is also served at GET /mobmon/v1/reports.
#
# Environment:
#   E2MGR_URL      e2mgr REST base (http://service-ricplt-e2mgr-http.ricplt:3800/v1)
#   SUBMGR_URL     submgr REST base (http://service-ricplt-submgr-http.ricplt:8088/ric/v1)
#   APPMGR_URL     appmgr REST base (http://service-ricplt-appmgr-http.ricplt:8080/ric/v1)
#   SERVICE_HOST   this xApp's http service (service-ricxapp-mobmon-http.ricxapp)
#   HTTP_PORT      8080
#   RMR_PORT       4560
#   PERIOD_MS      report period requested from the eNBs (1000)
#   RAN_FUNCTION_ID  E2SM-MOB RAN function id, if e2mgr does not list it (4)
#

import ctypes
import http.server
import json
import os
import sys
import threading
import time

import asn1tools
import requests

HERE = os.path.dirname(os.path.abspath(__file__))
E2MGR_URL = os.environ.get("E2MGR_URL", "http://service-ricplt-e2mgr-http.ricplt:3800/v1")
# submgr serves the subscription REST API on the xapp-frame default port 8088,
# which its headless service does not list; the headless name resolves to the
# pod, so the port can be used directly.
SUBMGR_URL = os.environ.get("SUBMGR_URL", "http://service-ricplt-submgr-http.ricplt:8088/ric/v1")
APPMGR_URL = os.environ.get("APPMGR_URL", "http://service-ricplt-appmgr-http.ricplt:8080/ric/v1")
SERVICE_HOST = os.environ.get("SERVICE_HOST", "service-ricxapp-mobmon-http.ricxapp")
HTTP_PORT = int(os.environ.get("HTTP_PORT", "8080"))
RMR_PORT = int(os.environ.get("RMR_PORT", "4560"))
PERIOD_MS = int(os.environ.get("PERIOD_MS", "1000"))
RAN_FUNCTION_ID = int(os.environ.get("RAN_FUNCTION_ID", "4"))
MOB_OID = "1.3.6.1.4.1.53148.1.1.2.102"

RIC_INDICATION = 12050
PROC_RIC_INDICATION = 5
IE_RIC_REQUEST_ID = 29
IE_RAN_FUNCTION_ID = 5
IE_RIC_ACTION_ID = 15
IE_RIC_INDICATION_SN = 27
IE_RIC_INDICATION_HEADER = 25
IE_RIC_INDICATION_MESSAGE = 26

e2ap = asn1tools.compile_files(os.path.join(HERE, "e2ap-envelope.asn1"), "per")
mob = asn1tools.compile_files(os.path.join(HERE, "e2sm-mob-v01.00.asn1"), "per")

lock = threading.Lock()
subscriptions = {}  # meid -> SubscriptionId
latest = {}  # meid -> last report
next_instance = [1]


def log(kind, **fields):
    print(json.dumps(dict(kind=kind, time=round(time.time(), 3), **fields)), flush=True)


def rsrp_dbm(v):
    return None if v is None else v - 140


def rsrq_db(v):
    return None if v is None else v / 2 - 20


def meas(m):
    return {"pci": m["pci"], "rsrpDbm": rsrp_dbm(m.get("rsrp")), "rsrqDb": rsrq_db(m.get("rsrq"))}


def ratio(num, den):
    return round(num / den, 4) if den else None


def kpis(c):
    """Rates derived from the cumulative counters."""
    return {
        "s1OutPrepSuccessRate": ratio(c["s1OutPrepSuccess"], c["s1OutAttempt"]),
        "s1OutSuccessRate": ratio(c["s1OutSuccess"], c["s1OutAttempt"]),
        "s1OutExecSuccessRate": ratio(c["s1OutSuccess"], c["s1OutPrepSuccess"]),
        "s1InPrepSuccessRate": ratio(c["s1InPrepSuccess"], c["s1InAttempt"]),
        "s1InSuccessRate": ratio(c["s1InSuccess"], c["s1InAttempt"]),
        "reestSuccessRate": ratio(c["reestSuccess"], c["reestAttempt"]),
    }


def decode_indication(payload):
    pdu = e2ap.decode("E2AP-PDU", payload)
    if pdu[0] != "initiatingMessage" or pdu[1]["procedureCode"] != PROC_RIC_INDICATION:
        return None
    ies = {ie["id"]: ie["value"] for ie in e2ap.decode("ProtocolIEMessage", pdu[1]["value"])["protocolIEs"]}
    ind = {
        "ranFunctionId": e2ap.decode("RANfunctionID", ies[IE_RAN_FUNCTION_ID]),
        "requestId": e2ap.decode("RICrequestID", ies[IE_RIC_REQUEST_ID]),
        "actionId": e2ap.decode("RICactionID", ies[IE_RIC_ACTION_ID]),
    }
    if IE_RIC_INDICATION_SN in ies:
        ind["sn"] = e2ap.decode("RICindicationSN", ies[IE_RIC_INDICATION_SN])
    header = mob.decode("E2SM-Mob-IndicationHeader", e2ap.decode("OctetString", ies[IE_RIC_INDICATION_HEADER]))
    msg = mob.decode("E2SM-Mob-IndicationMessage", e2ap.decode("OctetString", ies[IE_RIC_INDICATION_MESSAGE]))
    return ind, header, msg


def handle_indication(meid, payload):
    try:
        decoded = decode_indication(payload)
    except Exception as e:  # not E2SM-MOB, or malformed
        log("error", meid=meid, error="decode failed: %s" % e, payload=payload.hex())
        return
    if decoded is None:
        return
    ind, header, msg = decoded
    if msg[0] != "mobilityReport":
        return
    r = msg[1]
    enb_time = header["timestampSec"] + header["timestampMs"] / 1000
    ues = []
    for u in r["ueList"]:
        ue = {"rnti": u["rnti"], "rrcState": u["rrcState"], "mobilityState": u["mobilityState"],
              "servingPci": u.get("servingPci")}
        if "lastMeasReport" in u:
            m = u["lastMeasReport"]
            ue["lastMeasReport"] = {"ageMs": m["ageMs"], "nReports": m["nReports"], "measId": m["measId"],
                                    "serving": meas(m["serving"]),
                                    "neighbours": [meas(n) for n in m["neighbours"]]}
        ues.append(ue)
    events = []
    for e in r["eventList"]:
        ev = {"seq": e["seq"], "enbTime": e["timestampSec"] + e["timestampMs"] / 1000, "type": e["eventType"]}
        for k in ("rnti", "sourcePci", "targetPci", "targetEci", "durationMs", "reestCause"):
            if k in e:
                ev[k] = e[k]
        for k in ("servingRsrp", "targetRsrp"):
            if k in e:
                ev[k + "Dbm"] = rsrp_dbm(e[k])
        events.append(ev)
    report = {"meid": meid, "enbId": header["enbId"], "enbTime": enb_time, "sn": ind.get("sn"),
              "cells": r["cellList"], "counters": r["counters"], "kpis": kpis(r["counters"]),
              "ues": ues, "eventsLost": r["eventsLost"]}
    with lock:
        latest[meid] = report
    log("report", **report)
    for ev in events:
        log("event", meid=meid, enbId=header["enbId"], **ev)


class RmrMbuf(ctypes.Structure):
    # Leading, public fields of rmr_mbuf_t (rmr.h); RMR allocates the buffers.
    _fields_ = [("state", ctypes.c_int), ("mtype", ctypes.c_int), ("len", ctypes.c_int),
                ("payload", ctypes.POINTER(ctypes.c_ubyte)), ("xaction", ctypes.POINTER(ctypes.c_ubyte)),
                ("sub_id", ctypes.c_int), ("tp_state", ctypes.c_int)]


RMR_OK = 0
RMR_MAX_MEID = 32
RMR_MAX_RCV_BYTES = 65536


def rmr_loop():
    lib = ctypes.CDLL("librmr_si.so")
    lib.rmr_init.restype = ctypes.c_void_p
    lib.rmr_init.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.c_int]
    lib.rmr_alloc_msg.restype = ctypes.POINTER(RmrMbuf)
    lib.rmr_alloc_msg.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.rmr_torcv_msg.restype = ctypes.POINTER(RmrMbuf)
    lib.rmr_torcv_msg.argtypes = [ctypes.c_void_p, ctypes.POINTER(RmrMbuf), ctypes.c_int]
    lib.rmr_get_meid.restype = ctypes.c_char_p
    lib.rmr_get_meid.argtypes = [ctypes.POINTER(RmrMbuf), ctypes.c_char_p]

    port = ("tcp:%d" % RMR_PORT).encode()
    mrc = lib.rmr_init(port, RMR_MAX_RCV_BYTES, 0)
    while not mrc:
        time.sleep(1)
        mrc = lib.rmr_init(port, RMR_MAX_RCV_BYTES, 0)
    log("info", msg="rmr listening on %d" % RMR_PORT)
    sbuf = lib.rmr_alloc_msg(mrc, RMR_MAX_RCV_BYTES)
    meid = ctypes.create_string_buffer(RMR_MAX_MEID + 1)
    while True:
        sbuf = lib.rmr_torcv_msg(mrc, sbuf, 1000)
        m = sbuf.contents
        if m.state != RMR_OK or m.mtype != RIC_INDICATION:
            continue
        lib.rmr_get_meid(sbuf, meid)
        handle_indication(meid.value.decode(errors="replace"), ctypes.string_at(m.payload, m.len))


class Handler(http.server.BaseHTTPRequestHandler):
    def _reply(self, code, body=None):
        data = json.dumps(body).encode() if body is not None else b""
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.startswith("/ric/v1/health"):
            self._reply(200, {})
        elif self.path.startswith("/mobmon/v1/reports"):
            with lock:
                self._reply(200, latest)
        else:
            self._reply(404, {})

    def do_POST(self):
        # submgr subscription notifications
        n = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(n) if n else b""
        try:
            body = json.loads(body)
        except ValueError:
            body = body.decode(errors="replace")
        log("notification", path=self.path, body=body)
        self._reply(200, {})

    def log_message(self, *args):
        pass


def register():
    """Register with appmgr so rtmgr routes subscription traffic to us."""
    config = json.load(open(os.path.join(HERE, "config-file.json")))
    req = {"appName": "mobmon", "appVersion": config["version"], "configPath": "",
           "appInstanceName": "mobmon",
           "httpEndpoint": "%s:%d" % (SERVICE_HOST, HTTP_PORT),
           "rmrEndpoint": "%s:%d" % (SERVICE_HOST.replace("-http", "-rmr"), RMR_PORT),
           "config": json.dumps(config)}
    try:
        r = requests.post(APPMGR_URL + "/register", json=req, timeout=5)
        log("info", msg="appmgr register: %d %s" % (r.status_code, r.text.strip()))
    except requests.RequestException as e:
        log("warning", msg="appmgr register failed: %s" % e)


def ran_function_id(node):
    """E2SM-MOB's RAN function id on this node, if e2mgr lists RAN functions."""
    def walk(o):
        if isinstance(o, dict):
            if o.get("ranFunctionOid") == MOB_OID and "ranFunctionId" in o:
                return o["ranFunctionId"]
            o = list(o.values())
        if isinstance(o, list):
            for v in o:
                found = walk(v)
                if found is not None:
                    return found
        return None
    found = walk(node)
    return RAN_FUNCTION_ID if found is None else found


def subscribe(meid, node):
    trigger = list(mob.encode("E2SM-Mob-EventTriggerDefinition",
                              ("periodDefinition", {"period": PERIOD_MS})))
    action = list(mob.encode("E2SM-Mob-ActionDefinition", {"actionType": "mobilityReport"}))
    with lock:
        instance = next_instance[0]
        next_instance[0] += 1
    req = {
        "ClientEndpoint": {"Host": SERVICE_HOST, "HTTPPort": HTTP_PORT, "RMRPort": RMR_PORT},
        "Meid": meid,
        "RANFunctionID": ran_function_id(node),
        "SubscriptionDetails": [{
            "XappEventInstanceId": instance,
            "EventTriggers": trigger,
            "ActionToBeSetupList": [{
                "ActionID": 1,
                "ActionType": "report",
                "ActionDefinition": action,
                "SubsequentAction": {"SubsequentActionType": "continue", "TimeToWait": "zero"},
            }],
        }],
    }
    r = requests.post(SUBMGR_URL + "/subscriptions", json=req, timeout=10)
    log("subscribe", meid=meid, ranFunctionId=req["RANFunctionID"], status=r.status_code, response=r.text.strip())
    if r.status_code in (200, 201):
        return r.json().get("SubscriptionId")
    return None


def node_loop():
    while True:
        try:
            states = requests.get(E2MGR_URL + "/nodeb/states", timeout=5).json()
            connected = {s["inventoryName"] for s in states if s.get("connectionStatus") == "CONNECTED"}
            for meid in list(subscriptions):
                if meid not in connected:
                    # The eNB drops its subscriptions when it reconnects.
                    log("info", msg="%s disconnected; will resubscribe" % meid)
                    del subscriptions[meid]
            for meid in sorted(connected - set(subscriptions)):
                node = requests.get(E2MGR_URL + "/nodeb/" + meid, timeout=5).json()
                sub_id = subscribe(meid, node)
                if sub_id:
                    subscriptions[meid] = sub_id
        except (requests.RequestException, ValueError, KeyError) as e:
            log("warning", msg="node poll failed: %s" % e)
        time.sleep(10)


def main():
    server = http.server.ThreadingHTTPServer(("0.0.0.0", HTTP_PORT), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    threading.Thread(target=rmr_loop, daemon=True).start()
    register()
    node_loop()


if __name__ == "__main__":
    sys.exit(main())
