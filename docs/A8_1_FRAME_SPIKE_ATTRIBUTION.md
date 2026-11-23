# A8-P1 — Atribuição diagnóstica de picos de frame

Data: 23/11/2026. Baseline funcional A5/CPU16 inalterada. A7.4 encerrada sem merge; A8-P0 aprovado funcionalmente no Actions, não promovido.

## Evidência de entrada: A8-P0 em GTX 1050 Ti

ZIP da execução GPU `a8_pilot_summary.zip`, commit `a7c3e60c4157739cc601120acd1e031fd51e87d2`, seed 20261119, percurso reto 30s/540m, resolução 1920×1080, VSync normal, sem captura no jogo/ETW.

| Medição | Resultado |
|---|---:|
| Warmup realmente desenhado | 1000 frames / 16,670 s |
| Velocidade horizontal mediana amostrada | 17,998 m/s |
| Frames | 1800 |
| Mediana / p95 / p99 / p99,9 intervalo start-to-start | 16,670 / 17,445 / 17,943 / 20,587 ms |
| Máximo | 21,978 ms |
| Intervalos >16,7ms | 745/1800 (41,4%) |
| Intervalos >20ms / >33ms | 2 / 0 |
| Render viewport CPU/GPU p99 | 2,178 / 1,641 ms |
| Voxel worker queue máximo observado em 1 Hz | 87 tarefas |
| Workers ativos, máximo amostrado | 14 |
| Sondas is_area_meshed a 130 m | 8/8 nas 31 observações de movimento |
| Amostras 1Hz com LODs bloqueados | 10/31 |
| Amostras 1Hz com fila de workers não vazia | 8/31 |

**Interpretação:** um monitor aproximadamente a 60Hz produz período nominal de 16,667ms; comparar cada intervalo ao teto arredondado de 16,7ms amplifica a diferença de ~0,033ms. Os 745 eventos >16,7ms isoladamente não estabelecem sobrecarga de renderização. Há dois picos >20ms reais **de start-to-start**, que precisam de timestamp e posição para diagnóstico. CPU/GPU viewport leves não equivalem a medir o caminho CPU + GPU + compositor + present. Sondas nativas 8/8 não provam geometria correta em pixels nem continuidade dos recursos.

## Implementação P1

Introduz modo explícito **A8SpikeTrace**, sem custo de disco por frame e sem novos acessos de malha/worker a cada frame:

1. O medidor A7 já calcula cada intervalo start-to-start. Quando `dt_ms >= 18.0`, A8-P1 guarda somente em memória índice do frame, tempo do percurso, duração do intervalo, coordenada do jogador, medidores viewport CPU/GPU e **último snapshot de fila/workers/LOD feito a 1Hz**, com idade em segundos.
2. O buffer tem limite de 256 eventos; se houver perda, o analisador **reprova a integridade do diagnóstico**.
3. Os eventos são gravados **uma vez ao final da execução** em `a8_frame_spikes.json`; nenhum PNG, vídeo, readback de GPU ou log por frame é introduzido.
4. O analisador `a8_route_triage.py` verifica contagem, ordem, timestamps, provenance, thresholds, e reconcilia o número de eventos >20 e >33ms contra os contadores originais. Rejeita overflow, estado de warmup insuficiente, inconsistência e amostras de fila antigas demais.
5. A idade da amostra de worker é explicitada: **não é uma leitura instantânea** do estado que causou o frame lento. O resultado é uma hipótese de correlação, não diagnóstico causal fechado.

O modo permanece **opt-in**, disponível somente em percurso GPU real <=90s, com 1000 frames de warmup, VSync normal, sem screenshots/FFmpeg/PresentMon/CI headless/alteração de thread count. O cenário, mundo, física, terreno, rochas, água e malha A5 não mudam.

## Coleta seguinte: uma execução de 30s

Na GTX 1050 Ti, com checkout da branch A8-P1 e CI aprovado:

    cd "C:\Dev\sandbox-a7-etw"
    git fetch origin exp/a8-1-frame-spike-attribution-20261123
    git switch --detach FETCH_HEAD
    powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\a8-pilot-windows.ps1" -SpikeTrace

A saída será `reports/generated/a8/pilot-.../a8_pilot_summary.zip`, incluindo `a8_frame_spikes.json` e todas as telemetrias existentes. Não rodar uma bateria de 12 ou 90 sessões e não misturar instrumentação diferente entre os braços de um futuro teste A/B.

## Decisão futura

- Se os frames lentos coincidirem repetidamente com backlog/LODs bloqueados, aprofundar coleta ETW/PresentMon e perfil de publicação por fase; não atribuir causalidade apenas por fila.
- Se o padrão ocorrer sem backlog, investigar pacing/VSync/compositor e tempos de thread principal com ETW externo.
- Independente do cenário, os gates `PERF-60`, `STREAM-18`, `VIEW-130` e `EDIT-100` permanecem `NOT_QUALIFIED`. Nenhuma promoção da A5/CPU16 é autorizada.
