# A8-P6 — auditoria offline de todos os frames capturados com SDF nativo independente

Data: 24/11/2026. Issue [#26](https://github.com/publiomcko-labs/sandbox_v2_mvp_godotVoxel/issues/26). Derivada da A8-P5 ([PR #25 encerrado sem merge](https://github.com/publiomcko-labs/sandbox_v2_mvp_godotVoxel/pull/25)), cujos dois vídeos originais RGB e depth foram preservados e SHA-256 verificados.

## Objetivo e escopo

Continuar a investigação do raio visual de 130m **sem nova gravação GPU, sem edit/collision/LOD otimização e sem atualizar A5 CPU16**. A A8-P5 observou 799/799 amostras seguras com depth opaco e zero lacunas nessas amostras, mas a avaliação cobriu somente 30 instantes; video depth possui 1764 frames no trecho, 67 timestamps duplicados, 90 gaps PTS >33ms e ~58,77fps capturados. Isso não é performance apresentada.

## Braços independentes

**Oráculo CPU (GitHub Actions headless):** `godot/tests/a8_p6_sdf_frame_oracle.gd` recompila o gerador nativo do terreno A5/seed20261119, aplica trajetória canônica `turns_18mps_300s` e câmera 1920×1080, FOV75°, pitch -22°. Calcula distâncias horizontais até primeiro hit SDF (raio máximo 320m, passo 0,5m) para **sete pixels fixos** nos **1.800 instantes de 60 Hz**, total **12.600 raios independentes esperados**; não carrega malhas ou renderer. Coordenadas amostradas [240,400], [960,400], [1680,400], [480,640], [960,640], [1440,640], [960,760]. Salva `a8_p6_expected_sdf_60hz.json` (centímetros horizontais, -1 sem hit), entrega como artifact `a8-p6-60hz-expected-sdf`. O CI verifica cardinalidade, semântica, seed e todos os gates NOT_QUALIFIED.

**Vídeo GPU já coletado (análise local CPU):** `scripts/a8_p6_offline_review.py` recebe o ZIP original A8-P5 (2 vídeos RGB/depth NVENC 1920×1080) e o artifact SDF. Verifica hashes SHA-256 do par, seed/branch, 31 marcadores HUD com p99 <50ms, relógio e intervalo de 1.764 frames capturados, reextrai PTS do MKV sem criar frames e decodifica cada frame 1080p. Para cada pixel fixo, associa ao índice SDF 60Hz pela **interpolação entre dois marcadores consecutivos**, recusando duplicatas de PTS, ±40ms ao marcador, ±150ms à curva ou fim de rota e tempos fora do grid.

**Margem de segurança:** trata somente SDF esperado **<120m** como área segura para comparação categórica com depth verde (<129m). A folga de 9m não comprova os últimos 10m do requisito de 130m; PTS/HUD e reconstrução da pose podem diferir. Classificação vermelho/azul quando SDF <120m é **candidato de ausência** (não falha comprovada); amarelo/cores H264 ambíguas são desconhecidos. Nada fora desses pontos transforma ausência de candidato em PASS.

**Scan visual temporal auxiliar:** cada frame é também reduzido a 480×270 por nearest-neighbor, capturando quantidade de mudanças verde→azul e verde→vermelho em ROI sem HUD. Essa heurística localiza janelas a examinar, mas não diagnostica lacunas em resolução nativa sem oráculo SDF nos respectivos pixels. RGB e depth são **dois percursos diferentes**, não pares de mesmo frame.

## Execução

**GitHub CPU:** CI valida o oráculo e publica `a8-p6-60hz-expected-sdf` (sem GPU). Não publicar os MKVs privados no GitHub.

**Auditoria local em Python (com numpy, opencv-python e ffprobe):**

```powershell
python scripts/a8_p6_offline_review.py --evidence "a8_p5_dynamic_depth_evidence.zip" --oracle "a8_p6_expected_sdf_60hz.json" --out "reports/generated/a8-p6-offline"
```

Saídas `a8_p6_independent_review.json` e `a8_p6_all_frames.csv`, com contagens de pixels seguros, desconhecidos, gaps do gravador, eventos suspeitos e proveniência. Não repetir o vídeo da GTX 1050Ti antes de avaliar isso.

## Regras de conclusão

- `NO_IN_RADIUS_MISMATCH_ON_CONFIDENT_RAYS_ONLY`: nenhuma inconsistência nos raios SDF confiáveis <120m **observados**. Isso não prova ausência de buracos em todos os pixels/frames não apresentados. `VIEW-130`, `STREAM-18` permanecem NOT_QUALIFIED.
- `POTENTIAL_IN_RADIUS_MISMATCH_REQUIRES_SOURCE_FRAME_TRIAGE`: conservar frame/PTS/pixel e inspecionar vizinhos em resolução original; verificar a hipótese de geomatria ausente versus temporal/codec/oclusão e só então avaliar uma reprodução gráfica pontual.
- `PERF-60` e `EDIT-100` também permanecem `NOT_QUALIFIED`; não se mede apresentação da aplicação, input→pixel correto ou publicação de água/rochas nesta fase.

Baseline A5/CPU16, mesher, LOD, trabalhadores, banco SQLite e política de persistência **não são modificados**. Ações de escalabilidade de milhões de edições/rochas estão registradas separadamente na [issue #27](https://github.com/publiomcko-labs/sandbox_v2_mvp_godotVoxel/issues/27), para execução futura, sem comprometer esta auditoria.
