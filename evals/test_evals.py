#!/usr/bin/env python3
"""Tests for the consolidation eval harness, run against synthetic fixtures.

    python3 -m unittest discover -s evals
"""

import contextlib
import datetime as dt
import io
import os
import shutil
import sys
import tempfile
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
sys.path.insert(0, os.path.join(_HERE, "fixtures"))

import run as harness           # noqa: E402
import build as fixtures        # noqa: E402


def _results_by_name(results):
    return {r["name"]: r for r in results}


class FixtureCase(unittest.TestCase):
    mode = None

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="evals-%s-" % cls.mode)
        cls.vault, cls.ledger = fixtures.build(cls.tmp, cls.mode)
        _, results = harness.run_all(cls.vault, cls.ledger)
        cls.results = _results_by_name(results)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)


class TestHealthyFixture(FixtureCase):
    mode = "healthy"

    def test_every_check_passes(self):
        for name, r in self.results.items():
            self.assertTrue(r["ok"], "%s failed on the healthy fixture: %r"
                            % (name, r))

    def test_staleness_is_near_zero(self):
        r = self.results["staleness-honesty"]
        self.assertLessEqual(r["value"], 1.0)
        self.assertFalse(r["detail"]["claim_in_future"])
        # the fixture plants one future-timestamped calendar row
        self.assertEqual(r["detail"]["future_timestamped_rows"], 1)

    def test_redaction_finds_nothing(self):
        self.assertEqual(self.results["redaction-hygiene"]["value"], 0)

    def test_structure_is_complete(self):
        r = self.results["structure-contract"]
        self.assertEqual(r["value"], 1.0)
        self.assertEqual(r["detail"]["missing"], [])
        self.assertTrue(r["detail"]["glance_is_first_section"])
        self.assertLessEqual(r["detail"]["glance_lines"],
                             harness.GLANCE_MAX_LINES)

    def test_coverage_is_full(self):
        self.assertEqual(self.results["coverage"]["value"], 1.0)


class TestBrokenFixture(FixtureCase):
    mode = "broken"

    def test_every_check_fails(self):
        for name, r in self.results.items():
            self.assertFalse(r["ok"], "%s passed on the broken fixture: %r"
                             % (name, r))

    def test_staleness_catches_the_future_claim(self):
        r = self.results["staleness-honesty"]
        self.assertTrue(r["detail"]["claim_in_future"])

    def test_redaction_counts_each_leak_kind(self):
        totals = self.results["redaction-hygiene"]["detail"]["totals"]
        self.assertGreaterEqual(totals["emails"], 2)      # handoff + learnings
        self.assertGreaterEqual(totals["digit-runs"], 2)  # order + invoice
        self.assertGreaterEqual(totals["secrets"], 1)     # exported api key
        surfaces = self.results["redaction-hygiene"]["detail"][
            "surfaces_with_leaks"]
        self.assertIn("HANDOFF.md", surfaces)
        self.assertIn("LEARNINGS.md", surfaces)

    def test_structure_names_the_missing_sections(self):
        r = self.results["structure-contract"]
        for section in ("beliefs", "ripening", "open-questions"):
            self.assertIn(section, r["detail"]["missing"])
        self.assertGreater(r["detail"]["glance_lines"],
                           harness.GLANCE_MAX_LINES)

    def test_coverage_reports_the_gap(self):
        r = self.results["coverage"]
        self.assertLessEqual(r["value"], 0.5)
        self.assertGreater(len(r["detail"]["uncovered"]), 0)


class TestParsers(unittest.TestCase):
    def test_infer_year_wraps_backward_at_new_year(self):
        anchor = dt.datetime(2026, 1, 3)
        self.assertEqual(harness.infer_year(12, 31, anchor).year, 2025)

    def test_infer_year_stays_in_anchor_year(self):
        anchor = dt.datetime(2026, 8, 20)
        self.assertEqual(harness.infer_year(8, 19, anchor).year, 2026)

    def test_infer_year_skips_invalid_dates(self):
        anchor = dt.datetime(2025, 3, 1)  # 2025 has no Feb 29
        got = harness.infer_year(2, 29, anchor)
        self.assertEqual((got.year, got.month, got.day), (2024, 2, 29))

    def test_claimed_coverage_picks_the_latest_marker(self):
        text = ("## GLANCE\n> NOW (WAKE 08-20 13:07): x\n"
                "- 08-19 consolidated\n"
                "— written 2026-08-20 @SLEEP.\n")
        kind, when = harness.parse_claimed_coverage(
            text, dt.datetime(2026, 8, 20, 14, 0))
        self.assertEqual(kind, "wake")
        self.assertEqual(when, dt.datetime(2026, 8, 20, 13, 7))

    def test_claimed_coverage_none_without_markers(self):
        kind, when = harness.parse_claimed_coverage(
            "no markers here", dt.datetime(2026, 8, 20))
        self.assertIsNone(when)

    def test_digit_run_boundary(self):
        self.assertIsNone(harness.DIGIT_RUN_RE.search("order 1234567 ok"))
        self.assertEqual(len(harness.DIGIT_RUN_RE.findall(
            "order 12345678 and 275817663999")), 2)

    def test_digit_run_ignores_hyphenated_dates(self):
        self.assertIsNone(harness.DIGIT_RUN_RE.search("on 2026-08-20 at 13:07"))

    def test_email_pattern(self):
        self.assertEqual(harness.EMAIL_RE.findall(
            "mail a.b+c@sub.example.test now"), ["a.b+c@sub.example.test"])

    def test_secret_shapes(self):
        samples = {
            "api-token": "key sk-abcdefghijklmnop1234",
            "export-secret": "export MY_API_TOKEN=abc123",
            "auth-header": "Authorization: Bearer eyJfixture",
            "aws-key": "AKIAABCDEFGHIJKLMNOP",
        }
        by_name = dict(harness.SECRET_PATTERNS)
        for name, sample in samples.items():
            self.assertTrue(by_name[name].search(sample),
                            "%s did not match %r" % (name, sample))

    def test_secret_shapes_leave_prose_alone(self):
        prose = ("The booking was rebooked on 08-19; commit eb25b2b landed "
                 "and the token budget held.")
        for name, rx in harness.SECRET_PATTERNS:
            self.assertIsNone(rx.search(prose), name)


class TestStructureCheckDirect(unittest.TestCase):
    def _run(self, handoff_text):
        tmp = tempfile.mkdtemp(prefix="evals-structure-")
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        with open(os.path.join(tmp, "HANDOFF.md"), "w") as f:
            f.write(handoff_text)
        return harness.check_structure_contract(tmp)

    def test_glance_must_come_first(self):
        r = self._run(
            "# H\n\n## What actually happened\nx\n\n## ⚡ GLANCE\n> a\n\n"
            "## What I believe\n\n## ⏰ RIPENING\n\n## Open questions\n\n"
            "## Predictions\n")
        self.assertFalse(r["ok"])
        self.assertFalse(r["detail"]["glance_is_first_section"])
        self.assertEqual(r["detail"]["missing"], [])

    def test_missing_handoff_fails(self):
        tmp = tempfile.mkdtemp(prefix="evals-structure-")
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        r = harness.check_structure_contract(tmp)
        self.assertFalse(r["ok"])


class TestCli(unittest.TestCase):
    def _main(self, mode, extra=()):
        tmp = tempfile.mkdtemp(prefix="evals-cli-")
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        vault, ledger = fixtures.build(tmp, mode)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = harness.main(["--vault", vault, "--ledger", ledger]
                                + list(extra))
        return code, out.getvalue()

    def test_exit_zero_and_pass_lines_on_healthy(self):
        code, out = self._main("healthy")
        self.assertEqual(code, 0)
        self.assertIn("overall: PASS", out)

    def test_exit_one_on_broken(self):
        code, out = self._main("broken")
        self.assertEqual(code, 1)
        self.assertIn("overall: FAIL", out)

    def test_json_output(self):
        import json
        code, out = self._main("healthy", ["--json"])
        data = json.loads(out)
        self.assertTrue(data["ok"])
        self.assertEqual(len(data["checks"]), 4)


if __name__ == "__main__":
    unittest.main()
