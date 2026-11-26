# Encerramento V3.0 — 26/11/2026

**V3_0_COMPLETE_NOT_REPRODUCED_WITH_LIMITATIONS**. Causa histórica UNATTRIBUTED. Sem intervenção corretiva no runtime. Duas rodadas de survey gráfico cold consumidas; terceira não necessária. CI inicial bloqueou Session 0 antes de iniciar qualquer rodada; não somar como benchmark.

| Métrica | Controle | Instrumentado |
|---|---:|---:|
| Intervalos | 2039 | 2038 |
| FPS por intervalos | 59,968 | 59,968 |
| p95 ms | 17,472 | 17,497 |
| p99 ms | 17,944 | 17,974001 |
| 1% low FPS | 54,129 | 54,198 |
| Máximo ms | 22,957001 | 20,665001 |
| >20 ms | 2 | 1 |
| >33 ms | 0 | 0 |
| Brushes aceitos/requeridos | 6/6 | 6/6 |
| Brush síncrono máximo ms | 6,554 | 6,349 |
| Sondas de malha mínimas/8 | 6 | 6 |
| Persistência | completed | completed |

Dados recalculados dos CSV do ZIP recebido, não da triagem automática: ambos COMPARISON_V1_DONE, sem stderr Godot, mesmo Godot 4.7.2 custom ed1daf0bf, OpenGL 3.3 NVIDIA 581.57, GTX 1050 Ti, seed 20261119, LOD4, distância 192. Logs e dados corroboram conclusão funcional apesar das falhas de supervisão do PowerShell. Metadados contemporâneos e hashes completos dos binários ausentes; comparação descritiva, não prova de overhead. P99 variou +0,030001 ms; não há evidência de regressão relevante. PresentMon não forneceu CSV nem status; stdout/stderr apenas BOM UTF-16. Causa da falha do coletor não identificada pelo pacote; apresentação física NOT_MEASURED. O código de saída da segunda execução não foi recuperado do ZIP; os dados do jogo são completos. Não presumir que ETW rodou efetivamente nem tentar inferir GPUTime.

Trace interno: 2038 linhas, 34 amostras contextuais, zero overflow/descontinuidade, erros máximos de correspondência 1 µs (intervalo) e 2 µs (t_s), drift de âncora 0,663 ms. Maior intervalo do braço instrumentado 20,665001 ms aos 24,243319 s, callback anterior movimento 0,010 ms, edição 0,006 ms (sem brush), sonda 0,000 ms, coleta 0,001 ms; restante 20,648 ms não atribuído. Maior trecho de movimento/câmera 0,072 ms, brush/raycast 7,816 ms, sondas 0,052 ms, contexto 0,064 ms. Contadores de worker e terreno a 1 Hz não são spans de jobs. Picos de delta reportados pelo bootstrap nos primeiros cinco segundos (133,33 e 137,19 ms) pertencem ao warmup e não são o pico de 24,60 s. Não misturar delta do motor e intervalos monotônicos.

Nenhum intervalo >=100 ms na janela medida nas duas rodadas. O evento histórico de 143,75 ms aproximadamente aos 24,60 s permanece não reproduzido e sem atribuição; não é falha corrigida. Não executar terceira rodada só para reparar o ETW, pois isso não responderia uma pergunta causal reproduzida. Reabrir investigação caso recorrência material observada na V3, com instrumentação focalizada, sem vídeo e com coleta ETW validada. O projeto segue V3.1. PERF-60, STREAM-18, VIEW-130, EDIT-100 continuam NOT_QUALIFIED.

## Proveniência (arquivos externos não versionados)

ZIP v3_0_evidence(1).zip SHA256 19695939f41eb5a4e897d285786452b8a32e72b7cb60d055763b4cee1263e9ff.
- Controle frames.csv: 365662d309b2e1cca61db5c5136e352c51273e8e855b1aeb66df8cf02c27a144.
- Instrumentado frames.csv: 810ca062b1a610dd9a7cf279a19d2c5972702801ae7253a6e87e469ac6b1e1e2.
- v3-trace.csv: 1fd8b9f5b68efd7ae76a4165511c9d6dd26274594c8b5fa8adcd50660cd93382.
- v3-trace.csv.json: f0bbb2da6fb0a2bb6f2016374fb8957c6f7efc4512d211732c84bc2c9c11a3e5.

Harness preparado em 77b7a6d, retomada 5a22dde. Main c60e9fb33e7ce229d666496e2583d7c9f9ceaaba, A5 0c3fee959576d0a1faec9ceecffb4b132a65558b preservados. Checkpoint de encerramento não representa export ou aprovação de desempenho gráfico estrito.
