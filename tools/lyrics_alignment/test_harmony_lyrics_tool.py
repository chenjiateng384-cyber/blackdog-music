import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("harmony_lyrics_tool.py")
SPEC = importlib.util.spec_from_file_location("harmony_lyrics_tool", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class HarmonyLyricsToolTest(unittest.TestCase):
    def test_source_lrc_is_sorted_and_offset_is_not_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "song.lrc"
            path.write_text("[ar:歌手]\n[offset:300]\n[00:02.00]第二句\n[00:01.00]第一句\n", encoding="utf-8")
            source = MODULE.read_source_lrc(path)
            self.assertEqual(source.metadata, ("[ar:歌手]",))
            self.assertEqual(source.lines, ("第一句", "第二句"))
            self.assertEqual(source.line_times_ms, (1000, 2000))

    def test_json_conversion_keeps_word_end_and_gap(self):
        payload = [{
            "line": "你 好", "start": 1.0, "end": 2.0, "score": 0.9, "matched": True,
            "chars": [
                {"char": "你", "start": 1.0, "end": 1.2},
                {"char": "好", "start": 1.5, "end": 2.0},
            ],
        }]
        enhanced, report = MODULE.json_to_harmony_lrc(payload, ())
        self.assertIn("<00:01.000>你 <00:01.200><00:01.500>好<00:02.000>", enhanced)
        self.assertEqual(report["alignedLineCount"], 1)

    def test_validation_rejects_missing_lines(self):
        source = MODULE.SourceLyrics((), ("第一句", "第二句"))
        enhanced = "[00:01.000]<00:01.000>第一句<00:02.000>\n"
        result = MODULE.validate_enhanced_lrc(source, enhanced)
        self.assertFalse(result["valid"])
        self.assertFalse(result["textMatchesSource"])

    def test_leading_song_credits_are_reported_but_not_aligned(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "song.lrc"
            path.write_text(
                "[00:00.00]安静 - 周杰伦 (Jay Chou)\n"
                "[00:01.00]词：周杰伦\n"
                "[00:10.00]只剩下钢琴陪我谈了一天\n",
                encoding="utf-8",
            )
            source = MODULE.read_source_lrc(path)
            self.assertEqual(source.ignored_leading_lines, ("安静 - 周杰伦 (Jay Chou)", "词：周杰伦"))
            self.assertEqual(source.lines, ("只剩下钢琴陪我谈了一天",))
    def test_swlrc_conversion_preserves_explicit_token_ranges(self):
        enhanced, report = MODULE.swlrc_to_harmony_lrc("""[swlrc:1]
[offset:0]
[tokenization:char]
[00:10.000,00:11.200]
<00:10.000,00:10.250>你
<00:10.500,00:11.200>好
""")
        self.assertIn("[00:10.000]<00:10.000>你<00:10.250><00:10.500>好<00:11.200>", enhanced)
        self.assertEqual(report, {"lineCount": 1, "tokenCount": 2})

    def test_swlrc_conversion_rejects_overlapping_tokens(self):
        with self.assertRaisesRegex(ValueError, "重叠"):
            MODULE.swlrc_to_harmony_lrc("""[swlrc:1]
[offset:0]
[tokenization:char]
[00:10.000,00:11.200]
<00:10.000,00:10.700>你
<00:10.500,00:11.200>好
""")

    def test_swlrc_conversion_restores_source_spacing(self):
        source = MODULE.SourceLyrics(("[ar:歌手]",), ("茶道 有三段",))
        enhanced, report = MODULE.swlrc_to_harmony_lrc("""[swlrc:1]
[00:10.000,00:11.200]
<00:10.000,00:10.200>茶
<00:10.200,00:10.400>道
<00:10.500,00:10.700>有
<00:10.700,00:10.900>三
<00:10.900,00:11.200>段
""", source)
        self.assertIn("茶<00:10.200><00:10.200>道<00:10.400><00:10.500> 有", enhanced)
        self.assertTrue(report["textRestoredFromSource"])
        self.assertTrue(MODULE.validate_enhanced_lrc(source, enhanced)["valid"])

    def test_language_selection_preserves_bilingual_translation(self):
        source = MODULE.SourceLyrics(
            (),
            ("I love you", "我爱你"),
            (),
            (1000, 1500),
        )
        content = """[swlrc:1]
[00:01.000,00:02.000]
<00:01.000,00:01.150>I
<00:01.250,00:01.550>love
<00:01.650,00:02.000>you
"""
        indices = MODULE._alignment_indices(source, "en")
        enhanced, report = MODULE.swlrc_to_harmony_lrc(content, source, indices)
        self.assertEqual(indices, (0,))
        self.assertIn("[00:01.500]我爱你", enhanced)
        self.assertTrue(MODULE.validate_enhanced_lrc(source, enhanced)["valid"])
        self.assertEqual(report["lineCount"], 2)

    def test_extended_leading_credits_are_filtered(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "song.lrc"
            path.write_text(
                "[00:00.00]合声编写：周杰伦\n"
                "[00:01.00]Lyrics by: Example\n"
                "[00:02.00]TME享有本翻译歌词\n"
                "[00:10.00]真正歌词\n",
                encoding="utf-8",
            )
            source = MODULE.read_source_lrc(path)
            self.assertEqual(source.lines, ("真正歌词",))
            self.assertEqual(len(source.ignored_leading_lines), 3)


    def test_swlrc_skipped_line_is_preserved_as_line_timed(self):
        source = MODULE.SourceLyrics(
            (),
            ("第一句", "没有唱出的说明", "第三句"),
            (),
            (1000, 2000, 3000),
        )
        content = """[swlrc:1]
[00:01.000,00:01.800]
<00:01.000,00:01.300>第一
<00:01.350,00:01.800>句
[00:03.000,00:03.800]
<00:03.000,00:03.300>第三
<00:03.350,00:03.800>句
"""
        indices = MODULE._alignment_indices(source, "zh")
        enhanced, _ = MODULE.swlrc_to_harmony_lrc(content, source, indices)
        self.assertIn("[00:02.000]没有唱出的说明", enhanced)
        self.assertTrue(MODULE.validate_enhanced_lrc(source, enhanced)["valid"])

if __name__ == "__main__":
    unittest.main()
