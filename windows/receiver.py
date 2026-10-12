"""Experimental USB-proxy receiver -> ReaRoute ASIO output."""
import argparse
import os
import socket
import threading
import time

# Must be set before importing sounddevice on Windows.
os.environ['SD_ENABLE_ASIO'] = '1'
from protocol import AudioQueue, read_packet


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--list', action='store_true', help='Listar dispositivos de áudio')
    parser.add_argument('--device', type=int, help='Índice da saída ReaRoute ASIO')
    parser.add_argument('--port', type=int, default=24680)
    parser.add_argument('--block', type=int, choices=(64, 128, 256, 512), default=128)
    parser.add_argument('--prefill', type=int, default=256)
    args = parser.parse_args()
    import sounddevice as sd
    if args.list:
        print(sd.query_devices())
        print(sd.query_hostapis())
        return
    if args.device is None:
        parser.error('Use --list e depois --device N com a saída ReaRoute ASIO.')
    if not 64 <= args.prefill <= 4096:
        parser.error('--prefill deve estar entre 64 e 4096 frames')
    device = sd.query_devices(args.device)
    api = sd.query_hostapis(device['hostapi'])
    if 'ASIO' not in api['name'].upper() or 'rearoute' not in device['name'].lower():
        parser.error('Selecione ReaRoute ASIO. Abra o REAPER antes de iniciar o receptor.')
    if device['max_output_channels'] < 2:
        parser.error('O dispositivo precisa de duas saídas.')
    queue = AudioQueue(capacity_frames=8192, prefill_frames=args.prefill)
    print('Conectando ao túnel USB local. Ctrl+C para parar.')
    with socket.create_connection(('127.0.0.1', args.port), timeout=5) as sock:
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        rate, first = read_packet(sock)
        queue.push(first)
        stopped = threading.Event()
        errors = []

        def receive():
            try:
                while not stopped.is_set():
                    next_rate, pcm = read_packet(sock)
                    if next_rate != rate:
                        raise ValueError('Taxa de áudio mudou. Reinicie o receptor.')
                    queue.push(pcm)
            except (OSError, EOFError, ValueError) as error:
                errors.append(str(error))
            finally:
                queue.clear()
                stopped.set()

        def callback(outdata, frames, timing, status):
            outdata[:] = queue.pop(frames)

        sd.check_output_settings(device=args.device, channels=2, dtype='float32', samplerate=rate)
        worker = threading.Thread(target=receive, daemon=True)
        worker.start()
        try:
            with sd.RawOutputStream(device=args.device, channels=2, dtype='float32',
                                    samplerate=rate, blocksize=args.block, latency='low',
                                    callback=callback):
                print(f'{rate} Hz estéreo -> ReaRoute 1/2. Latência total ainda não medida.')
                while not stopped.wait(1):
                    print(f'Faltas de áudio: {queue.underruns} | frames descartados: {queue.dropped_frames}', end='\r')
        finally:
            stopped.set()
            sock.shutdown(socket.SHUT_RDWR)
            worker.join(timeout=6)
        if errors:
            raise RuntimeError(errors[-1])


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        print('\nEncerrado.')
    except Exception as error:
        raise SystemExit(f'Erro: {error}')
