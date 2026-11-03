"""Tools/asc.py のうち asc-ops.yml が使う部分（regen-profile・beta-submit）。

App Store Connect には繋がない。asc.call を偽物に差し替えて、返事を決めて走らせる。
"""
import tempfile
from pathlib import Path

from test_asc_release import Fake, run
from tools_support import load_tool, unittest

NAME = "EffeTuneLive-AppStore"
BUNDLE = "ai.nemut.effetune"


def bundle_ids(*idents):
    return {"data": [{"id": "bid-%d" % i, "type": "bundleIds", "attributes": {"identifier": x}}
                     for i, x in enumerate(idents)]}


def caps(*types):
    return {"data": [{"id": "cap-%d" % i, "attributes": {"capabilityType": t}} for i, t in enumerate(types)]}


def profiles(*items):
    return {"data": [{"id": pid, "attributes": {"name": name, "profileState": state}}
                     for pid, name, state in items]}


CREATED = {"data": {"id": "p-new", "type": "profiles",
                    "attributes": {"name": NAME, "profileState": "ACTIVE"}}}


class RegenProfileTest(unittest.TestCase):
    def setUp(self):
        self.asc = load_tool("asc")

    def replies(self, bids=None, cap=None, profs=None):
        return {
            ("GET", "/v1/bundleIds"): [bids or bundle_ids(BUNDLE, BUNDLE + ".extension")],
            ("GET", "/v1/bundleIds/bid-0/bundleIdCapabilities"): [cap or caps("APP_GROUPS")],
            ("POST", "/v1/bundleIdCapabilities"): [{"data": {"id": "cap-new"}}],
            ("GET", "/v1/profiles"): [profs or profiles()],
            ("DELETE", "/v1/profiles/p-old"): [{}],
            ("DELETE", "/v1/profiles/p-bad"): [{}],
            ("POST", "/v1/profiles"): [CREATED],
        }

    def test_adds_capability_deletes_same_name_and_creates(self):
        fake = Fake(self.replies(profs=profiles(("p-old", NAME, "ACTIVE"), ("p-bad", NAME, "INVALID"),
                                                ("p-keep", NAME + "-20260926", "ACTIVE"))))
        rc, out, _ = run(self.asc, fake, "regen-profile", NAME, BUNDLE)
        self.assertEqual(rc, 0)
        self.assertEqual(out.strip(), "p-new ACTIVE")
        methods = [(m, p.split("?")[0]) for m, p, _ in fake.calls]
        # 消すのは名前が完全に一致する 2 つだけ。作るのは消した後。
        self.assertIn(("DELETE", "/v1/profiles/p-old"), methods)
        self.assertIn(("DELETE", "/v1/profiles/p-bad"), methods)
        self.assertNotIn(("DELETE", "/v1/profiles/p-keep"), methods)
        self.assertLess(methods.index(("DELETE", "/v1/profiles/p-bad")), methods.index(("POST", "/v1/profiles")))
        cap = next(b for m, p, b in fake.calls if p == "/v1/bundleIdCapabilities")
        self.assertEqual(cap["data"]["attributes"]["capabilityType"], "INTER_APP_AUDIO")
        self.assertEqual(cap["data"]["relationships"]["bundleId"]["data"]["id"], "bid-0")
        body = next(b for m, p, b in fake.calls if (m, p) == ("POST", "/v1/profiles"))["data"]
        self.assertEqual(body["attributes"], {"name": NAME, "profileType": "IOS_APP_STORE"})
        self.assertEqual(body["relationships"]["bundleId"]["data"]["id"], "bid-0")
        self.assertEqual(body["relationships"]["certificates"]["data"],
                         [{"type": "certificates", "id": self.asc.DIST_CERT_ID}])

    def test_keeps_existing_capability(self):
        fake = Fake(self.replies(cap=caps("APP_GROUPS", "INTER_APP_AUDIO")))
        rc, _, _ = run(self.asc, fake, "regen-profile", NAME, BUNDLE)
        self.assertEqual(rc, 0)
        self.assertFalse([c for c in fake.calls if c[1] == "/v1/bundleIdCapabilities"])
        self.assertFalse([c for c in fake.calls if c[0] == "DELETE"])

    def test_refuses_unknown_or_ambiguous_bundle_id(self):
        for bids in (bundle_ids(BUNDLE + ".share"), bundle_ids(BUNDLE, BUNDLE)):
            fake = Fake(self.replies(bids=bids))
            rc, _, err = run(self.asc, fake, "regen-profile", NAME, BUNDLE)
            self.assertEqual(rc, 1)
            self.assertIn("bundle ID", err)
            self.assertEqual([c[0] for c in fake.calls], ["GET"])


def build(encryption=None):
    return {"data": {"id": "b-1", "type": "builds", "attributes": {"usesNonExemptEncryption": encryption}}}


def groups(*items):
    return {"data": [{"id": gid, "attributes": {"name": name, "isInternalGroup": internal}}
                     for gid, name, internal in items]}


PUBLIC = ("g-pub", "EffectDeck Public Beta", False)
INTERNAL = ("g-int", "Internal", True)


class BetaSubmitTest(unittest.TestCase):
    def setUp(self):
        self.asc = load_tool("asc")
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.notes = Path(tmp.name) / "beta_notes.txt"
        self.notes.write_bytes(b"Please test Output Correction.\r\n\r\nReport a problem.\r\n")
        self.asc.BETA_NOTES = self.notes

    def replies(self, locs=None, b=None, grp=None, subs=None):
        app = self.asc.APP
        return {
            ("GET", "/v1/builds/b-1/betaBuildLocalizations"): [locs or {"data": []}],
            ("POST", "/v1/betaBuildLocalizations"): [{"data": {"id": "loc-new"}}],
            ("PATCH", "/v1/betaBuildLocalizations/loc-en"): [{}],
            ("GET", "/v1/builds/b-1"): [b or build()],
            ("PATCH", "/v1/builds/b-1"): [{}],
            ("GET", "/v1/apps/%s/betaGroups" % app): [grp or groups(INTERNAL, PUBLIC)],
            ("POST", "/v1/betaGroups/g-pub/relationships/builds"): [{}],
            ("GET", "/v1/betaAppReviewSubmissions"): [subs or {"data": []}],
            ("POST", "/v1/betaAppReviewSubmissions"): [
                {"data": {"id": "s-1", "attributes": {"betaReviewState": "WAITING_FOR_REVIEW"}}}],
        }

    def bodies(self, fake, method, path):
        return [b for m, p, b in fake.calls if m == method and p.split("?")[0] == path]

    def test_fresh_build_gets_notes_encryption_group_and_submission(self):
        fake = Fake(self.replies())
        rc, out, _ = run(self.asc, fake, "beta-submit", "b-1")
        self.assertEqual((rc, out.strip()), (0, "WAITING_FOR_REVIEW"))
        loc = self.bodies(fake, "POST", "/v1/betaBuildLocalizations")[0]["data"]
        self.assertEqual(loc["attributes"],
                         {"locale": "en-US", "whatsNew": "Please test Output Correction.\n\nReport a problem."})
        self.assertEqual(loc["relationships"]["build"]["data"]["id"], "b-1")
        enc = self.bodies(fake, "PATCH", "/v1/builds/b-1")[0]["data"]["attributes"]
        self.assertEqual(enc, {"usesNonExemptEncryption": False})
        self.assertEqual(self.bodies(fake, "POST", "/v1/betaGroups/g-pub/relationships/builds"),
                         [{"data": [{"type": "builds", "id": "b-1"}]}])
        self.assertFalse(self.bodies(fake, "POST", "/v1/betaGroups/g-int/relationships/builds"))
        sub = self.bodies(fake, "POST", "/v1/betaAppReviewSubmissions")[0]["data"]
        self.assertEqual(sub["relationships"]["build"]["data"]["id"], "b-1")
        q = [p for m, p, _ in fake.calls if p.startswith("/v1/betaAppReviewSubmissions?")][0]
        self.assertIn("filter[build]=b-1", q)

    def test_existing_localization_encryption_and_submission_are_kept(self):
        locs = {"data": [{"id": "loc-ja", "attributes": {"locale": "ja"}},
                         {"id": "loc-en", "attributes": {"locale": "en-US", "whatsNew": "old"}}]}
        subs = {"data": [{"id": "s-0", "attributes": {"betaReviewState": "IN_REVIEW"}}]}
        fake = Fake(self.replies(locs=locs, b=build(False), subs=subs))
        rc, out, _ = run(self.asc, fake, "beta-submit", "b-1")
        self.assertEqual((rc, out.strip()), (0, "IN_REVIEW"))
        patch = self.bodies(fake, "PATCH", "/v1/betaBuildLocalizations/loc-en")[0]["data"]
        self.assertEqual(patch["attributes"]["whatsNew"], "Please test Output Correction.\n\nReport a problem.")
        self.assertFalse(self.bodies(fake, "POST", "/v1/betaBuildLocalizations"))
        self.assertFalse(self.bodies(fake, "PATCH", "/v1/builds/b-1"))
        self.assertFalse(self.bodies(fake, "POST", "/v1/betaAppReviewSubmissions"))

    def test_refuses_missing_duplicate_or_internal_public_group(self):
        cases = {"missing": groups(INTERNAL), "two": groups(PUBLIC, ("g-2",) + PUBLIC[1:]),
                 "internal": groups(("g-pub", PUBLIC[1], True))}
        for label, grp in cases.items():
            fake = Fake(self.replies(grp=grp))
            rc, _, _ = run(self.asc, fake, "beta-submit", "b-1")
            self.assertEqual(rc, 1, label)
            # グループを確かめる前には何も書かない。
            self.assertEqual({c[0] for c in fake.calls}, {"GET"}, label)

    def test_refuses_missing_empty_or_long_notes_before_any_call(self):
        for text in (None, "  \n", "x" * 4001):
            if text is None:
                self.notes.unlink(missing_ok=True)
            else:
                self.notes.write_text(text, encoding="utf-8")
            fake = Fake(self.replies())
            rc, _, err = run(self.asc, fake, "beta-submit", "b-1")
            self.assertEqual(rc, 1)
            self.assertIn("beta_notes.txt", err)
            self.assertEqual(fake.calls, [])


if __name__ == "__main__":
    unittest.main()
