# PadBridge — protótipo experimental

Projeto para hospedar o PadLab AUv3 no iPhone e transmitir PCM estéreo pelo cabo
Lightning–USB ao Windows, com saída ReaRoute ASIO para o REAPER.

**Estado: código inicial; iOS não compilado nem testado em aparelho. Nenhum IPA
foi gerado ainda. Transporte USB, interface do PadLab e latência não validados.**
Não há garantia de uso ao vivo nesta versão. O PadLab precisa estar instalado
separadamente e disponibilizar sua extensão AUv3 no iPhone.

## Gerar o IPA sem possuir um Mac

O arquivo `.github/workflows/ios.yml` prepara uma compilação manual em macOS
no GitHub Actions. A execução exige um repositório na sua conta com Actions
disponível; verifique a cota/custo da conta antes de executar. Este projeto não
foi publicado e o workflow não foi executado nesta sessão.

1. Envie os arquivos deste projeto para um repositório GitHub, incluindo `.github`.
2. Em Actions, selecione **Gerar IPA experimental → Run workflow**.
3. Se a compilação passar, baixe o artefato **PadBridge-IPA-Sideloadly** e extraia
   `PadBridge-unsigned.ipa` do ZIP. Se falhar, o log identifica os erros a corrigir.
4. Conecte o iPhone ao Windows, desbloqueie e aceite **Confiar neste computador**.
5. No Sideloadly, selecione o iPhone, arraste o IPA e faça a assinatura/instalação
   usando sua conta Apple no próprio Sideloadly. Não compartilhe sua senha no chat.
6. Autorize o perfil e o Modo de Desenvolvedor no iPhone caso o sistema solicite.

O pacote é propositalmente sem assinatura para ser assinado pelo Sideloadly.
Com uma conta Apple gratuita, normalmente é necessário renovar após sete dias.

## Preparar o Windows e REAPER

Dependências: Python 3.11+ de 64 bits, suporte de dispositivos Apple, `iproxy`
do libusbmuxd para Windows e REAPER de 64 bits com **ReaRoute ASIO** instalado
(opção adicional no instalador do REAPER). O iproxy não está incluído neste projeto.
O projeto oficial documenta a compilação no Windows com MSYS2.

No PowerShell, dentro da pasta do projeto:

```powershell
py -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r windows/requirements.txt
```

1. Abra o REAPER, use inicialmente 48 kHz e mantenha seu dispositivo de áudio
   habitual. Crie uma faixa estéreo com entrada **ReaRoute 1 / ReaRoute 2**,
   arme para gravação e habilite monitoramento. ReaRoute deve ser escolhido como
   saída do receptor; não substitua o dispositivo principal do REAPER por ele.
2. Abra o PadBridge no iPhone, escolha o PadLab e inicie um pad em sua interface.
3. Em um terminal separado, execute a versão atual do iproxy:

```powershell
iproxy -l -s 127.0.0.1 24680:24680
```

O parâmetro `-l` seleciona apenas conexão USB. Não há transmissão por Wi-Fi.
O servidor no iPhone também escuta somente em loopback. Esta ligação via
usbmux ao servidor do app precisa de validação física; apenas conectar o cabo
não transforma o iPhone em uma interface de áudio USB padrão.

4. Liste os dispositivos e selecione o número da saída **ReaRoute ASIO**:

```powershell
.\.venv\Scripts\python.exe windows/receiver.py --list
.\.venv\Scripts\python.exe windows/receiver.py --device NUMERO
```

Substitua `NUMERO` pelo índice exibido. Se ReaRoute não aparecer, confira a
instalação de 64 bits, abra o REAPER primeiro e confirme que a distribuição de
PortAudio usada pelo sounddevice inclui ASIO. O receptor ativa `SD_ENABLE_ASIO`.

## Limites conhecidos e validação pendente

- Este receptor é Python + ReaRoute, não um plugin VST nem um instalador Windows.
- O app solicita 128 frames, mas o iOS pode entregar taps maiores. Isso pode
  dominar a latência; não há promessa de atraso mínimo nem medição ponta a ponta.
- Há uma operação de envio pendente por vez; pacotes podem ser descartados sob
  carga. O tap aloca memória: precisa de ring buffer nativo para produção.
- O receptor usa uma fila limitada a 8192 frames e prefill padrão de 256 frames.
  O tamanho máximo é proteção contra acúmulo ilimitado, não uma meta de latência.
- Os relógios do iPhone e da placa de som são independentes. Ainda não há
  reamostragem adaptativa; podem ocorrer faltas, descartes e cliques em uso longo.
- Não há reconexão automática, transporte musical do host, restauração de
  presets ou suporte a segundo plano. Mantenha o app aberto. Após uma mudança
  de rota de áudio ou interrupção, recarregue o instrumento e reinicie o receptor.
- Confirmar se o PadLab permite tocar os pads na interface AUv3 e se exige
  callbacks de transporte do host. A descrição da loja não valida essa integração.
- Para testar, use volume baixo inicialmente, desligue Wi-Fi no iPhone para
  confirmar o cabo e teste desconexão/reconexão, estéreo e reprodução por 30 min.
- Medir latência com impulsos e gravação de referência no mesmo relógio; números
  de buffer isolados não representam latência total. Depois ajustar o transporte.

## Testes locais

```powershell
py -m unittest discover -s windows -p "test_*.py" -v
```

Cobrem fragmentação TCP, pacotes inválidos/truncados, descarte, silêncio na falta
de dados e limpeza da fila. Não substituem compilação Swift nem teste com hardware.

## Referências

- https://apps.apple.com/us/app/padlab-live-pads/id6759358968
- https://developer.apple.com/documentation/audiotoolbox/incorporating-audio-effects-and-instruments
- https://github.com/libimobiledevice/libusbmuxd
- https://sideloadly.io/faq.html
- https://python-sounddevice.readthedocs.io/en/latest/installation.html
