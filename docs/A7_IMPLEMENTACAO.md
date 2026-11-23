# A7 — Bateria final de aceitação do MVP Godot + Voxel Tools

## Escopo
Baseline inalterada: A5 CPU16, GL Compatibility, commit 0c3fee959576d0a1faec9ceecffb4b132a65558b. Nenhuma variante A6 ou A6B promovida. O contrato oficial permanece em docs/CRITERIOS_COMUNS.md. Quatro metas: PERF-60 (frame CPU+GPU+present <=16,7 ms), STREAM-18 (18 m/s sem lacunas), VIEW-130 (130m 360 graus por pixels/profundidade) e EDIT-100 (input aceito até primeiro pixel correto apresentado <=100ms). Sem evidência completa, relatório deve marcar NOT_QUALIFIED; se o custo nativo de edição excede 100ms, EDIT-100 é FAIL.

## Instrumentação implementada
- A7 usa o mundo A5 existente, mesmas seed, geração CPU, mesh_block_size 16, lod_count 4, lod_distance 48m, view_distance 192m e renderizador GL Compatibility. Não altera o C++, stream, UI, água ou rochas.
- Rotas A2 preservadas: stationary_180s, straight_18mps_600s, turns_18mps_300s, out_and_back_18mps_300s. Cenários adicionais: shoreline_180s, cave_180s, rocks_water_180s.
- Coleta start-to-start frame interval p50/p95/p99/p99.9/máximo, frame intervals >16,7/20/33ms, CPU render e GPU viewport se suportados, probes 8 direções a 130m, bloco/LOD, instâncias de rocha, estado da água, contador de tempo até oito sondas processadas e memória/CPU da Godot.
- Edit_idle_100, edit_moving_100 e boundary_edit_100: até 100 chamadas de edição add/sub a 10Hz, coordenadas determinísticas, medição de aplicação nativa, mudança SDF e primeiro frame pós-render, opção de screenshots antes/depois. Rejeições por LOD0 são documentadas, não ocultadas. A chamada simulada não é input HID real. Nem frame_post_draw nem mudança no SDF provam imagem apresentada corretamente.
- Captura de imagem separada de teste de performance, para não inserir overhead de GPU readback na comparação.
- Cada sessão usa save SQLite e JSON de rochas próprios. Os testes preexistentes A3/A4/A5 verificam reabertura em processos independentes com a seed padrão.
- Relatórios: manifest.json, JSONL e JSON por cenário, a7_acceptance_matrix.json, A7_REPORT.md. O compilador é fail-closed e jamais marca PASS estrito automaticamente.

## Rodar localmente
No PowerShell, no repo C:\Dev\sandbox_v2_mvp_godotVoxel:

1. git fetch origin
2. git switch --track origin/feat/a7-final-acceptance-harness-20261120
3. powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\a7-smoke-windows.ps1
4. powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\a7-run-windows.ps1 -Scenario out_and_back_18mps_300s -Duration 60 -Warmup 45
5. powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\a7-run-windows.ps1 -Scenario shoreline_180s -Duration 60 -Warmup 45 -Capture
6. powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\a7-run-windows.ps1 -Scenario boundary_edit_100 -Warmup 45 -Capture

## Campanha integral
Sete rotas x três seeds x três execuções + três cenários de edição de 100 operações x três seeds x três execuções = 90 sessões com aquecimento. A campanha completa pode durar várias horas. Executar apenas em sessão gráfica interativa com 1920x1080 e hardware estável:

powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\a7-run-windows.ps1 -Full -Repeats 3 -Seeds 20261119,20261120,20261121 -Warmup 45

O modo Full não aceita encurtar duração nominal ou reduzir seeds/repetições. Para revalidação dos saves, rodar separadamente:

powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\a7-run-windows.ps1 -Scenario reopen_save

O cenário reopen_save produz a7_reopen.json após a aprovação dos smokes A3/A4/A5; a matriz contabiliza 1/1 sessão funcional, mas conserva os quatro gates gráficos como NOT_QUALIFIED.

Para recompilar o relatório de uma pasta: python .\scripts\a7_report.py .\reports\generated\a7\campaign-YYYYMMDD-HHMMSS-PID

## Limites da qualificação
Sem instrumentação externa correlacionada ao compositor e à apresentação, PERF-60 e EDIT-100 não podem obter PASS estrito. Screenshot simples não mede profundidade do terreno a 130m, nem garante continuidade entre frames. Capturas a 30s não substituem vídeo de toda a rota; usar vídeo/captura externa sincronizada e revisar a presença do solo, rochas e água. Confirmar também colisão após edição sem atravessar o solo, 400 rochas dentro de 130m, voxel equivalente a 0,5m próximo e Windows Release exportável. O smoke usa editor debug e DLL debug e não comprova export Release.

Limitações do MVP já aceitas: rocha promovida com pequena diferença de tamanho/iluminação (A4), inundação global de cavidades secas abaixo de y=0 (issue #7). A6 não promoveu CPU32/GPU devido à lacuna visual em blocos 32 (issue #10). A7 é de aceitação e documentação de falhas, não altera essas decisões.

## Estados possíveis
PASS: exige a medição específica, vídeo/depth/captura e revisão da meta; nunca atribuído automaticamente.
FAIL: resultado comprovado que viola a meta (ex.: aplicação de brush >100ms).
NOT_QUALIFIED: falta evidência essencial; NÃO é PASS.

Aprovação funcional A3–A5 não constitui qualificação dos quatro gates inegociáveis.

## Encerramento funcional A7.2 e sequência de qualificação

A A7.2 foi encerrada em 23/11/2026 como **`FUNCTIONAL_COMPLETE_WITH_LIMITATIONS`**; ver [termo formal e matriz de evidências](A7_2_ENCERRAMENTO_FUNCIONAL.md). Foram realizadas 300/300 chamadas aceitas (100 em repouso, 100 em movimento, 100 em fronteiras), com persistência SQLite e sincronização visual de marcadores. O analisador A7.3 extraiu candidatos de alteração local de pixels das gravações existentes, sem provar o primeiro pixel **correto**.

**Nenhuma campanha A7.2 deve ser repetida por rotina.** Continuam em `NOT_QUALIFIED`: `PERF-60`, `STREAM-18`, `VIEW-130` e `EDIT-100`. A próxima direção, **A7.4**, é um piloto de referência geométrica independente e sincronização de pixels corretos, antes de qualquer nova campanha ampla; os demais três gates exigem suas próprias provas. A etapa A7 como um todo **não** foi formalmente aprovada ou promovida. Baseline A5/CPU16 e PR #16 draft preservadas.
