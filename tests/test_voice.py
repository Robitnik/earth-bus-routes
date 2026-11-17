"""Tests of the stop announcer's service part (voices, phrases, the clip with its gong, the /v1/voice and /v1/say requests):
python -m unittest discover -s tests -p "test_voice.py" (from the repo root). No test starts the Piper program or goes online."""
import http.client
import io
import json
import pathlib
import sys
import tempfile
import threading
import time
import unittest
import wave

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "companion"))
import bus_routes_data as d  # noqa: E402

RATE = 22050


def speech(seconds=1.0):
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(bytes(2 * int(RATE * seconds)))
    return buf.getvalue()


def wav_seconds(data):
    with wave.open(io.BytesIO(data), "rb") as w:
        return w.getnframes() / w.getframerate()


def fake_fetch(calls, fail=()):
    """A stand-in for download_file: writes a small file, or the voice's config, and remembers what was asked."""
    def fetch(url, dest, max_bytes=0, progress=None):
        calls.append(url)
        if any(f in url for f in fail):
            raise OSError("no internet")
        dest = pathlib.Path(dest)
        if url.endswith(".onnx.json"):
            dest.write_text(json.dumps({"phoneme_id_map": {"a": [1], "aɪ": [2]}, "vowel_clusters": [["a", "ɪ"]]}), encoding="utf-8")
        else:
            dest.write_bytes(b"x" * 100)
            if progress:
                progress(100, 100)
    return fetch


class Phrases(unittest.TestCase):
    def test_every_language_has_the_four_sentences_and_a_voice(self):
        for lang, p in d.PHRASES.items():
            for kind in d.SAY_KINDS:
                self.assertIn(kind, p, f"{lang} lacks {kind}")
                self.assertIn("{s}", p[kind], f"{lang}.{kind} has no stop name")
            self.assertIn(lang, d.VOICES, f"{lang} has no voice")
        for lang, (key, rev, speaker) in d.VOICES.items():
            self.assertIn(lang, d.PHRASES)
            self.assertIn(rev, (d.VOICE_OLD, d.VOICE_NEW))
            self.assertTrue(d.voice_path(key).count("/") == 4, key)

    def test_every_country_of_the_union_speaks_its_language(self):
        eu = "AT BE BG HR CY CZ DK EE FI FR DE GR HU IE IT LV LT LU MT NL PL PT RO SK SI ES SE UA".split()
        for cc in eu:
            self.assertIsNotNone(d.announce_lang(cc, 50.0, 4.0), cc)
        self.assertEqual(d.announce_lang("CZ"), "cs")
        self.assertEqual(d.announce_lang("UA"), "uk")
        self.assertEqual(d.announce_lang("AT"), "de_AT")

    def test_belgium_speaks_dutch_in_flanders_and_french_in_wallonia_and_brussels(self):
        self.assertEqual(d.announce_lang("BE", 51.05, 3.72), "nl_BE")       # Ghent
        self.assertEqual(d.announce_lang("BE", 50.46, 4.86), "fr")          # Namur
        self.assertEqual(d.announce_lang("BE", 50.85, 4.35), "fr")          # Brussels

    def test_a_country_without_a_language_of_its_own_takes_the_game_language_if_there_is_a_voice(self):
        self.assertEqual(d.announce_lang("JP", fallback="uk"), "uk")
        self.assertEqual(d.announce_lang("JP", fallback="pt_BR"), "pt")
        self.assertEqual(d.announce_lang("JP", fallback="en"), "en_US")
        self.assertIsNone(d.announce_lang("JP", fallback="ja"))

    def test_sentences_follow_the_country(self):
        self.assertEqual(d.announcement("uk", "next", "Площа Ринок"), "Наступна зупинка: Площа Ринок.")
        self.assertEqual(d.announcement("cs", "next", "Náměstí"), "Příští zastávka: Náměstí.")
        self.assertEqual(d.announcement("hu", "next", "Deák tér", request=True), "Következik: Deák tér, feltételes megálló.")
        self.assertIn("Endhaltestelle", d.announcement("de", "end", "Hbf"))
        self.assertEqual(d.announcement("de", "at", "Mitte", request=True), "Mitte.")        # no request form: the plain one

    def test_short_forms_of_names_are_read_in_full(self):
        self.assertEqual(d.speakable("Police n.Met.,aut.st.", "cs"), "Police nad Metují, autobusové stanoviště")
        self.assertEqual(d.speakable("Náchod,nám.", "cs"), "Náchod, náměstí")
        self.assertEqual(d.speakable("вул. Січових Стрільців", "uk"), "вулиця Січових Стрільців")
        self.assertEqual(d.speakable("Hauptstr.", "de"), "Hauptstraße")
        self.assertEqual(d.speakable('Rynek (Dworzec) / "Centrum"', "pl"), "Rynek, Dworzec, Centrum")
        self.assertEqual(d.speakable("  ", "cs"), "")

    def test_a_voice_the_old_engine_cannot_read_loses_its_two_letter_symbols(self):
        cfg = d.fit_config({"phoneme_id_map": {"a": [1], "aɪ": [2]}, "vowel_clusters": [["a", "ɪ"]], "audio": {"sample_rate": 22050}})
        self.assertEqual(list(cfg["phoneme_id_map"]), ["a"])
        self.assertNotIn("vowel_clusters", cfg)
        same = {"phoneme_id_map": {"a": [1]}}
        self.assertEqual(d.fit_config(same), same)

    def test_the_clip_is_a_gong_then_the_speech(self):
        data, secs = d.with_chime(speech(1.0))
        self.assertAlmostEqual(wav_seconds(data), secs, places=1)
        self.assertGreater(secs, 1.0 + 1.0)
        bare, secs2 = d.with_chime(speech(1.0), gong=False)
        self.assertLess(secs2, secs - 0.9)


class Voices(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = pathlib.Path(self.tmp.name) / "voice"
        self.calls = []
        self.spoken = []

        def engine(model, text, speaker):
            self.spoken.append((pathlib.Path(model).name, text, speaker))
            return speech(0.5)
        self.engine = engine

    def tearDown(self):
        self.tmp.cleanup()

    def wait(self, a, lang, states=("ready", "failed"), secs=5):
        end = time.time() + secs
        while time.time() < end:
            st = a.prepare(lang)
            if st["state"] in states:
                return st
            time.sleep(0.02)
        self.fail(f"voice stayed {a.status(lang)}")

    def test_no_folder_no_voice(self):
        a = d.Announcer(None)
        self.assertEqual(a.prepare("cs")["state"], "unsupported" if a.engine is None else "none")
        with self.assertRaises(d.VoiceNotReady):
            a.speak("cs", "x")

    def test_a_language_without_a_voice_is_none(self):
        a = d.Announcer(self.dir, fetch=fake_fetch(self.calls), engine=self.engine)
        self.assertEqual(a.prepare(None)["state"], "none")
        self.assertEqual(a.prepare("xx")["state"], "none")

    def test_the_voice_downloads_once_and_the_config_is_fitted_to_the_engine(self):
        a = d.Announcer(self.dir, fetch=fake_fetch(self.calls), engine=self.engine)
        self.assertEqual(a.status("cs")["state"], "missing")
        st = a.prepare("cs")
        self.assertEqual(st["state"], "downloading")
        self.wait(a, "cs", ("ready",))
        urls = [u.rsplit("/", 1)[1] for u in self.calls]
        self.assertEqual(urls, ["cs_CZ-jirka-medium.onnx.json", "cs_CZ-jirka-medium.onnx"])
        self.assertTrue(all("/v1.0.0/" in u for u in self.calls))
        cfg = json.loads((self.dir / "models" / "cs_CZ-jirka-medium.onnx.json").read_text(encoding="utf-8"))
        self.assertEqual(list(cfg["phoneme_id_map"]), ["a"])
        n = len(self.calls)
        a.prepare("cs")
        self.assertEqual(len(self.calls), n, "a ready voice is not downloaded again")

    def test_two_asks_while_it_downloads_start_one_download(self):
        slow = []

        def fetch(url, dest, max_bytes=0, progress=None):
            slow.append(url)
            time.sleep(0.2)
            return fake_fetch([])(url, dest, max_bytes, progress)
        a = d.Announcer(self.dir, fetch=fetch, engine=self.engine)
        a.prepare("pl")
        a.prepare("pl")
        a.prepare("pl")
        self.wait(a, "pl", ("ready",))
        self.assertEqual(len(slow), 2)

    def test_a_failed_download_is_failed_and_leaves_no_half_file_then_is_tried_again_after_a_minute(self):
        now = [0.0]
        a = d.Announcer(self.dir, fetch=fake_fetch(self.calls, fail=(".onnx",)), clock=lambda: now[0], engine=self.engine)
        a.prepare("de")
        st = self.wait(a, "de", ("failed",))
        self.assertIn("internet", st["error"])
        self.assertEqual(list((self.dir / "models").glob("*.dl")), [])
        self.assertFalse((self.dir / "models" / "de_DE-thorsten-medium.onnx").exists())
        n = len(self.calls)
        a.prepare("de")
        self.assertEqual(len(self.calls), n, "not at once")
        now[0] = 61.0
        a.fetch = fake_fetch(self.calls)
        a.prepare("de")
        self.wait(a, "de", ("ready",))

    def test_a_download_nobody_asks_for_any_more_is_dropped(self):
        now = [0.0]

        def fetch(url, dest, max_bytes=0, progress=None):
            if url.endswith(".onnx"):
                now[0] += 1000.0                         # long after the lease
                if progress:
                    progress(1, 100)
            return fake_fetch([])(url, dest, max_bytes, progress)
        a = d.Announcer(self.dir, fetch=fetch, clock=lambda: now[0], engine=self.engine)
        a.prepare("sk")
        st = self.wait(a, "sk", ("failed",))
        self.assertIn("nobody", st["error"])

    def test_a_sentence_is_spoken_with_the_voice_and_kept_for_the_next_time(self):
        a = d.Announcer(self.dir, fetch=fake_fetch(self.calls), engine=self.engine)
        a.prepare("uk")
        self.wait(a, "uk", ("ready",))
        data, secs, cid = a.speak("uk", "Наступна зупинка: Ринок.")
        self.assertGreater(secs, 1.5)
        self.assertEqual(self.spoken, [("uk_UA-ukrainian_tts-medium.onnx", "Наступна зупинка: Ринок.", 2)])
        data2, secs2, cid2 = a.speak("uk", "Наступна зупинка: Ринок.")
        self.assertEqual((cid, secs), (cid2, secs2))
        self.assertEqual(len(self.spoken), 1, "the clip came from the disk")
        self.assertTrue(a.clip_path(cid).exists())
        a.speak("uk", "Наступна зупинка: Ринок.", gong=False)
        self.assertEqual(len(self.spoken), 2, "another clip for the same words without the gong")

    def test_old_clips_are_trimmed(self):
        a = d.Announcer(self.dir, fetch=fake_fetch(self.calls), engine=self.engine)
        a.CLIPS_MAX_BYTES = 100000
        a.prepare("uk")
        self.wait(a, "uk", ("ready",))
        for i in range(12):
            a.speak("uk", f"Зупинка {i}.")
        a._trim(self.dir / "clips")
        total = sum(p.stat().st_size for p in (self.dir / "clips").glob("*.wav"))
        self.assertLessEqual(total, 100000)


class Http(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        base = pathlib.Path(cls.tmp.name)
        cls.calls = []
        voice = d.Announcer(base / "voice", fetch=fake_fetch(cls.calls),
                            engine=lambda model, text, speaker: speech(0.5))
        cls.svc = d.Service(d.Cache(base / "cache"), voice=voice,
                            upstream=lambda q: (_ for _ in ()).throw(RuntimeError("no map servers")))
        cls.httpd, _ = d.serve(0, service=cls.svc)
        cls.port = cls.httpd.server_address[1]
        cls.httpd.RequestHandlerClass = d.make_handler(cls.svc, cls.port)
        threading.Thread(target=cls.httpd.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.tmp.cleanup()

    def get(self, path):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        c.putrequest("GET", path, skip_host=True)
        c.putheader("Host", f"127.0.0.1:{self.port}")
        c.endheaders()
        r = c.getresponse()
        return r.status, dict(r.getheaders()), r.read()

    def ready(self, query):
        end = time.time() + 5
        while time.time() < end:
            s, h, b = self.get("/v1/voice?" + query)
            st = json.loads(b)["data"]
            if st["state"] == "ready":
                return st
            time.sleep(0.02)
        self.fail(st)

    def test_the_service_says_it_has_the_voice(self):
        s, h, b = self.get("/v1/info")
        self.assertIn("voice", json.loads(b)["features"])

    def test_the_country_picks_the_language_and_the_voice_is_downloaded_on_asking(self):
        s, h, b = self.get("/v1/voice?cc=CZ&lat=50.5&lon=16.2")
        self.assertEqual(s, 200)
        st = json.loads(b)["data"]
        self.assertEqual((st["lang"], st["voice"]), ("cs", "cs_CZ-jirka-medium"))
        self.ready("cc=CZ")

    def test_say_gives_the_wav_or_the_path_of_the_clip(self):
        self.ready("cc=UA")
        s, h, b = self.get("/v1/say?cc=UA&kind=next&name=" + "%D0%A0%D0%B8%D0%BD%D0%BE%D0%BA")
        self.assertEqual(s, 200)
        self.assertEqual(h["Content-Type"], "audio/wav")
        self.assertEqual(h["X-Lang"], "uk")
        self.assertGreater(float(h["X-Seconds"]), 1.0)
        self.assertEqual(b[:4], b"RIFF")
        s, h, b = self.get("/v1/say?file=1&cc=UA&kind=end&name=Vyshenka")
        j = json.loads(b)["data"]
        self.assertTrue(pathlib.Path(j["path"]).exists())
        self.assertIn("Кінцева", j["text"])

    def test_the_language_of_the_game_is_used_where_the_country_has_none(self):
        s, h, b = self.get("/v1/voice?cc=JP&ui=uk")
        self.assertEqual(json.loads(b)["data"]["lang"], "uk")
        s, h, b = self.get("/v1/voice?cc=JP&ui=ja")
        self.assertEqual(json.loads(b)["data"]["state"], "none")

    def test_say_without_a_voice_is_409_and_a_bad_request_400(self):
        s, h, b = self.get("/v1/say?lang=fi&kind=next&name=X")
        self.assertEqual(s, 409)
        s, h, b = self.get("/v1/say?lang=fi&kind=bogus&name=X")
        self.assertEqual(s, 400)


if __name__ == "__main__":
    unittest.main()
