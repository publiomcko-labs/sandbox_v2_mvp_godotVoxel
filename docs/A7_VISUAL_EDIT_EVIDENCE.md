# A7.1 / A7.2 — evidência gráfica e edição (branch experimental)

Base: `fix/a7-etw-loss-probe-20261121`. O código funcional do mundo
A5 CPU16, geometria, água, física, mesher e parâmetros de LOD não mudam.
Nenhum gate `PERF-60`, `STREAM-18`, `VIEW-130` ou `EDIT-100`
é aprovado automaticamente.

## Distribuição de execução

- **Runner CPU/genérico DESKTOP-T0U6S55**: testes estáticos, unitários,
  contratos Python/PowerShell, bootstrap e testes Godot **headless**. O
  `a0-windows.yml` desta branch exige a etiqueta `a7-cpu`. Se ela ainda não
  existir, adicionar **somente nesse runner** pelo GitHub:
  organização `publiomcko-labs` → **Settings** → **Actions** → **Runners**
  → selecionar `DESKTOP-T0U6S55` → **Labels** → **New label** → `a7-cpu`.
  Sem o rótulo o job permanece na fila; **não** será transferido
  automaticamente para a GTX 1050 Ti.
- **GPU GTX 1050 Ti DESKTOP-SAFGO15**: necessária apenas para coleta visual
  real de 1920×1080, FFmpeg/desktop e PresentMon/ETW na sessão interativa.
  Não alocar GPU para gerar relatórios, rodar Python, analisar vídeo ou
  validar a sintaxe. Evitar sobreposição com outros projetos.

## A7.1 — fluxo visual

`godot/tests/a7_route_runtime.gd` em `--capture` grava um PNG
1080p por segundo com posição do jogador, câmera, timestamp Unix,
ticks monotônicos e resultado das 8 sondas a 130m. O executável é colocado
em janela borderless na posição (0,0), somente na campanha de evidência.

`scripts/a7-record-evidence-windows.ps1` inicia FFmpeg com `gdigrab`
para tentar capturar continuamente o monitor principal a 60fps, antes de
chamar o mesmo script de rotas. Grava manifestos incluindo versões, horários,
tamanho do vídeo e advertências. O teste recusa ambientes sem desktop
interativo e sem monitor principal **1920×1080 na origem (0,0)**.

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

Para encontrar FFmpeg previamente instalado:

```powershell
Get-Command ffmpeg.exe -ErrorAction SilentlyContinue | Select-Object Source
```

Depois, caso esteja instalado, usar o caminho real retornado no argumento
`-FfmpegExe`. Exemplo de sintaxe (substitua pelo caminho efetivo):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\a7-record-evidence-windows.ps1" -Mode Route -Scenario shoreline_180s -Duration 30 -Warmup 20 -FfmpegExe "CAMINHO_REAL_DO_FFMPEG_EXE"
```

Para validar o script sem FFmpeg, `-SkipVideo` salva apenas os PNGs, os
eventos e o manifesto; a ausência do vídeo **não** qualifica STREAM-18.

## A7.2 — edição visual e timestamp de apresentação

`godot/tests/a7_edit_runner.gd` registra, por tentativa, a posição
da edição projetada na tela, entrada na função `edit_sphere` em tempo Unix
e ticks monotônicos, retorno da função, mudança SDF e sincronizador visual
de cor sobre a imagem. Em três índices representativos registra PNG antes
e após os frames 1, 4 e 8. O marcador **não** comprova alteração do terreno.

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
