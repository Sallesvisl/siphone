import struct
import unittest
from protocol import AudioQueue, read_packet


class FragmentedSocket:
    def __init__(self, data):
        self.data = data

    def recv(self, count):
        part = self.data[:min(count, 3)]
        self.data = self.data[len(part):]
        return part


class ProtocolTests(unittest.TestCase):
    def test_fragmented_stereo_packet(self):
        pcm = struct.pack('<4f', 0.25, -0.25, 0.5, -0.5)
        self.assertEqual(read_packet(FragmentedSocket(struct.pack('<4sII', b'PDB1', 48000, 2) + pcm)), (48000, pcm))

    def test_truncated_packet(self):
        with self.assertRaises(EOFError):
            read_packet(FragmentedSocket(struct.pack('<4sII', b'PDB1', 48000, 2) + b'\0'))

    def test_reject_bad_headers_before_allocation(self):
        for magic, rate, frames in [(b'BAD!', 48000, 1), (b'PDB1', 0, 1), (b'PDB1', 48000, 999999)]:
            with self.assertRaises(ValueError):
                read_packet(FragmentedSocket(struct.pack('<4sII', magic, rate, frames)))

    def test_overflow_keeps_latest_frames(self):
        q = AudioQueue(4, 2)
        q.push(b'a' * 24)
        q.push(b'b' * 24)
        self.assertEqual(q.pop(4), b'a' * 8 + b'b' * 24)
        self.assertEqual(q.dropped_frames, 2)

    def test_underflow_silence_and_rebuffer(self):
        q = AudioQueue(4, 2)
        q.push(b'a' * 16)
        self.assertEqual(q.pop(3), b'a' * 16 + bytes(8))
        q.push(b'b' * 8)
        self.assertEqual(q.pop(1), bytes(8))
        q.push(b'c' * 8)
        self.assertEqual(q.pop(2), b'b' * 8 + b'c' * 8)

    def test_disconnect_clears_audio(self):
        q = AudioQueue(4, 2)
        q.push(b'a' * 32)
        q.clear()
        self.assertEqual(q.pop(4), bytes(32))

    def test_callback_does_not_wait_for_producer(self):
        q = AudioQueue(4, 2)
        with q.lock:
            self.assertEqual(q.pop(4), bytes(32))


if __name__ == '__main__':
    unittest.main()
