# A8-P2 — revisão independente do vídeo da GTX 1050 Ti

Data da coleta: 23/11/2026. Evidência: `a8_visual_evidence.zip`, 90.366.829 bytes de vídeo MKV.
SHA-256 do vídeo original: `1488b6208f47d62f8c9070cf8896e2af0d97c2cbdf440d1bf7df5377f99f621b`.

## Procedimento e proveniência

- Git SHA da coleta: `98f7a53f9a6755945798edde3805f6656e0b42ae`; baseline funcional A5 CPU16 `0c3fee959576d0a1faec9ceecffb4b132a65558b`, `turns_18mps_300s` abreviado a 30 segundos; seed 20261119, 1920×1080, GTX 1050 Ti.
- Warmup: 1000/1000 frames desenhados em 16,672s. Jogo: 1800 frames em 30s, p99 start-to-start 17,936ms, máximo 19,830ms, **0 >20ms, 0 >33ms**. Render viewport p99 CPU 2,065ms/GPU 1,807ms, medidores não equivalem ao caminho completo de apresentação.
- Sondas `is_area_meshed` a 130m: 8/8 nos checkpoints, não medem pixels.
- Vídeo: 2855 frames ao longo de 51,067s (inclui inicialização e warmup); trecho de rota 1744 frames em 30s, **58,1fps observados**, 104 timestamps duplicados e 129 intervalos PTS >33ms (máx 34ms). 31 marcadores alternados 31/31, alinhamento de relógio p99 residual 14ms. A captura não representa cada frame realmente apresentado; não confundir defeitos PTS de FFmpeg com falhas do jogo.
- Revisão: vídeo original examinado em amostras por segundo e em sequências de quadros nos cinco pontos destacados; análise auxiliar de 2855 frames a 320×180 com classificação de pixels verdes, candidatos reinspecionados no vídeo 960×540. O critério auxiliar identifica **aparecimento súbito de verde na faixa distante** `y=70..219` (em 960×540) com pouca mudança `y>=350` no mesmo par de quadros. Não é prova independente de geometria correta ou de profundidade.

## Candidatos visuais de surgimento abrupto no horizonte distante

| Quadro antes → depois | Tempo relativo aproximado | Posição (x,z) aproximada | Novos pixels verdes na faixa distante | Novos pixels verdes na faixa próxima |
|---|---:|---:|---:|---:|
| 1288→1289 | 3,616 s | (65,09;18,00) m | 9,05% | 0,66% |
| 1699→1700 | 10,716 s | (192,89;18,00) m | 4,55% | 0,50% |
| 2111→2112 | 17,816 s | (320,69;18,00) m | 7,13% | 2,53% |
| 2380→2381 | 22,600 s | (360,00;64,80) m | 9,53% | 1,14% |
| 2804→2805 | 29,733 s | (360,00;193,19) m | 6,06% | 0,66% |

O padrão espacial nas retas é aproximadamente `64 + 128n` metros em X, e depois em Z, compatível com o **comprimento horizontal hipotético de 128m de um bloco LOD3** se `mesh_block_size=16` e `LOD3=2³m/voxel`. Esta é uma **hipótese**, não uma demonstração de revisão/publicação específica do Voxel Tools. A virada planejada na trajetória aos 20s (aprox. frames 2230–2231) foi **excluída** dos cinco candidatos: a câmera gira legitimamente, alterando a imagem próxima e distante ao mesmo tempo.

### O que pode e não pode ser afirmado

Há **cinco transições abruptas visíveis na silhueta distante** durante o deslocamento, sem evidência nestes pares de desaparecimento completo do terreno próximo. As sequências também mostram rochas/água desenhadas nas amostras, mas **não demonstram publicação atômica em todos os 1744 quadros**. A periodicidade sugere mudanças de LOD distante, e não um problema de VSync ou GPU dominante.

A profundidade horizontal **dos pixels recém-surgidos é desconhecida**. Não afirmar que as transições ocorrem dentro de 130m: podem estar no horizonte opcional além do raio de aceite. A observação de cor não comprova fissura, profundidade, nem se alguma transição é proibida pelo contrato. A captura a 58,1fps não permite assegurar ausência total de falhas subframe; 100% dos quadros apresentados pelo jogo não foram observados.

**Decisão:** A8-P2 conclui como `DISTANT_HORIZON_TRANSITION_CANDIDATES_WITH_CAPTURE_LIMITATIONS`, não como falha/passe estrito. `PERF-60`, `STREAM-18`, `VIEW-130` e `EDIT-100` permanecem `NOT_QUALIFIED`. Baseline A5 CPU16 e PR experimental não são promovidos.

## Próxima hipótese A8-P3, antes de alterar mesher/LOD/workers

Localizar a **distância horizontal real** da geometria afetada em relação à câmera (principalmente dentro/fora de 130m) e correlacionar com publicações LOD3 nas bordas dos blocos de 128m. Instrumentação dedicada e limitada às cinco janelas acima; mesmos parâmetros de jogo. Se os pops forem exclusivamente fora dos 130m exigidos, classificá-los como qualidade visual opcional, não como bloqueadores do MVP. Caso atinjam o raio requerido, somente então propor correção de publicação/LOD com controle A/B de custos e de continuidade visual.

Nenhum teste de edição A7.4 deve ser repetido; não há justificativa para otimizar Voxel Tools antes da prova causal e da localização espacial dos candidatos.
