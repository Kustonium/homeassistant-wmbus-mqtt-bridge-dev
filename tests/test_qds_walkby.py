#!/usr/bin/env python3
"""Regression corpus for the Qundis (QDS) walk-by block -- rootfs/usr/bin/qds.py.

The corpus is split by how each frame can be delivered on a real bench:

  TCP-INJECTED  -- decoder and classifier logic. Everything here can be pushed
                   straight into the bridge over MQTT/TCP, no radio involved.
  FAKE-T (RF)   -- the one frame that must arrive over the air, because what it
                   exercises is the RF path: Format A framing, per-block CRCs
                   and FIFO readout. It is the only fixture carrying CRCs.

The most important test in this file is
`test_upstream_1_in_256_bug_is_not_reproduced`. It pins the exact failure that
motivated the whole feature: wmbusmeters v3.0.0 (and master as of 2026-08-17)
publishes `total_m3 = 15430.611, status: OK` for that frame, because it gates
the walk-by decode on the single byte blob[9]==0x13 which random ciphertext hits
1/256. If that test ever goes green while a numeric value is present, the guard
has been broken.
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "rootfs", "usr", "bin"))

import qds  # noqa: E402


# --- wmbusmeters issue #2025, meter QDS 60555885, ver 0x1A type 0x07 --------
TRIGGER = (  # blob[9] happens to be 0x13 -> upstream publishes garbage
    "49449344855855601A07780DFF5F350082590035E40C1B5C1313509ED5FE13E79D59"
    "75FA08EF2A766E0F341BE49F21CB2A8CDADE82FA4CE9EF79287407BF57764792EEFA"
    "046D29064837")
BENIGN = (  # same meter ~2 min earlier, blob[9]=0x1E -> upstream ignores it
    "49449344855855601A07780DFF5F3500825900358F7892871E56F1F8F1FD3BD3BD85"
    "F7D3BE076E8DE810EBA30EBBA63B45F05D75680B4AABAEC324CF689A9F483240E423"
    "046D28064837")
REBUILT = (  # the same block after decryption, byte[4] reset to 0x00
    "49449344855855601A07780DFF5F350082590000F10007C113FFFF87130000FFFF00"
    "0000005E364812000000800080008000800080008000800080030008002F0042002F"
    "046D29064837")
CI7A_REFERENCE = (  # ordinary records from the same meter: the true 1.387 m3
    "48449344855855601A077A5A0030252F2F0C13871300004C1300000000426CFFFFCC"
    "081348120000C2086C5E3602BB5600002F2F2F2F2F2F2F2F2F2F2F2F2F326CFFFF04"
    "6D2D064837")
# The plaintext body #2025 reports as verified against 36/36 captured frames.
PLAINTEXT_BODY = bytes.fromhex(
    "F10007C113FFFF87130000FFFF000000005E3648120000008000800080008000"
    "80008000800080030008002F0042002F")

# --- FAKE-T (RF) : Format A, 84 bytes, 5/5 block CRCs valid ----------------
CRC_WRAPPED = (
    "49449344708828521a072198780dff5f350082a70035865b2883cf79596625201701"
    "faccdcedd4506930ee48b78676cf439beb7e6054de780a19938a15235695b5c3e7af"
    "7140e85bfaefe1dd046d011307365690")

# --- plaintext walk-by from the wmbusmeters test corpus --------------------
CORPUS_PLAINTEXT = (
    "49449344123456781606780DFF5F3500824E00007F0007C113FFFF63961300DF2C82"
    "731200FE2463811300A400F200D100A900DD00E000E90006011601EA0027010F012F"
    "046D0211F225")

# --- standard DIF/VIF telegrams: nothing Qundis-specific to do -------------
QHEAT_PLAIN = (
    "41449344839201684637728392016893444604640000200C06851400004C06411100"
    "00426C1F3CCC080668130000C2086C3F3102FD170000326CFFFF046D24133432")
QSMOKE = (
    "3E44934452114247231A7801FD086081027C034955230082026CFFFF81037C034C41"
    "230082036CFFFF03FD17000000326CFFFF046D3809183802FDAC7E0F00",
    "3E44934444114247231A7801FD084281027C034955230082026CFFFF81037C034C41"
    "230082036CFFFF03FD17000000326CFFFF046D3809183802FDAC7EF100",
    "3744934452114247231A7A6100002081027C034955230082026CFFFF81037C034C41"
    "230082036CFFFF02FD170000326CFFFF046D39091838",
)
# 0DFF5F with LVAR 0x0C, not 0x35 -- the fixed-offset reader must not apply.
QCALORIC_SHORT_BLOCK = (
    "344465325566366018087A90040000046D1311962C01FD0C03326CFFFF01FD730002"
    "5AC2000DFF5F0C0008003030810613080BFFFC")

KEY = bytes.fromhex("000102030405060708090A0B0C0D0E0F")
WRONG_KEY = bytes.fromhex("FFEEDDCCBBAA99887766554433221100")
M_QDS = bytes.fromhex("9344")
A_60555885 = bytes.fromhex("855855601A07")   # id(4 LE) || ver || type


def numeric_values(res):
    """Every numeric measurement the classifier produced, flattened."""
    out = []
    for k, v in (res.get("values") or {}).items():
        if isinstance(v, (int, float)) and k != "seconds_to_next_tpl_frame":
            out.append((k, v))
        elif isinstance(v, list):
            out += [(k, x) for x in v if isinstance(x, (int, float))]
    return out


class UpstreamBugCorpus(unittest.TestCase):
    """TCP-INJECTED. The failure this whole feature exists to stop."""

    def test_upstream_1_in_256_bug_is_not_reproduced(self):
        res = qds.classify(TRIGGER)
        self.assertNotEqual(res["status"], "QDS_PLAINTEXT_OK")
        self.assertEqual(res.get("values"), None)
        # The exact number upstream publishes for this frame.
        self.assertNotIn(15430.611, [v for _, v in numeric_values(res)])
        # And it must be named, not silently dropped.
        for token in ("ver=0x1A", "type=0x07", "CI=0x78", "0DFF5F"):
            self.assertIn(token, res["message"])

    def test_trigger_frame_is_neutralised_not_forwarded_intact(self):
        # Forwarding it unchanged would let the decoder downstream hit the
        # single-byte gate anyway, so the record key must be rewritten.
        res = qds.classify(TRIGGER)
        neut = res["neutralized"]
        self.assertNotIn("0DFF5F", neut)
        self.assertIn("0DFF5E", neut)
        self.assertEqual(len(neut), len(TRIGGER))
        # meter_datetime is the one field that IS valid here -- keep it.
        self.assertTrue(neut.endswith("046D29064837"))

    def test_benign_frame_also_rejected_but_datetime_survives(self):
        res = qds.classify(BENIGN)
        self.assertEqual(res["status"], "QDS_ENCRYPTED_PAYLOAD")
        self.assertIsNone(res.get("values"))
        self.assertTrue(res["neutralized"].endswith("046D28064837"))

    def test_message_names_the_key_the_user_actually_needs(self):
        # The commonest misunderstanding on this format is that walk-by needs a
        # separate secret. It does not.
        msg = qds.classify(TRIGGER)["message"]
        self.assertIn("SAME", msg)
        self.assertIn("CI=0x7A", msg)


class PlaintextCorpus(unittest.TestCase):
    """TCP-INJECTED."""

    def test_decrypted_block_rebuilt_as_plaintext(self):
        res = qds.classify(REBUILT)
        self.assertEqual(res["status"], "QDS_PLAINTEXT_OK")
        v = res["values"]
        self.assertEqual(v["total_m3"], 1.387)
        self.assertEqual(v["target_m3"], 1.248)
        self.assertEqual(v["target_date"], "2026-06-30")
        self.assertEqual(v["target_year_m3"], 0.0)
        self.assertIsNone(v["error_date"])
        # 0x8000 is the vendor "no data" sentinel. We report it as None rather
        # than upstream's -32.768: a real number would land in Home Assistant
        # long-term statistics as a genuine -32768 litre reading.
        self.assertEqual(v["deltas_m3"][:8], [None] * 8)
        self.assertEqual(v["deltas_m3"][8:], [0.003, 0.008, 0.047, 0.066])

    def test_corpus_plaintext_walkby(self):
        v = qds.classify(CORPUS_PLAINTEXT)["values"]
        self.assertEqual(v["total_m3"], 139.663)
        self.assertEqual(v["target_m3"], 138.163)
        self.assertEqual(v["target_year_m3"], 127.382)

    def test_ci7a_reference_is_an_ordinary_telegram(self):
        res = qds.classify(CI7A_REFERENCE)
        self.assertEqual(res["status"], "QDS_NO_MFCT_BLOCK")
        self.assertIn("0C13", res["message"])

    def test_standard_telegrams_have_no_mfct_block(self):
        for hexs in (QHEAT_PLAIN,) + QSMOKE:
            res = qds.classify(hexs)
            self.assertEqual(res["status"], "QDS_NO_MFCT_BLOCK", hexs[:20])
            self.assertIn("DIF/VIF found:", res["message"])

    def test_short_mfct_block_is_not_read_at_walkby_offsets(self):
        res = qds.classify(QCALORIC_SHORT_BLOCK)
        self.assertEqual(res["status"], "QDS_UNKNOWN_LAYOUT")
        self.assertIn("LVAR=0x0C", res["message"])
        self.assertIsNone(res.get("values"))


class StrictBcd(unittest.TestCase):
    """TCP-INJECTED. Guard 1, independent of the header gate."""

    def test_any_nibble_above_nine_rejects_the_field(self):
        self.assertEqual(qds._bcd(bytes.fromhex("87130000")), 1387)
        for bad in ("9ED5FE13", "0000000A", "A0000000"):
            with self.assertRaises(qds.BcdError):
                qds._bcd(bytes.fromhex(bad))

    def test_plaintext_marker_with_non_bcd_body_is_a_layout_problem(self):
        # byte[4]=0x00 claims plaintext, but the payload is not BCD. That is a
        # layout/driver problem, and must NOT be reported as a missing key.
        block = bytearray(bytes.fromhex(REBUILT[22 + 8:22 + 8 + 106]))
        block[12:16] = bytes.fromhex("9ED5FE13")
        frame = REBUILT[:22 + 8] + block.hex().upper() + REBUILT[22 + 8 + 106:]
        res = qds.classify(frame)
        self.assertEqual(res["status"], "QDS_UNKNOWN_LAYOUT")
        self.assertIsNone(res.get("values"))
        self.assertIn("9ED5FE13", res["message"])


class Decryption(unittest.TestCase):
    """TCP-INJECTED.

    We own no Qundis meter and no key for the real #2025 ciphertexts, so the
    decryption path is exercised against ciphertext we build ourselves from the
    plaintext body #2025 published as verified. A round trip through
    make_encrypted_walkby() proves the IV construction, the CBC wiring and the
    offsets are mutually consistent -- it does NOT prove the vendor really uses
    this construction. That claim rests on one user's report (issue #2025) and
    is not confirmed upstream.
    """

    def build(self, cnt=0x59, key=KEY):
        return qds.make_encrypted_walkby(PLAINTEXT_BODY, key, M_QDS, A_60555885, cnt)

    def test_generated_frame_has_the_encrypted_shape(self):
        tel = self.build()
        self.assertIn("0DFF5F35", tel)
        block = tel[tel.index("0DFF5F35") + 8:][:106]
        self.assertTrue(block.startswith("00825900" "35"))
        self.assertEqual(int(tel[0:2], 16), len(tel) // 2 - 1)   # L-field

    def test_round_trip_with_the_right_key(self):
        res = qds.classify(self.build(), key=KEY)
        self.assertEqual(res["status"], "QDS_PLAINTEXT_OK")
        v = res["values"]
        self.assertEqual(v["total_m3"], 1.387)
        self.assertEqual(v["target_m3"], 1.248)
        self.assertEqual(v["deltas_m3"][:8], [None] * 8)
        self.assertEqual(v["seconds_to_next_tpl_frame"], 241)
        self.assertTrue(v["decrypted"])
        # The rebuilt frame is what the decoder downstream actually receives.
        self.assertEqual(qds.classify(res["rebuilt"])["values"]["total_m3"], 1.387)

    def test_wrong_key_never_produces_a_number(self):
        res = qds.classify(self.build(), key=WRONG_KEY)
        self.assertEqual(res["status"], "QDS_DECRYPT_FAILED")
        self.assertIsNone(res.get("values"))
        self.assertEqual(numeric_values(res), [])
        self.assertIn("key is most likely wrong", res["message"])

    def test_no_key_asks_for_the_ordinary_meter_key(self):
        res = qds.classify(self.build())
        self.assertEqual(res["status"], "QDS_ENCRYPTED_PAYLOAD")
        self.assertIsNone(res.get("values"))

    def test_malformed_key_is_reported_not_ignored(self):
        res = qds.classify(self.build(), key=b"\x00" * 8)
        self.assertEqual(res["status"], "QDS_DECRYPT_FAILED")
        self.assertIn("not 16", res["message"])

    def test_counter_participates_in_the_iv(self):
        # A frame built with a different counter must not decrypt against the
        # IV of another counter -- otherwise the counter is not really in play.
        tel = self.build(cnt=0x59)
        other = tel[:tel.index("0DFF5F35") + 8 + 4] + "5A" + \
            tel[tel.index("0DFF5F35") + 8 + 6:]
        self.assertEqual(qds.classify(other, key=KEY)["status"],
                         "QDS_DECRYPT_FAILED")


class FormatACrc(unittest.TestCase):
    """FAKE-T (RF). The only fixture that must travel over the air."""

    def test_block_crcs_are_verified_and_stripped(self):
        frame, blocks = qds.strip_block_crc(bytes.fromhex(CRC_WRAPPED))
        self.assertEqual(blocks, 5)
        self.assertEqual(len(frame), frame[0] + 1)

    def test_crc_wrapped_frame_is_classified_not_rejected(self):
        res = qds.classify(CRC_WRAPPED)
        self.assertEqual(res["status"], "QDS_ENCRYPTED_PAYLOAD")
        self.assertIn("block CRCs verified and stripped", res["message"])

    def test_crc_free_frame_is_left_alone(self):
        raw = bytes.fromhex(REBUILT)
        frame, blocks = qds.strip_block_crc(raw)
        self.assertEqual(blocks, 0)
        self.assertEqual(frame, raw)

    def test_a_single_corrupt_crc_aborts_the_strip(self):
        # Better to hand the decoder the frame as received than to silently
        # remove bytes from a frame whose integrity we could not confirm.
        bad = bytearray(bytes.fromhex(CRC_WRAPPED))
        bad[20] ^= 0xFF
        frame, blocks = qds.strip_block_crc(bytes(bad))
        self.assertEqual(blocks, 0)
        self.assertEqual(frame, bytes(bad))

    def test_round_trip_through_the_rf_framing(self):
        tel = qds.make_encrypted_walkby(PLAINTEXT_BODY, KEY, M_QDS, A_60555885, 0x59)
        wrapped = qds.add_block_crc(tel)
        self.assertGreater(len(wrapped), len(tel))
        self.assertEqual(qds.classify(wrapped, key=KEY)["values"]["total_m3"], 1.387)


class StreamFilter(unittest.TestCase):
    """The only component that touches the live decode path."""

    def setUp(self):
        import tempfile
        self.dir = tempfile.mkdtemp()
        with open(os.path.join(self.dir, "meter-0001"), "w", encoding="utf-8") as fh:
            fh.write("name=Kueche\nid=60555885\nkey=%s\n" % KEY.hex())

    def run_filter(self, lines):
        import io
        out, err = io.StringIO(), io.StringIO()
        qds.filter_stream(self.dir, iter(lines), out, err)
        return out.getvalue().strip().split("\n"), err.getvalue()

    def test_unrelated_traffic_passes_through_byte_for_byte(self):
        lines = [QHEAT_PLAIN, CI7A_REFERENCE, "1E44B4090713271916A2189F2519B2C7DE45B3AE0F0E11B72A3E5D"]
        got, err = self.run_filter(lines)
        self.assertEqual(got, lines)
        self.assertEqual(err, "")

    def test_encrypted_frame_with_key_becomes_plaintext(self):
        tel = qds.make_encrypted_walkby(PLAINTEXT_BODY, KEY, M_QDS, A_60555885, 0x59)
        got, err = self.run_filter([tel])
        self.assertNotEqual(got[0], tel)
        self.assertEqual(qds.classify(got[0])["values"]["total_m3"], 1.387)
        self.assertIn("decrypted walk-by block", err)

    def test_undecryptable_frame_is_neutralised_on_the_way_out(self):
        got, err = self.run_filter([TRIGGER])
        self.assertNotIn("0DFF5F", got[0])
        self.assertTrue(got[0].endswith("046D29064837"))
        self.assertIn("QDS_DECRYPT_FAILED", err)


if __name__ == "__main__":
    unittest.main(verbosity=2)
