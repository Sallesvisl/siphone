"""PadBridge v1: PDB1 + LE uint32 rate + LE uint32 frames + stereo float32."""
import struct
import threading

HEADER = struct.Struct('<4sII')


def read_exact(sock, size):
    data = bytearray()
    while len(data) < size:
        part = sock.recv(size - len(data))
        if not part:
            raise EOFError('iPhone desconectado')
        data.extend(part)
    return bytes(data)


def read_packet(sock):
    magic, rate, frames = HEADER.unpack(read_exact(sock, HEADER.size))
    if magic != b'PDB1' or rate not in (44100, 48000, 88200, 96000) or not 1 <= frames <= 8192:
        raise ValueError('Pacote inválido ou formato de áudio não suportado')
    return rate, read_exact(sock, frames * 8)


class AudioQueue:
    """Bounded stereo PCM queue. Overflow drops oldest whole frames.

    This prototype does not compensate clock drift; corrections may click.
    The callback never waits for the producer lock.
    """
    def __init__(self, capacity_frames=4096, prefill_frames=256):
        if not 0 < prefill_frames <= capacity_frames:
            raise ValueError('Invalid queue limits')
        self.capacity = capacity_frames * 8
        self.prefill = prefill_frames * 8
        self.data = bytearray()
        self.lock = threading.Lock()
        self.ready = False
        self.underruns = 0
        self.dropped_frames = 0

    def push(self, pcm):
        if len(pcm) % 8:
            raise ValueError('Incomplete stereo frame')
        with self.lock:
            self.data.extend(pcm)
            extra = max(0, len(self.data) - self.capacity)
            if extra:
                del self.data[:extra]
                self.dropped_frames += extra // 8
            if len(self.data) >= self.prefill:
                self.ready = True

    def pop(self, frames):
        size = frames * 8
        if not self.lock.acquire(blocking=False):
            self.underruns += 1
            return bytes(size)
        try:
            if not self.ready:
                return bytes(size)
            count = min(size, len(self.data))
            result = bytes(self.data[:count])
            del self.data[:count]
            if count < size:
                self.ready = False
                self.underruns += 1
            return result + bytes(size - count)
        finally:
            self.lock.release()

    def clear(self):
        with self.lock:
            self.data.clear()
            self.ready = False
