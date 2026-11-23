# A7.1 / A7.2 — evidência gráfica e edição (branch experimental)

Base: `fix/a7-etw-loss-probe-20261121`. O código funcional do mundo
A5 CPU16, geometria, água, física, mesher e parâmetros de LOD não mudam.
Nenhum gate `PERF-60`, `STREAM-18`, `VIEW-130` ou `EDIT-100`
é aprovado automaticamente.

## Distribuição de execução

- **Runner CPU/genérico DESKTOP-T0U6S55**: testes estáticos, unitários,
  contratos Python/PowerShell, bootstrap e testes Godot **headless**. O
  `a0-windows.yml` desta branch exige a etiqueta `cpu-only`. Se ela ainda não
  existir, adicionar **somente nesse runner** pelo GitHub:
  organização `publiomcko-labs` → **Settings** → **Actions** → **Runners**
  → selecionar `DESKTOP-T0U6S55` → **Labels** → **New label** → `cpu-only`.
  Sem o rótulo o job permanece na fila; **não** será transferido
  automaticamente para a GTX 1050 Ti.
- **GPU GTX 1050 Ti DESKTOP-SAFGO15**: necessária apenas para coleta visual
  real de 1920×1080, FFmpeg/desktop e PresentMon/ETW na sessão interativa.
  Não alocar GPU para gerar relatórios, rodar Python, analisar vídeo ou
  validar a sintaxe. Evitar sobreposição com outros projetos.

## A7.1 — fluxo visual

`godot/tests/a7_route_runtime.gd` em `--capture` emite um marcador verde/magenta por segundo, com eventos UTC para sincronização temporal do vídeo. Admite PNG
1080p com intervalo configurável (padrão 30s), posição do jogador, câmera,
timestamp Unix, ticks monotônicos e resultado das 8 sondas a 130m.
**Quando há vídeo externo, o intervalo é 0 e nenhum PNG é lido dentro do Godot.**
O executável fica em janela borderless na posição (0,0), somente na
campanha de evidência.

`scripts/a7-record-evidence-windows.ps1` inicia FFmpeg com `gdigrab`
para tentar capturar continuamente o monitor principal a 60fps, antes de
chamar o mesmo script de rotas. Grava manifestos incluindo versões, horários,
tamanho do vídeo e advertências. O teste recusa ambientes sem desktop
interativo ou com monitor principal inferior a **1920×1080**. O monitor principal deve começar na origem **(0,0)**. A resolução atual do Windows é preservada: com telas maiores, a gravação captura somente a área superior esquerda de **1920×1080**, ocupada pela janela borderless do Godot. Não cubra a janela com outros aplicativos; o vídeo do desktop gravaria a sobreposição.

**Importante:** capturar e codificar vídeo e ler PNGs da GPU custa tempo
adicional. É um braço **somente de evidência visual**, separado dos números
canônicos de PERF-60/ETW. O número de frames real, perdas da gravação,
provas de profundidade 360° e ausência de fissuras devem ser verificados
independentemente. Não usar 8/8 sondas como substituto para pixels.

Com o repositório atualizado, no PowerShell interativo do PC com GPU,
comando de **uma linha por vez**:

```powershell
cd "C:\Dev\sandbox-a7-etw"
git fetch origin exp/a7-visual-edit-evidence-20261121
git switch --detach FETCH_HEAD
python .\tests\check_a7_visual_edit_evidence.py
```

**FFmpeg portátil automático:** não é necessário instalar o programa
no Windows ou alterar o PATH. No primeiro teste gráfico, o script baixa
a versão 7.1.1 para `reports/tools/` e valida seu SHA-256 contra o
manifesto público versionado de `microsoft/winget-pkgs`.

A7.1 com vídeo externo de 60fps (sem capturas dentro do Godot):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\a7-record-evidence-windows.ps1" -Mode Route -Scenario shoreline_180s -Duration 30 -Warmup 20
```

A7.2 com vídeo externo e PresentMon ETW do mesmo processo:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\a7-record-evidence-windows.ps1" -Mode Edit -Scenario boundary_edit_100 -Warmup 45 -PresentMonExe ".\PresentMon.exe"
```

A indexação temporal do vídeo (no runner CPU ou outra máquina, sem reserva
da GTX 1050 Ti), após transferir os arquivos de evidência, utiliza:

```powershell
python .\scripts\a7_video_timeline.py "CAMINHO_REAL_DA_PASTA_EVIDENCE" --ffmpeg "CAMINHO_FFMPEG_PORTATIL" --ffprobe "CAMINHO_FFPROBE_PORTATIL"
```

O arquivo `a7_video_timeline.json` registra os timestamps PTS de cada
frame, cadência e o marcador verde/magenta de sincronização. Sua correlação
com o relógio do Godot é aproximada; não substitui a verificação dos pixels
alterados nem profundidade a 130 m.

Para validar sem FFmpeg, `-SkipVideo` salva apenas PNGs espaçados **15s**
(aproximadamente 3 para rota de 30s), eventos e manifesto. Esses PNGs ainda
geram pausas pontuais, pois `get_viewport().get_texture().get_image()` é
readback síncrono. Para rodar **sem nenhum readback**, use `-SkipVideo
-NoStills`: gera telemetria, mas **não gera prova visual**. A ausência do
vídeo **não** qualifica STREAM-18. O campo de manifesto
`video_capture_valid_container` é `false` quando vídeo é ignorado,
mesmo que o experimento de telemetria tenha sucesso.

## A7.2 — edição visual e timestamp de apresentação

`godot/tests/a7_edit_runner.gd` registra, por tentativa, a posição
da edição projetada na tela, entrada na função `edit_sphere` em tempo Unix
e ticks monotônicos, retorno da função, mudança SDF e sincronizador visual
de cor sobre a imagem. Em modo de imagem estática (`-SkipVideo`, sem `-NoStills`),
em três índices representativos registra PNG antes e após os
frames 1, 4 e 8. Em modo de vídeo externo, usa **somente os marcadores
visuais e timestamps**, sem PNG interno ou readback. O marcador
**não** comprova alteração do terreno.

O modo `-Mode Edit` permite, opcionalmente, passar `-PresentMonExe`
para capturar ETW sobre a **mesma execução** que o vídeo e as edições;
esse modo é explicitamente excluído das métricas PERF-60, pois inclui
readback/gravador. Os guardas do ETW anteriores são preservados e só
encerram sessões A7 próprias sem coletor ativo.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\a7-record-evidence-windows.ps1" -Mode Edit -Scenario boundary_edit_100 -Warmup 45 -FfmpegExe "CAMINHO_REAL_DO_FFMPEG_EXE" -PresentMonExe ".\PresentMon.exe"
```

Cenários adicionais: `edit_idle_100`, `edit_moving_100`.

`scripts/a7_analyze_visual_evidence.py` produz
`visual_evidence_analysis.json` com existência/size de vídeos e PNGs,
eventos, sondas e timestamp de edições. Com ETW válido e relógio alinhado,
calcula a **primeira oportunidade de apresentação após a chamada**;
ela é apenas um *limite inferior* da latência até pixel correto.
Sem verificação visual do ROI e sincronização confiável de frames externos,
`EDIT-100` continua `NOT_QUALIFIED`.

Exemplo de análise CPU (caminho real criado no teste):

```powershell
python .\scripts\a7_analyze_visual_evidence.py ".\reports\generated\a7-visual-evidence\evidence-YYYYMMDD-HHMMSS-PID"
```

## Saídas e próximos passos

- `reports/generated/a7-visual-evidence/evidence-*/visual_evidence_manifest.json`
- `game/*/a7_route.jsonl` + PNGs de rota, ou
  `game/*/a7_edits.jsonl` + PNGs de edição
- `desktop-1080p-60fps.mkv` (quando FFmpeg presente)
- `a7_presentmon_status.json` e `a7_presentmon.csv` da edição (ETW opcional)
- `visual_evidence_analysis.json` gerado pelo analisador

O roteiro da revisão é classificar manualmente os frames com fissuras,
desaparecimento, água/rochas adiantados e mudança real dos pixels do ROI
do brush; quando houver dúvida, manter `NOT_QUALIFIED`.

**Ainda pendente nesta fase:** detector de pixels/depth independente,
correlação comprovada frame de vídeo → frame ETW e julgamento automático
de pixels alterados. Esta implementação entrega captura e correlação
temporal auxiliar, não uma aprovação prematura de A7.

## Investigação de travadas no primeiro diagnóstico A7.1

ZIP local `evidence-20261122-204616-5884.zip` (22 Nov 2026):
- `capture=true`, `-SkipVideo`, 30 s de movimento, 31 imagens 1920x1080
- 31 intervalos de frame maiores que 33 ms (mesmo número dos screenshots)
- `frame_start_p99_ms=214.001`, `frame_start_max_ms=309.902`
- `frame_count=1449`, `min_radial_probe_hits_8=8`
- zero vídeo gravado: `video_fps_requested=0`, `video_path=null`

A correlação 31 screenshots / 31 pausas não prova causalidade frame a frame
porque o trace não preservou timestamps individuais de todos os frames,
mas é forte evidência de custo do `get_image()`/PNG síncrono.
**Não classificar essas pausas como regressão da baseline A5.**
Correção: gravador externo não executa `get_image()`; `-SkipVideo`
reduz amostragem a 15 s, com opção `-NoStills` para zero readbacks.

Mantenha vídeo, PNG, ETW e desempenho estrito em braços separados.

## Implementação da indexação temporal

O FFmpeg 7.1.1 portátil é distribuído somente na pasta de trabalho, com SHA-256 fixado a partir do manifesto Microsoft winget 7.1.1. O analisador offline `scripts/a7_video_timeline.py` decodifica exclusivamente um recorte 8×8px por frame para ler os marcadores e usa `ffprobe` para medir os PTS. Retorna `NOT_QUALIFIED` para todas as metas gráficas até revisão dos pixels do mundo e profundidade. A carga de análise pode ser executada no runner `cpu-only`.

## A7.1 — revisão do vídeo da campanha 20261122-211708

Arquivo recebido: `evidence-20261122-211708-65708.zip`. Condições:
- `git_sha=561657922abed374e576ea45dd5c196e6f2e0f78`;
- GDI/CPU x264, 1920x1080, FFmpeg H264, tamanho 32.669.963 bytes;
- vídeo: 54,7 s, **1625 frames efetivamente codificados**, cadência real **29,69fps**,
  apesar do cabeçalho nominal `60/1`. P99 da distância entre PTS: 50ms;
  máximo 67ms. Não utilizar o FPS nominal para qualificar continuidade;
- 31 transições do marcador detectadas no vídeo e 31 eventos `video_sync`
  correlacionados em ordem; offset por mediana, maior resíduo ~18ms;
- Godot: 30s de movimento, 540m em X, 1800 frames, p99 start-to-start
  18,009ms, máximo 22,298ms, 0 intervalos >33ms, 8/8 sondas de malha;
- amostras visuais próximas aos instantes do vídeo 28s e 50s apresentam
  rochas aparentemente suspensas e geometria observada pelo lado de baixo.
  A rota canônica `shoreline_180s` usa y=7 fixo, sem ajustar a câmera à
  elevação do relevo: a câmera pode entrar no terreno. Não concluir automaticamente
  que esses quadros são falhas de streaming/recursos.
- aprovação formal `STREAM-18`, `VIEW-130`, `EDIT-100`, `PERF-60`:
  **NOT_QUALIFIED**. Não confundir cobertura 8/8 mesh com pixels 130m.

### Ajuste de aquisição — sem tocar na implementação A5

O gravador passa a usar por padrão `-RecorderMode ddagrab_nvenc`:
Desktop Duplication (D3D11) e encoder NVIDIA NVENC em hardware,
`framerate=60`, `dup_frames=0`, `fps_mode=passthrough`, com recorte
1920x1080 do monitor principal. Não alterar a resolução do Windows.
O modo `gdigrab_x264` é diagnóstico de compatibilidade e **não**
pode sozinho comprovar 60fps. Se NVENC/ddagrab não funcionar, o teste
falha explicitamente em vez de usar fallback silencioso. Confirmar FPS
**efetivo** e lacunas pelos PTS após cada campanha.

Somente na **aquisição visual**, não no benchmark, os cenários
`shoreline_180s` e `rocks_water_180s` acompanham a superfície
via raycast SDF com altura mínima `superfície + 5m` para a câmera
não atravessar o terreno. Movimento XZ preservado em 18 m/s, e
`surface_follow_hits` / `surface_follow_misses` e a folga mínima
são registrados. Qualquer `surface_follow_misses > 0` impede a
validação visual desse trecho. As rotas canônicas sem esse flag
permanecem **inalteradas**.

A7.1 com gravador novo, após atualizar a branch:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\a7-record-evidence-windows.ps1" -Mode Route -Scenario shoreline_180s -Duration 30 -Warmup 20
```

Esse teste requer a GTX 1050 Ti, pois usa o desktop real; análises de
arquivo, validação do código e smokes headless continuam no `cpu-only`.
