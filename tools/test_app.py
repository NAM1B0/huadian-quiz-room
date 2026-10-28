"""Acceptance tests for durable records and the requested scoring lifecycle."""
import json
import shutil
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from server import BANK, QUESTIONS, Server, Store, UserError


def wrong(qid):
    q = QUESTIONS[qid]
    return [next(o["key"] for o in q["options"] if [o["key"]] != q["answer"])]


class Acceptance(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="huadian-test-")
        self.store = Store(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def fill(self, exam, wrong_ids=()):
        for qid in exam["order"]:
            self.store.save_exam(exam["id"], qid, wrong(qid) if qid in wrong_ids else QUESTIONS[qid]["answer"])

    def test_bank_complete_and_source_groups(self):
        self.assertEqual(len(QUESTIONS), 563)
        self.assertEqual([q["number"] for q in BANK["questions"]], list(range(1, 564)))
        self.assertEqual([sum(q["type"] == t for q in BANK["questions"]) for t in ("single", "multiple", "judge")], [245, 181, 137])
        for q in BANK["questions"]:
            self.assertEqual(len(q["options"]), 2 if q["type"] == "judge" else 4)
            self.assertNotIn("答案：", q["text"])
            self.assertGreaterEqual(q["pdfPage"], 40)
        self.assertEqual(len(BANK["groups"]), 18)

    def test_practice_latest_and_all_history_survive_restart(self):
        s = self.store
        s.save_practice("1", wrong("1"))
        self.assertEqual(len(s.mistakes("practice")), 1)
        s.save_practice("1", QUESTIONS["1"]["answer"])
        self.assertEqual(s.mistakes("practice"), [])
        restarted = Store(self.temp.name)
        self.assertTrue(restarted.bootstrap()["practice"]["1"]["correct"])
        self.assertEqual(restarted.history()["total"], 2)
        self.assertEqual(restarted.history()["items"][1]["answer"], wrong("1"))

    def test_review_is_independent_and_removal_switch_persists(self):
        s = self.store
        s.save_practice("1", wrong("1"))
        first = s.review("practice:1", QUESTIONS["1"]["answer"])
        self.assertFalse(first["removed"])
        self.assertEqual(len(s.mistakes()), 1)
        self.assertFalse(s.bootstrap()["practice"]["1"]["correct"])
        s.settings("autoRemove:practice", True)
        second = s.review("practice:1", QUESTIONS["1"]["answer"])
        self.assertTrue(second["removed"])
        self.assertEqual(s.mistakes(), [])
        self.assertFalse(s.bootstrap()["practice"]["1"]["correct"])
        restarted = Store(self.temp.name)
        self.assertTrue(restarted.settings()["autoRemove:practice"])
        s.save_practice("1", QUESTIONS["1"]["answer"])
        s.save_practice("1", wrong("1"))
        self.assertEqual(len(s.mistakes()), 1)

    def test_multiselect_exact_match_and_clear(self):
        qid = "246"
        answer = QUESTIONS[qid]["answer"]
        self.assertGreater(len(answer), 1)
        self.assertFalse(self.store.save_practice(qid, answer[:1])["correct"])
        self.assertTrue(self.store.save_practice(qid, list(reversed(answer)))["correct"])
        self.assertIsNone(self.store.save_practice(qid, []))
        self.assertNotIn(qid, self.store.bootstrap()["practice"])
        with self.assertRaises(UserError):
            self.store.save_practice("1", ["A", "B"])

    def test_group_shuffle_resume_hidden_answers_and_unfinished_guard(self):
        s = self.store
        e = s.start_exam("single")
        self.assertNotIn("results", e)
        self.assertNotIn("correctCount", e)
        for group in [g for g in BANK["groups"] if g["type"] == "single"]:
            expected = [q["id"] for q in BANK["questions"] if q["group"] == group["id"]]
            actual = [qid for qid in e["order"] if QUESTIONS[qid]["group"] == group["id"]]
            self.assertCountEqual(expected, actual)
            self.assertNotEqual(expected, actual)
        group_positions = [QUESTIONS[qid]["group"] for qid in e["order"]]
        self.assertEqual(group_positions, sorted(group_positions))
        s.save_exam(e["id"], e["order"][0], wrong(e["order"][0]))
        s.position(e["id"], e["order"][3])
        resumed = Store(self.temp.name).start_exam("single")
        self.assertEqual(e["id"], resumed["id"])
        self.assertEqual(e["order"], resumed["order"])
        self.assertEqual(resumed["currentQ"], e["order"][3])
        self.assertEqual(resumed["answered"], 1)
        self.assertNotIn("correctAnswer", json.dumps(resumed))
        self.assertEqual(s.mistakes("exam"), [])
        with self.assertRaisesRegex(UserError, "未作答"):
            s.submit(e["id"])
        s.save_exam(e["id"], e["order"][0], [])
        self.assertEqual(s.exam(e["id"])["answered"], 0)

    def test_submission_lock_new_paper_and_old_wrong_retained(self):
        s = self.store
        e = s.start_exam("judge")
        qid = "427"
        self.fill(e, {qid})
        result = s.submit(e["id"])
        self.assertEqual(result["correctCount"], 136)
        self.assertEqual(result["wrongCount"], 1)
        self.assertFalse(result["results"][qid]["correct"])
        self.assertEqual(s.submit(e["id"]), result)
        self.assertEqual(len(s.mistakes("exam")), 1)
        with self.assertRaisesRegex(UserError, "不能再修改"):
            s.save_exam(e["id"], qid, QUESTIONS[qid]["answer"])
        newer = s.start_exam("judge")
        self.assertNotEqual(newer["id"], e["id"])
        self.assertEqual(newer["answers"], {})
        self.fill(newer)
        self.assertEqual(s.submit(newer["id"])["score"], 100)
        self.assertEqual(len(s.mistakes("exam")), 1)
        self.assertEqual(s.exam(e["id"])["answers"][qid], wrong(qid))
        self.assertEqual(len(Store(self.temp.name).bootstrap()["exams"]), 2)

    def test_two_exam_errors_are_separate_and_remove_only_current(self):
        s = self.store
        ids = []
        for _ in range(2):
            e = s.start_exam("judge")
            self.fill(e, {"427"})
            s.submit(e["id"])
            ids.append("exam:" + e["id"] + ":427")
        self.assertEqual(len(s.mistakes("exam")), 2)
        self.assertFalse(s.review(ids[0], QUESTIONS["427"]["answer"])["removed"])
        s.settings("autoRemove:exam", True)
        self.assertTrue(s.review(ids[0], QUESTIONS["427"]["answer"])["removed"])
        self.assertEqual([m["id"] for m in s.mistakes("exam")], [ids[1]])
        self.assertEqual(s.bootstrap()["exams"][0]["wrongCount"], 1)
        self.assertEqual(s.bootstrap()["exams"][1]["wrongCount"], 1)

    def test_timer_pause_resume_and_duplicate_tabs(self):
        s = self.store
        eid = s.start_exam("single")["id"]
        with patch("server.time.time", return_value=100):
            self.assertEqual(s.tick(eid, "one")["elapsed"], 0)
        with patch("server.time.time", return_value=105):
            self.assertEqual(s.tick(eid, "one")["elapsed"], 5)
            self.assertEqual(s.tick(eid, "two")["elapsed"], 5)
            self.assertEqual(s.tick(eid, "one", False)["elapsed"], 5)
        with patch("server.time.time", return_value=107):
            self.assertEqual(s.tick(eid, "two", False)["elapsed"], 7)
        with patch("server.time.time", return_value=1000):
            self.assertEqual(s.tick(eid, "two")["elapsed"], 7)
        restarted = Store(self.temp.name)
        with patch("server.time.time", return_value=2000):
            self.assertEqual(restarted.tick(eid, "three")["elapsed"], 7)

    def test_backup_contains_complete_state(self):
        self.store.save_practice("1", wrong("1"))
        exam = self.store.start_exam("multiple")
        self.store.save_exam(exam["id"], "246", ["A"])
        snapshot = Path(self.temp.name) / "backup.sqlite3"
        self.store.backup(snapshot)
        restored_dir = Path(self.temp.name) / "restored"
        restored_dir.mkdir()
        shutil.copy2(snapshot, restored_dir / "学习记录.sqlite3")
        restored = Store(restored_dir)
        self.assertEqual(restored.bootstrap()["practice"], self.store.bootstrap()["practice"])
        self.assertEqual(restored.exam(exam["id"])["answers"], {"246": ["A"]})

    def test_http_api_and_security_boundary(self):
        server = Server(("127.0.0.1", 0), self.store)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base = f"http://127.0.0.1:{server.server_port}"
        try:
            with urllib.request.urlopen(base + "/") as r:
                self.assertEqual(r.status, 200)
            with urllib.request.urlopen(base + "/api/bootstrap") as r:
                b = json.load(r)
            self.assertNotIn("answer", b["bank"]["questions"][0])
            req = urllib.request.Request(base + "/api/practice", data=json.dumps({"qid": "1", "answer": ["A"]}).encode(), headers={"Content-Type": "application/json"})
            with self.assertRaises(urllib.error.HTTPError) as context:
                urllib.request.urlopen(req)
            self.assertEqual(context.exception.code, 403)
            req.add_header("X-App-Token", b["token"])
            with urllib.request.urlopen(req) as r:
                self.assertEqual(json.load(r)["answer"], ["A"])
            with urllib.request.urlopen(base + "/api/backup") as r:
                self.assertTrue(r.read().startswith(b"SQLite format 3"))
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__":
    unittest.main(verbosity=2)
