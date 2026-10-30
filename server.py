"""Huadian question practice app. Python standard library only; local SQLite storage."""
import argparse
import hashlib
import http.client
import json
import mimetypes
import os
import secrets
import shutil
import sqlite3
import threading
import time
import urllib.parse
import urllib.request
import uuid
import webbrowser
from contextlib import contextmanager, closing
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent
BANK = json.loads((ROOT / "bank.json").read_text(encoding="utf-8"))
QUESTIONS = {q["id"]: q for q in BANK["questions"]}
TYPES = ("single", "multiple", "judge")
APP_ID = "huadian-quiz-2026"


class UserError(Exception):
    def __init__(self, message, status=400):
        self.status = status
        super().__init__(message)


def dumps(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def now():
    return datetime.now().astimezone().isoformat(timespec="seconds")


def validate_choice(qid, answer):
    q = QUESTIONS.get(str(qid))
    if q is None:
        raise UserError("没有找到这道题。")
    if not isinstance(answer, list) or any(not isinstance(x, str) for x in answer):
        raise UserError("答案格式不正确。")
    valid = {o["key"] for o in q["options"]}
    if len(set(answer)) != len(answer) or not set(answer).issubset(valid):
        raise UserError("选项不在这道题中。")
    if q["type"] != "multiple" and len(answer) > 1:
        raise UserError("本题只能选择一个选项。")
    return sorted(answer)


class Store:
    def __init__(self, directory):
        self.directory = Path(directory).resolve()
        self.directory.mkdir(parents=True, exist_ok=True)
        self.path = self.directory / "学习记录.sqlite3"
        self.lock = threading.RLock()
        with self.connect() as db:
            db.executescript("""
                PRAGMA journal_mode=WAL;
                PRAGMA synchronous=FULL;
                CREATE TABLE IF NOT EXISTS practice(qid TEXT PRIMARY KEY, answer TEXT NOT NULL,
                    correct INTEGER, updated TEXT NOT NULL, revision INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS exams(id TEXT PRIMARY KEY, type TEXT NOT NULL,
                    status TEXT NOT NULL, ordering TEXT NOT NULL, answers TEXT NOT NULL,
                    current_q TEXT, elapsed REAL NOT NULL DEFAULT 0, last_tick REAL, timer_owner TEXT,
                    created TEXT NOT NULL, updated TEXT NOT NULL, submitted TEXT);
                CREATE UNIQUE INDEX IF NOT EXISTS one_active_exam ON exams(type) WHERE status='active';
                CREATE TABLE IF NOT EXISTS mistakes(id TEXT PRIMARY KEY, source TEXT NOT NULL,
                    qid TEXT NOT NULL, exam_id TEXT, original TEXT NOT NULL, review TEXT NOT NULL DEFAULT '[]',
                    review_correct INTEGER, dismissed INTEGER NOT NULL DEFAULT 0,
                    created TEXT NOT NULL, updated TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS events(id INTEGER PRIMARY KEY AUTOINCREMENT, at TEXT NOT NULL,
                    scope TEXT NOT NULL, qid TEXT, exam_id TEXT, answer TEXT, correct INTEGER);
                CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            """)
            # A process restart pauses all running clocks. Saved elapsed time is retained.
            db.execute("UPDATE exams SET last_tick=NULL,timer_owner=NULL WHERE status='active'")
        self.backup_daily()

    @contextmanager
    def connect(self):
        with self.lock:
            db = sqlite3.connect(self.path, timeout=30)
            db.row_factory = sqlite3.Row
            try:
                with db:
                    yield db
            finally:
                db.close()

    def backup_daily(self):
        folder = self.directory / "自动备份"
        folder.mkdir(exist_ok=True)
        target = folder / (datetime.now().strftime("%Y-%m-%d") + ".sqlite3")
        if not target.exists():
            self.backup(target)

    def backup(self, target):
        with self.connect() as db, closing(sqlite3.connect(target)) as dest:
            db.backup(dest)

    @staticmethod
    def event(db, scope, qid=None, answer=None, correct=None, exam_id=None):
        db.execute("INSERT INTO events(at,scope,qid,exam_id,answer,correct) VALUES(?,?,?,?,?,?)",
                   (now(), scope, qid, exam_id, dumps(answer) if answer is not None else None, correct))

    def practice_map(self, db):
        result = {}
        for row in db.execute("SELECT * FROM practice"):
            answer = json.loads(row["answer"])
            if answer:
                result[row["qid"]] = {"answer": answer, "correct": bool(row["correct"]) if row["correct"] is not None else None,
                                      "correctAnswer": QUESTIONS[row["qid"]]["answer"] if row["correct"] is not None else None, "updated": row["updated"]}
        return result

    def save_practice(self, qid, answer, check=False):
        if not isinstance(check, bool):
            raise UserError("检查答案参数不正确。")
        qid = str(qid)
        answer = validate_choice(qid, answer)
        correct = answer == QUESTIONS[qid]["answer"] if answer else None
        if QUESTIONS[qid]["type"] == "multiple" and not check and correct is not True:
            correct = None
        with self.connect() as db:
            previous = db.execute("SELECT * FROM practice WHERE qid=?", (qid,)).fetchone()
            if previous and json.loads(previous["answer"]) == answer and previous["correct"] == correct:
                return self.practice_map(db).get(qid)
            revision = (previous["revision"] if previous else 0) + 1
            db.execute("INSERT OR REPLACE INTO practice VALUES(?,?,?,?,?)", (qid, dumps(answer), correct, now(), revision))
            if answer and correct is False:
                mid = "practice:" + qid
                db.execute("""INSERT INTO mistakes(id,source,qid,original,created,updated) VALUES(?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET original=excluded.original,review='[]',review_correct=NULL,
                    dismissed=0,updated=excluded.updated""", (mid, "practice", qid, dumps(answer), now(), now()))
            elif not answer or correct is True:
                db.execute("UPDATE mistakes SET dismissed=1,updated=? WHERE id=?", (now(), "practice:" + qid))
            return self.practice_map(db).get(qid)

    @staticmethod
    def exam_info(row, include_answers=False):
        order = json.loads(row["ordering"])
        answers = json.loads(row["answers"])
        submitted = row["status"] == "submitted"
        result = {"id": row["id"], "type": row["type"], "status": row["status"],
                  "currentQ": row["current_q"], "elapsed": row["elapsed"], "created": row["created"],
                  "updated": row["updated"], "submitted": row["submitted"], "total": len(order),
                  "answered": sum(bool(a) for a in answers.values()), "allAnswered": all(answers.get(q) for q in order)}
        if submitted:
            result["correctCount"] = sum(answers.get(q) == QUESTIONS[q]["answer"] for q in order)
            result["wrongCount"] = len(order) - result["correctCount"]
            result["score"] = round(result["correctCount"] / len(order) * 100, 1)
        if include_answers:
            result.update(order=order, answers=answers)
            if submitted:
                result["results"] = {q: {"correct": answers.get(q) == QUESTIONS[q]["answer"],
                                          "correctAnswer": QUESTIONS[q]["answer"]} for q in order}
        return result

    def start_exam(self, kind):
        if kind not in TYPES:
            raise UserError("请选择一种题型。")
        with self.connect() as db:
            row = db.execute("SELECT * FROM exams WHERE type=? AND status='active'", (kind,)).fetchone()
            if row:
                return self.exam_info(row, True)
            order = []
            for group in BANK["groups"]:
                if group["type"] == kind:
                    ids = [q["id"] for q in BANK["questions"] if q["group"] == group["id"]]
                    original = ids[:]
                    secrets.SystemRandom().shuffle(ids)
                    if ids == original and len(ids) > 1:
                        ids = ids[1:] + ids[:1]
                    order.extend(ids)
            eid = uuid.uuid4().hex
            db.execute("INSERT INTO exams(id,type,status,ordering,answers,current_q,created,updated) VALUES(?,?,?,?,?,?,?,?)",
                       (eid, kind, "active", dumps(order), "{}", order[0], now(), now()))
            self.event(db, "exam-start", exam_id=eid)
            return self.exam_info(db.execute("SELECT * FROM exams WHERE id=?", (eid,)).fetchone(), True)

    @staticmethod
    def get_row(db, eid):
        row = db.execute("SELECT * FROM exams WHERE id=?", (eid,)).fetchone()
        if not row:
            raise UserError("找不到这场考试记录。", 404)
        return row

    def exam(self, eid):
        with self.connect() as db:
            return self.exam_info(self.get_row(db, eid), True)

    def delete_exams(self, ids):
        if (not isinstance(ids, list) or not 1 <= len(ids) <= 1000
                or any(not isinstance(eid, str) or not eid or len(eid) > 128 for eid in ids)):
            raise UserError("请选择要删除的考试记录，每次最多 1000 场。")
        ids = list(dict.fromkeys(ids))
        placeholders = ",".join("?" for _ in ids)
        with self.connect() as db:
            count = db.execute(f"SELECT COUNT(*) FROM exams WHERE id IN ({placeholders})", ids).fetchone()[0]
            if count:
                # Keep a recoverable snapshot before the atomic delete, including active exams.
                backup = self.directory / "自动备份" / ("删除考试前-" + datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8] + ".sqlite3")
                self.backup(backup)
                db.execute(f"DELETE FROM mistakes WHERE exam_id IN ({placeholders})", ids)
                db.execute(f"DELETE FROM events WHERE exam_id IN ({placeholders})", ids)
                db.execute(f"DELETE FROM exams WHERE id IN ({placeholders})", ids)
        # Retrying an already completed request is harmless.
        return {"deletedIds": ids, "deletedCount": count}

    def save_exam(self, eid, qid, answer):
        qid = str(qid)
        answer = validate_choice(qid, answer)
        with self.connect() as db:
            row = self.get_row(db, eid)
            if row["status"] != "active":
                raise UserError("这场考试已交卷，答案不能再修改。", 409)
            if qid not in json.loads(row["ordering"]):
                raise UserError("这道题不属于本场考试。")
            answers = json.loads(row["answers"])
            if answers.get(qid, []) != answer:
                if answer:
                    answers[qid] = answer
                else:
                    answers.pop(qid, None)
                db.execute("UPDATE exams SET answers=?,current_q=?,updated=? WHERE id=?", (dumps(answers), qid, now(), eid))
                self.event(db, "exam-answer", qid, answer, exam_id=eid)
            return self.exam_info(self.get_row(db, eid), True)

    def position(self, eid, qid):
        with self.connect() as db:
            row = self.get_row(db, eid)
            if str(qid) not in json.loads(row["ordering"]):
                raise UserError("无效题号。")
            if row["status"] == "active":
                db.execute("UPDATE exams SET current_q=? WHERE id=?", (str(qid), eid))
        return {"ok": True}

    def tick(self, eid, owner, active=True):
        with self.connect() as db:
            row = self.get_row(db, eid)
            elapsed = row["elapsed"]
            if row["status"] != "active":
                return {"elapsed": elapsed, "status": row["status"]}
            stamp = time.time()
            if not active and row["timer_owner"] != owner:
                return {"elapsed": elapsed, "status": "active"}
            if row["last_tick"] is not None:
                elapsed += max(0, min(stamp - row["last_tick"], 15))
            db.execute("UPDATE exams SET elapsed=?,last_tick=?,timer_owner=? WHERE id=?",
                       (elapsed, stamp if active else None, owner if active else None, eid))
            return {"elapsed": elapsed, "status": "active"}

    def submit(self, eid):
        with self.connect() as db:
            row = self.get_row(db, eid)
            if row["status"] == "submitted":
                return self.exam_info(row, True)
            order, answers = json.loads(row["ordering"]), json.loads(row["answers"])
            missing = [q for q in order if not answers.get(q)]
            if missing:
                raise UserError(f"还有 {len(missing)} 道题未作答，请全部作答后再交卷。", 409)
            elapsed = row["elapsed"]
            if row["last_tick"] is not None:
                elapsed += max(0, min(time.time() - row["last_tick"], 15))
            db.execute("UPDATE exams SET status='submitted',submitted=?,updated=?,elapsed=?,last_tick=NULL,timer_owner=NULL WHERE id=?",
                       (now(), now(), elapsed, eid))
            for qid in order:
                if answers[qid] != QUESTIONS[qid]["answer"]:
                    db.execute("INSERT INTO mistakes(id,source,qid,exam_id,original,created,updated) VALUES(?,?,?,?,?,?,?)",
                               ("exam:" + eid + ":" + qid, "exam", qid, eid, dumps(answers[qid]), now(), now()))
            self.event(db, "exam-submit", exam_id=eid)
            return self.exam_info(self.get_row(db, eid), True)

    def mistakes(self, source=None):
        with self.connect() as db:
            result = []
            for row in db.execute("SELECT m.*,e.created AS exam_created FROM mistakes m LEFT JOIN exams e ON m.exam_id=e.id WHERE m.dismissed=0 ORDER BY m.created DESC,m.qid*1"):
                if source and row["source"] != source:
                    continue
                result.append({"id": row["id"], "source": row["source"], "qid": row["qid"],
                               "examId": row["exam_id"], "examCreated": row["exam_created"],
                               "original": json.loads(row["original"]), "review": json.loads(row["review"]),
                               "reviewCorrect": bool(row["review_correct"]) if row["review_correct"] is not None else None,
                               "correctAnswer": QUESTIONS[row["qid"]]["answer"] if row["review_correct"] is not None else None,
                               "created": row["created"], "updated": row["updated"]})
            return result

    def review(self, mid, answer, check=False):
        if not isinstance(check, bool):
            raise UserError("检查答案参数不正确。")
        with self.connect() as db:
            row = db.execute("SELECT * FROM mistakes WHERE id=?", (mid,)).fetchone()
            if not row or row["dismissed"]:
                raise UserError("这条错题已移出错题集，请刷新列表。", 409)
            answer = validate_choice(row["qid"], answer)
            correct = answer == QUESTIONS[row["qid"]]["answer"] if answer else None
            if QUESTIONS[row["qid"]]["type"] == "multiple" and not check:
                correct = None
            setting = db.execute("SELECT value FROM settings WHERE key=?", ("autoRemove:" + row["source"],)).fetchone()
            removed = bool(correct and setting and json.loads(setting["value"]))
            db.execute("UPDATE mistakes SET review=?,review_correct=?,dismissed=?,updated=? WHERE id=?", (dumps(answer), correct, removed, now(), mid))
            return {"answer": answer, "correct": correct, "correctAnswer": QUESTIONS[row["qid"]]["answer"] if correct is not None else None, "removed": removed}

    def settings(self, key=None, value=None):
        with self.connect() as db:
            if key is not None:
                if key not in ("autoRemove:practice", "autoRemove:exam") or not isinstance(value, bool):
                    raise UserError("无效设置。")
                db.execute("INSERT OR REPLACE INTO settings VALUES(?,?)", (key, dumps(value)))
            return {row["key"]: json.loads(row["value"]) for row in db.execute("SELECT * FROM settings")}

    def bootstrap(self):
        with self.connect() as db:
            practice = self.practice_map(db)
            exams = [self.exam_info(r) for r in db.execute("SELECT * FROM exams ORDER BY created DESC,rowid DESC")]
        public_bank = {**BANK, "questions": [{k: v for k, v in q.items() if k != "answer"} for q in BANK["questions"]]}
        return {"bank": public_bank, "practice": practice, "exams": exams,
                "mistakes": self.mistakes(), "settings": self.settings(), "dataPath": str(self.path)}


class Server(ThreadingHTTPServer):
    daemon_threads = True
    def __init__(self, address, store):
        self.store = store
        self.token = secrets.token_urlsafe(32)
        super().__init__(address, Handler)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def respond(self, value, status=200, content_type="application/json; charset=utf-8", extra=None):
        data = dumps(value).encode("utf-8") if content_type.startswith("application/json") else value
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "same-origin")
        self.send_header("Content-Security-Policy", "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self'; img-src 'self' data:; object-src 'self'; frame-ancestors 'none'")
        if extra:
            for k, v in extra.items():
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def host_ok(self):
        host = self.headers.get("Host", "")
        return host in (f"127.0.0.1:{self.server.server_port}", f"localhost:{self.server.server_port}")

    def do_GET(self):
        try:
            if not self.host_ok():
                raise UserError("仅允许从本机访问。", 403)
            url = urllib.parse.urlsplit(self.path)
            path = urllib.parse.unquote(url.path)
            store = self.server.store
            if path == "/api/health":
                return self.respond({"app": APP_ID, "root": str(ROOT), "dataPath": str(store.path)})
            if path == "/api/bootstrap":
                return self.respond({**store.bootstrap(), "token": self.server.token})
            if path == "/api/practice/answers":
                kind = urllib.parse.parse_qs(url.query).get("type", [""])[0]
                if kind not in TYPES:
                    raise UserError("请选择有效的练习题型。")
                return self.respond({"answers": {q["id"]: q["answer"] for q in BANK["questions"] if q["type"] == kind}})
            if path.startswith("/api/exam/"):
                return self.respond(store.exam(path.rsplit("/", 1)[-1]))
            if path == "/api/backup":
                target = store.directory / ("导出备份-" + uuid.uuid4().hex + ".sqlite3")
                try:
                    store.backup(target)
                    return self.respond(target.read_bytes(), content_type="application/octet-stream", extra={"Content-Disposition": 'attachment; filename="huadian-backup-' + datetime.now().strftime("%Y%m%d-%H%M%S") + '.sqlite3"'})
                finally:
                    target.unlink(missing_ok=True)
            if path == "/source.pdf":
                return self.respond((ROOT / "source" / "题库原文.pdf").read_bytes(), content_type="application/pdf")
            relative = "index.html" if path == "/" else path.lstrip("/")
            file = (ROOT / "web" / relative).resolve()
            if not file.is_relative_to((ROOT / "web").resolve()) or not file.is_file():
                raise UserError("页面不存在。", 404)
            mime = mimetypes.guess_type(str(file))[0] or "application/octet-stream"
            if file.suffix in (".js", ".css", ".html", ".svg"):
                mime += "; charset=utf-8"
            return self.respond(file.read_bytes(), content_type=mime)
        except UserError as error:
            self.respond({"error": str(error)}, error.status)
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as error:
            self.respond({"error": "读取失败：" + str(error)}, 500)

    def do_POST(self):
        try:
            if not self.host_ok():
                raise UserError("仅允许从本机访问。", 403)
            origin = self.headers.get("Origin")
            if origin and origin != "http://" + self.headers["Host"]:
                raise UserError("请求来源不正确。", 403)
            length = int(self.headers.get("Content-Length", "0"))
            if length > 1_000_000:
                raise UserError("请求过大。", 413)
            payload = json.loads(self.rfile.read(length) or b"{}")
            if not isinstance(payload, dict) or not secrets.compare_digest(str(self.headers.get("X-App-Token") or payload.get("token", "")), self.server.token):
                raise UserError("程序已重启，请刷新页面后继续。", 403)
            p, store = payload, self.server.store
            route = urllib.parse.urlsplit(self.path).path
            if route == "/api/practice":
                result = store.save_practice(p["qid"], p["answer"], p.get("check", False))
            elif route == "/api/exam/start":
                result = store.start_exam(p["type"])
            elif route == "/api/exam/answer":
                result = store.save_exam(p["id"], p["qid"], p["answer"])
            elif route == "/api/exam/position":
                result = store.position(p["id"], p["qid"])
            elif route == "/api/exam/tick":
                result = store.tick(p["id"], str(p["owner"]), bool(p.get("active", True)))
            elif route == "/api/exam/submit":
                result = store.submit(p["id"])
            elif route == "/api/exam/delete":
                result = store.delete_exams(p["ids"])
            elif route == "/api/review":
                result = store.review(p["id"], p["answer"], p.get("check", False))
            elif route == "/api/settings":
                result = store.settings(p["key"], p["value"])
            elif route == "/api/shutdown":
                store.backup(store.directory / "退出时备份.sqlite3")
                self.respond({"ok": True})
                threading.Thread(target=self.server.shutdown, daemon=True).start()
                return
            else:
                raise UserError("操作不存在。", 404)
            self.respond(result)
        except UserError as error:
            self.respond({"error": str(error)}, error.status)
        except (KeyError, ValueError, TypeError) as error:
            self.respond({"error": "操作数据不完整，请刷新后重试。"}, 400)
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as error:
            self.respond({"error": "保存失败，当前操作未确认保存：" + str(error)}, 500)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=18926)
    parser.add_argument("--data-dir", type=Path, default=ROOT / "data")
    parser.add_argument("--open", action="store_true")
    args = parser.parse_args()
    candidates = [f"http://127.0.0.1:{args.port}"]
    address_file = args.data_dir / "运行地址.txt"
    if address_file.is_file():
        try:
            saved = address_file.read_text(encoding="utf-8").strip()
            parsed = urllib.parse.urlsplit(saved)
            if parsed.scheme == "http" and parsed.hostname == "127.0.0.1" and parsed.port and not parsed.path:
                candidates.insert(0, saved)
        except (OSError, ValueError):
            pass
    for url in dict.fromkeys(candidates):
        connection = None
        try:
            connection = http.client.HTTPConnection("127.0.0.1", urllib.parse.urlsplit(url).port, timeout=1)
            connection.request("GET", "/api/health")
            existing = json.load(connection.getresponse())
            if existing.get("app") == APP_ID and existing.get("dataPath") == str((args.data_dir / "学习记录.sqlite3").resolve()):
                if args.open:
                    webbrowser.open(url)
                return
        except Exception:
            pass
        finally:
            if connection:
                connection.close()
    store = Store(args.data_dir)
    try:
        server = Server(("127.0.0.1", args.port), store)
    except OSError:
        server = Server(("127.0.0.1", 0), store)
    url = f"http://127.0.0.1:{server.server_port}"
    (args.data_dir / "运行地址.txt").write_text(url, encoding="utf-8")
    if args.open:
        threading.Timer(0.5, lambda: webbrowser.open(url)).start()
    if os.sys.stdout:
        print("华电题库练习室 " + url, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
