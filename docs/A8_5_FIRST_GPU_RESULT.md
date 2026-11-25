# A8-P5 — revisão independente da captura real GTX 1050 Ti

Data da coleta: **24/11/2026**, branches experimentais; PR #25. Pacote original recebido: `a8_p5_dynamic_depth_evidence.zip`, ~107,64MB, ambos vídeos MKV originais preservados. Commit de ambos os braços: `cf4be42b27cb9b20d7847d73ce15c122003a8a85`. Baseline A5 CPU16 GL Compatibility `0c3fee959576d0a1faec9ceecffb4b132a65558b` não alterada.

## Autenticidade e integridade

- ZIP com 14 entradas e CRC íntegro. Hash **SHA-256 recalculado diretamente dos dois vídeos**, ambos idênticos aos hashes de `a8_p5_review.json`:
  - RGB: 84.406.883 bytes, `203d74d5396d64cae6318d5fd2628be77882195339885b2fae02bccd98798c00`.
  - Depth: 24.694.933 bytes, `d553f73d1e94b279da972773a80972f94718791f14387a68b0ce4c1a05e449cb`.
- Mesma seed 20261119, rota `turns_18mps_300s` de 30s, virada a ~20s, 18m/s, 1920×1080, 14 threads nativas, VSync ativo e GPU GTX 1050 Ti.
- **1000/1000 frames desenhados em cada braço**, aquecimento ~16,74s (RGB) / 16,65s (depth). Cada braço: 1800 intervalos medidos no Godot, 0 intervalos >20ms ou >33ms. Máximo RGB **19,13ms**, depth **19,464ms**. Render GPU p99: 2,161ms RGB e 6,129ms depth (pós-processamento tem custo; medições não equivalem ao tempo de apresentação).
- Calibração de depth real **25m = verde/interior** e **165m = vermelho/exterior**, ambas PASS antes do warmup. Estas duas sondas não certificam erro métrico em todos os pixels.
- Marcadores RGB **31/31**, resíduo de relógio p99 **23ms**; depth **31/31**, resíduo **22ms**.

## Resultado primário: profundidade real no movimento, 30 × 35 pixels

Reprocessamento independente dos **30 frames efetivamente decodificados** do vídeo depth MKV, sem interpolação, extraiu 1050 pixels e reclassificou as cores por canal RGB. **1050/1050 classificações coincidiram com o JSON da coleta.**

| Categoria do SDF procedural esperado | Resultado no depth real dos frames selecionados | Contagem |
|---|---|---:|
| SDF <125m (raio interno seguro) | DEPTH_INSIDE_130 (verde) | **799** |
| SDF <125m | Ausência de depth correspondente | **0** |
| SDF sem hit até 320m | DEPTH_NO_OPAQUE_HIT (azul) | 163 |
| SDF sem hit até 320m | DEPTH_OUTSIDE_130 (vermelho) | 8 |
| SDF sem hit até 320m | cor inválida/limite de compressão | 7 |
| SDF >135m | DEPTH_OUTSIDE_130 (vermelho) | 38 |
| SDF >135m | DEPTH_NO_OPAQUE_HIT (azul) | 17 |
| SDF entre 125 e 135m | DEPTH_INSIDE_130 (verde) | 10 |
| SDF entre 125 e 135m | DEPTH_BORDERLINE_130 (amarelo) | 4 |
| SDF entre 125 e 135m | DEPTH_OUTSIDE_130 (vermelho) | 3 |
| SDF entre 125 e 135m | cor inválida | 1 |
| **Total** | | **1050** |

Os **251 pixels fora da categoria segura** não são uma falha em 130m; são apenas inconclusivos para o aceite interno. Oito cores inválidas estão em 7 `SDF_NO_HIT` e 1 faixa de 125–135m, **zero em SDF <125m**.

**Classificação:** `A8_P5_SAMPLED_DYNAMIC_DEPTH_CONSISTENT_WITH_CAPTURE_LIMITATIONS`. Há evidência dinâmica amostrada positiva no raio interno seguro de 125m, **sem certificação estrita** de 130m/continuidades invisíveis ao gravador.

## Integridade da captura e varredura temporal auxiliar

| Indicador | Vídeo RGB | Vídeo depth |
|---|---:|---:|
| Frames originais capturados durante os 30s da rota | 1767 | 1764 |
| Taxa média registrada | 58,8667fps | 58,7667fps |
| PTS duplicados na rota | 63 | 67 |
| Gaps PTS acima de 33ms | 82 | 90 |
| Maior gap PTS na rota | 50ms | 34ms |

**Análise auxiliar offline**: todos os **1764 frames da rota de profundidade** foram decodificados **sem interpolação**, reduzidos por vizinho mais próximo a 480×270, e classificados por cor categórica (verde <129m, vermelho >131m, azul sem geometria opaca, amarelo transição, resto inválido). Nesse exame foi observada **zero transição direta verde→azul em pares de frames consecutivos**, mas isso é indicador heurístico e não prova de ausência de gaps menores que 4 pixels ou invisíveis pela captura. A maior alteração bruta da máscara esteve na **mudança planejada de direção aos ~20s**, esperada e não indicativa isoladamente de defeito de streaming.

As cópias RGB e depth **são dois percursos separados**, sem paridade exata de frame. Os vídeos têm compressão H.264/NVENC, perdas de PTS/captura, rochas e água visíveis no RGB, mas o depth não identifica identidade de terreno nem prova a publicação simultânea de rochas e água. O teste de depth usa SDF procedural pré-edição, não profundidade de água transparente. **Não afirmar ausência definitiva de falhas em qualquer instante de 18m/s.**

## Decisão

- **Aceitar somente consistência dinâmica amostrada**, sem correção de mesher/worker/LOD nem promoção do checkpoint.
- Encerrar PR #25 sem merge, conservando a coleta e métricas. A5 CPU16 continua baseline de referência.
- Todos os gates **`PERF-60`, `STREAM-18`, `VIEW-130`, `EDIT-100` = `NOT_QUALIFIED`**. FPS do vídeo ≠ FPS apresentado, e overlay depth/SDF/NVENC altera custos.
- Próxima investigação sugerida: A8-P6 **offline-first**, aproveitando o vídeo depth original para verificar frames adicionais em torno de janelas de transições de LOD e curva; reconstruir raios SDF/pose com PTS e margem fail-closed, **sem coletar outra bateria na GPU** a menos que se encontre candidato de lacuna próxima.
