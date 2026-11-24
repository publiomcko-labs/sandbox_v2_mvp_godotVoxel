# A8-P7 — medir cauda extrema dos frames e tempo de apresentação

24/11/2026 — Issue [#29](https://github.com/publiomcko-labs/sandbox_v2_mvp_godotVoxel/issues/29). Base A5 CPU16/GL Compatibility imutável: `0c3fee959576d0a1faec9ceecffb4b132a65558b`. A8-P6 ([PR #28](https://github.com/publiomcko-labs/sandbox_v2_mvp_godotVoxel/pull/28)) foi auditoria **visual** e não medição independente de frames apresentados.

## Por que as metas são extremas?

O [contrato do MVP](CRITERIOS_COMUNS.md) exige **60 FPS com nenhum frame causado pela aplicação acima de 16,7 ms** nos percursos de aceitação, não uma simples média ou p99. Em VSync a 60 Hz um intervalo de 16,667 ms é nominal, restando margem operacional muito pequena. Uma única ocorrência validada de causa da aplicação além de 16,7 ms impede PASS nessa execução; eventos atribuíveis a compositor, SO, janela, ETW ou scheduler exigem **classificação e investigação**, nunca descarte silencioso.

A8-P7 **não altera a meta**, mas reporta três planos separados:

1. **Contratual:** orçamento 16,7 ms incluindo CPU+GPU+apresentação; exige causa identificada e campanha qualificatória (três seeds, três repetições, rotas longas). Um piloto isolado jamais tem PASS automático.
2. **Engenharia:** distribuição real apresentada p50/p95/p99/p99,9/máximo, frequência e concentração de intervalos >16,7/>20/>33/>50/>100 ms, maior sequência consecutiva e perda de throughput. Ganho prático pode ser válido mesmo com gate não qualificado.
3. **Diagnóstico:** tempos `CPUBusy`, `FrameTime`, `GPUTime`, `DisplayLatency`, contadores internos de Godot, `VoxelEngine.get_stats` a 1 Hz, blocos de dados e meshes, água/rochas, filas de workers. Correlacionar **não prova causalidade** de remeshing, geração, upload ou driver.

**Nunca confundir:** `FrameTime` (PresentMon), `GPUTime`, `DisplayLatency`, `DisplayedTime`, intervalo calculado entre atualizações de tela no mesmo swapchain, e callback start-to-start do Godot. Nenhum campo, isoladamente, garante duração ponta a ponta do frame completo causada pela aplicação ou o instante exato de apresentação do pixel correto.

## Implementação piloto sem recorder

- Rota `turns_18mps_300s` limitada a **30 s de movimento**, seed20261119, 18m/s, virada aos 20s; **1.000 frames realmente desenhados** de warmup; VSync ON, GL Compatibility/OpenGL3, 1920×1080, mesh16, 4 LOD, Voxel workers automáticos.
- A7 runner recebe `-A8P7Performance`, exige `-WarmupFrames 1000 -Warmup 0 -Duration 30 -ResourceTelemetry -PresentMonExe` e **proíbe** screenshots, captura NVENC, P5 depth overlay, headless, Full, mudanças de threads ou seed/rota. Qualquer violação falha antes do launch.
- PresentMon standalone **2.6.0** oficial vinculado ao PID do Godot, SHA-256 `b2a706bc6ad475749e3b7e3409263aa1e6906d45bdcf993f6dbc0f660188f1af`; ETW de GPU habilitado. O guard A7 detecta/saneia apenas sessões próprias; não eleva permissões nem muda grupos Windows. Se o token não tiver `Performance Log Users`, falha antes do teste, sem fingir ETW.
- Godot conserva a instrumentação 1Hz canônica dos testes A7/A8; eventos de callback **>16,7 ms** são colocados em memória (máx. 4096, overflow explícito) e só serializados ao encerrar, para não adicionar IO por frame. São eventos distintos dos frames apresentados.
- O relatório `a8_p7_present_report.py` exige proveniência A5/CPU16, warmup, um único braço, sincronização ETW válida, swapchain dominante >=90%, GPUTime presente, ausência de perdas ETW **conhecidas**, 30s de janela, e distribuições sem inventar frames. Marca `etw_loss_counters_explicit_zero=false` caso o provedor não reporte valores concretos. Mantém eventos de apresentação como picos **sem atribuição causal automática**, associando o estado de trabalhadores mais próximo em 1Hz apenas como contexto.
- O teste CPU-only do Actions usa ETW CSV **sintético**, inclusive picos de apresentação, PTS de relógio, perdas ETW, warmup falso, screenshot indevido e promoção de gate falsa. **Não fornece resultado gráfico.**

## Execução na GTX 1050 Ti — piloto único (não repetir bateria)

No terminal PowerShell interativo com a janela principal desbloqueada, monitor >=1920×1080, runtime A5/CPU16 já instalado:

```powershell
cd "C:\Dev\sandbox-a7-etw"
git fetch origin exp/a8-7-extreme-frame-presentation-probe-20261124
git switch --detach FETCH_HEAD
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\a8-p7-present-windows.ps1"
```

O script localiza `PresentMon.exe` nas pastas conhecidas ou baixa o release **verificando SHA antes de executar**. Exige que a sessão Windows interativa tenha permissão ETW (`Performance Log Users` ou admin); **nunca eleva, altera grupos ou inicia campanha longa automaticamente**. Se não houver permissão, enviar a mensagem exata de erro, sem modificar permissões por tentativa.

O script roda uma única sessão de 1000 frames de warmup + 30s a 18m/s, grava dados ETW nativos, status, métricas de jogo e relatório. Compacta a evidência sem alterar o CSV original e produz um ZIP mesmo no caminho de falha depois de iniciar o piloto:

`reports/generated/a8-p7/pilot-.../a8_p7_performance_evidence.zip`

Enviar o ZIP (ou erro de preflight se ocorrer antes da criação). Pode ter dezenas de MB. Nenhum ajuste permanente no Windows.

## Decisão após coleta

1. Se ETW não alinhar, perder eventos/buffers ou não fornecer `GPUTime`, **não tirar conclusões sobre frames apresentados**. Diagnosticar permissão/collector, sem repetir automaticamente duração maior.
2. ETW válido + picos >16,7 ms: localizar timestamps e testar se coincidem com filas de workers e atividade de meshes; nunca descartar um pico só porque a média é 60fps ou o p99 parece bom. Se a instrumentação de 1Hz não localizar a causa, coletar trace de subsistema **apenas nas janelas suspeitas**, com controle de overhead equivalente em A/B.
3. Somente após evidência de causa planejar A8-P7.1 corretiva focalizada de geração, mesher, upload, driver, colisores ou scheduling. O alvo final requer `PERF-60`, `STREAM-18`, `VIEW-130`, `EDIT-100` qualificados separadamente. Não trocar FPS por redução da distância de visão, rochas ou qualidade de água.

**Status inicial:** metodologia e piloto experimental preparados; resultados reais da GPU são `NOT_MEASURED` até o ZIP. Todos os gates contratuais permanecem `NOT_QUALIFIED`, PR draft sem merge; testes de milhões de edições e rochas estão em [#27](https://github.com/publiomcko-labs/sandbox_v2_mvp_godotVoxel/issues/27).
