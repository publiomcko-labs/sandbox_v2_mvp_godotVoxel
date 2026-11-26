# V3.0 — investigação direcionada do pico (2026-11-26)

Status: **DIAGNOSTIC_IMPLEMENTED_PENDING_REAL_GPU**. Base V3: 4977fb5fcce723712586db567d8c618d2d945d41. Main c60e9fb33e7ce229d666496e2583d7c9f9ceaaba e checkpoint A5 0c3fee959576d0a1faec9ceecffb4b132a65558b preservados. Nenhuma alteração de gameplay, SDF, mesher, LOD, threads, colisores, física ou código nativo.

## Auditoria e hipótese

- Harness survey46 original: 165a1b73ca2fc4e10187830ce44b40d71fd9b93b. 12 s warmup, 46 s total, 18 m/s, virada aos 30 s, seis brushes aos 25/28/31/34/37/40 s. Pico histórico 143,75 ms ~24,60 s, antes do primeiro brush. Não implica que o brush seja causa; nem a proximidade com sondas a 1 Hz constitui causalidade. Dados históricos agregados não incluem o trace bruto.
- A7/A8 (b38b66e1193c88a5c1976cb99042760bceb97e1b): telemetria de VoxelEngine e terreno, PresentMon 2.6.0, guard de sessões ETW, análise de relógios e perdas. A8-P7 tem rota/warmup diferentes; não importar seus shaders, overlays ou vídeo. Reusar guard e parser de timestamps originais.
- CI histórica: comparação portable #45712601221 e A5 main #45616597100 com sucesso; não comprovam GPU. Runner interactive-gpu previsto na A7; disponibilidade atual ainda não confirmada.

## Execução

Estender o survey existente com flag opt-in V3Trace. Armazenar tempos monotônicos de callback (movimento/câmera, brush, sondas, coleta contextual), contadores VoxelEngine/terreno/memória/física a 1 Hz; buffer limitado com overflow explícito, sem serialização durante a janela. Âncoras monotônico/UTC para comparação com PresentMon por PID. Frame-start gap abrange callback anterior; reportar resto como não atribuído, nunca convertê-lo em custo de GPU ou CPU. PresentMon 2.6.0 com SHA fixo, nenhuma elevação automática, guard A7, sem vídeo/readback, logs e status de coleta preservados. Não há ainda instrumentação de jobs internos de geração/meshing/upload/colisores/I/O ou scheduler Windows por thread; somente se houver evento reproduzido e evidência insuficiente, usar a terceira rodada para aprofundar a janela suspeita, sem otimização especulativa.

Workflow v3-0-survey.yml: contratos/reducer e parse PowerShell, depois desktop real no host alvo. Duas rodadas cold: controle sem trace/ETW e trace+ETW. Comparar p99 e máximos, integridade e hardware/binaries. A diferença entre rodadas é uma estimativa conjunta de efeito e variância, não isolamento causal de overhead. Uma terceira rodada no máximo, se necessária (trace sem ETW ou trace focal por subsistema, nunca repetir bateria integral). Se nenhuma ocorrência comparável >=100 ms aparecer, documentar não reproduzido nas rodadas válidas, sem atribuição e seguir V3.1; limiar diagnóstico não comprova identidade do pico original. Se houver candidato, examinar janela e dados antes de decidir intervenção. Se coleta inválida, manter INCONCLUSIVE e contabilizar qualquer rodada que efetivamente iniciou survey. Não executar campanha automaticamente após esta investigação.

Metadados, CSV, logs e triage.json ficam em reports/generated/v3/. Não publicar saves. ETW alinhado apenas com cobertura e swapchain dominante, dados GPU, ausência de perdas conhecidas e relógio estável; contadores ausentes não significam zero. Associação por proximidade não significa identidade de frame. Gates PERF-60, STREAM-18, VIEW-130, EDIT-100 permanecem NOT_QUALIFIED.

## Execução local (somente se runner indisponível ou preflight falhar)

Usar checkout isolado V3, Godot/DLL A5 pinados, Python e PresentMon 2.6.0 verificado, Windows interativo no mesmo host e token ETW válido. Não executar se o workflow gráfico já tiver iniciado os surveys, para respeitar o teto de três. Para cada braço:
- `scripts/comparison-v1-windows.ps1 -Profile cold -OutputRoot reports/generated/v3/control`
- `scripts/comparison-v1-windows.ps1 -Profile cold -OutputRoot reports/generated/v3/traced -V3Trace -PresentMonExe C:\CAMINHO\PresentMon.exe`
- `python scripts/v3_0_triage.py --control <pasta da rodada controle> --traced <pasta da rodada trace> --out reports/generated/v3/triage.json`

## Checkpoint

Preparação diagnóstica, não encerramento da V3.0. Causa, reprodução, overhead e resultado gráfico pendentes de evidência real; sem otimização.

### Resultado CI inicial — 26/11/2026
Run [45824145413](https://github.com/publiomcko-labs/sandbox_v2_mvp_godotVoxel/actions/runs/45824145413), commit 77b7a6d: 8/8 testes de comparação PASS; compilação sintática Python e parse PowerShell PASS. Runner DESKTOP-SAFGO15 encontrado, preflight falhou em Session 0. Nenhuma rodada de survey iniciada. Status GPU: BLOCKED_INTERACTIVE_SESSION; causa UNATTRIBUTED. Corrigida tolerância de comparação temporal CSV/trace para 5 µs devido ao armazenamento de t_s no Vector2 float32 original (sem alterar os dados). A execução local reutiliza o mesmo harness, com dois braços e ZIP sem saves. Esta atualização não dispara nova campanha automaticamente.
