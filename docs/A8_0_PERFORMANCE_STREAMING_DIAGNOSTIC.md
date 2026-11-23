# A8-P0 — Baseline de desempenho e streaming após encerramento A7.4

Data: 23/11/2026. **Experimento isolado, não é promoção nem aceite.**

## Ponto de partida e decisão

A7.4 encerrou com o [PR #17](https://github.com/publiomcko-labs/sandbox_v2_mvp_godotVoxel/pull/17)
fechado **sem merge**; 12/12 edições funcionais, alterações visuais diagnosticadas,
mas EDIT-100 ainda sem prova independente do primeiro pixel de profundidade correta.
Não repetir as capturas de edição.

A8 parte da branch A7.3 (que já contém telemetria A7.1–A7.3), com
**baseline funcional A5 CPU16** imutável: commit
`0c3fee959576d0a1faec9ceecffb4b132a65558b`,
GL Compatibility 1920×1080, mesh16, 4 LODs, lod_distance=48m e
view_distance=192m. A8 não modifica o streamer Voxel Tools, mundo, água,
rochas, física, C++ ou tolerâncias de aceitação.

## Próxima pergunta experimental

Num percurso determinístico de 18 m/s, **quais indicadores precisam de
investigação primeiro** para aproximar PERF-60, STREAM-18 e VIEW-130?

A8-P0 é um **diagnóstico barato** antes de uma campanha longa. Ele não é
uma certificação dos três gates.

- 1.000 **frames realmente desenhados** por Godot, contados por
  `Engine.get_frames_drawn()` e registrados como contagem+tempo;
  warmup só inicia amostragem depois da conclusão;
- 30 s de rota reta 18 m/s, seed fixa 20261119, percurso da A7 já
  aprovado funcionalmente; sem vídeo, ETW ou readback neste braço;
- tempos start-to-start p50/p95/p99/p99,9/máximo e contadores >16,7,
  >20 e >33 ms, GPU/CPU viewport se houver dados;
- 1Hz: localização real, velocidade horizontal estimada, fila de
  Voxel workers, blocos, rochas e água, 8 sondas nativas de malha a 130m;
- saída JSON e ZIP pequeno com manifestos e trace original;
- tudo com gates `PERF-60`,
  `STREAM-18`,
  `VIEW-130`,
  `EDIT-100` = **NOT_QUALIFIED**.

A instrumentação é igual em todos os braços de rotas A7/A8 e em uma futura
comparação A/B. Não rodar vídeo, PNG ou recorder junto da medição de frame
deste braço; qualquer comparação futura deve ter captura separada.

## Execução GPU, apenas um piloto

Na máquina GTX 1050 Ti com Windows, Godot custom e DLL A5 já instalados:

    cd "C:\Dev\sandbox-a7-etw"
    git fetch origin exp/a8-perf-stream-view-diagnostic-20261123
    git switch --detach FETCH_HEAD
    powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\a8-pilot-windows.ps1"

O script usa **30 segundos de movimento** após 1000 frames renderizados,
sem alterar o Windows ou ocupar GPU do runner CPU.
Não movimentar a câmera nem cobrir a janela durante o teste.
O arquivo a enviar fica sob
`reports/generated/a8/pilot-<timestamp>-<pid>/a8_pilot_summary.zip`.

Para investigar transição/reversão depois do primeiro resultado, somente
se necessário, o mesmo script aceita
`-Scenario turns_18mps_300s` ou
`-Scenario out_and_back_18mps_300s`,
mantendo 1000 frames de warmup e uma sessão por vez.

## Interpretação e limites

- Um p99 start-to-start acima de 16,7ms é **indício** de problema,
  não isola CPU principal, render thread, GPU ou compositor.
  Mesmo p99 menor não prova PERF-60: o critério exige **todos os frames**
  devidos à aplicação <=16,7 ms no caminho CPU+GPU+present.
- Sonda Voxel `is_area_meshed` em 8 direções a 130 m é
  disponibilidade de blocos nativos, **não** profundidade renderizada.
  Mesmo 8/8 não prova VIEW-130, água, objetos ou costuras.
- Velocidade derivada de amostras 1Hz não prova continuidade de pixels.
  Ela serve para verificar que o roteiro executou aproximadamente 18m/s.
  STREAM-18 exige vídeo/frames e inspeção de lacunas contínua, separada
  da medição de performance.
- `a8_route_triage.py` falha fechado se faltar
  proveniência A5, rota válida, warmup 1000, ausência de capturas, trace,
  contadores ou amostras.
- Não repetir a bateria longa A7.2/4, não alterar threads/LOD ou reduzir
  carga para alcançar uma média de FPS.
- Se o diagnóstico apontar picos e sondas incompletas, próxima fase
  **A8-P1** deverá coletar evidência adicional orientada pelo problema
  (PresentMon/ETW em braço separado e vídeo 60fps em braço de evidência),
  antes de otimizar C++/mesher.

## Checkpoint

A8-P0 começa **sem baseline novo** e com PR draft, sem merge. Nenhum PASS
nem FAIL das metas estritas é declarado a partir da coleta limitada.
