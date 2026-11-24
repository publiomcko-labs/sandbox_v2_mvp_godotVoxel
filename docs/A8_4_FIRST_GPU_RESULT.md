# A8-P4 — revisão independente da primeira captura real GTX 1050 Ti

Data da captura: **24/11/2026** (08:09 UTC-03; 11:09 UTC). Evidência `a8_p4_depth_evidence.zip`, SHA-256 `37c0906d183a87e3ceabd9350954dcb6df4833b6f122afc54c0720bd23343385`, capturada no commit `7d29dcaecd316afb9bc15ae38b0fd3c4d2e4123b` sob `DESKTOP-SAFGO15`, monitor primário 3440×1440 e render alvo 1920×1080. Baseline A5/CPU16 GL Compatibility sem mudanças.

## Verificação do material original

- ZIP íntegro (CRC OK), **18/18 PNGs** com hash SHA-256 compatível com `a8_p4_review.json`; JSON original com 8 direções × 35 raios = **280 pixels**.
- Warmup **1000 frames realmente desenhados em 16,653 segundos**.
- Calibração de profundidade GPU `25m = DEPTH_INSIDE_130` (verde) e `165m = DEPTH_OUTSIDE_130` (vermelho); **2/2 PASS**. O teste mede distâncias da superfície central de painéis auxiliares e não é validação de erro métrico em todo o z-buffer.
- Todas as 280 cores categóricas da profundidade nos **PNGs reais** correspondem às categorias dos respectivos registros JSON (0 divergências). Os 8 screenshots RGB contêm o terreno verde e os 8 depth screenshots mostram a silhueta opaca correspondente.

## Comparação independente com SDF esperado

| Direção (yaw) | Esperados dentro de 130m | Depth dentro de 130m nesses pixels | Falhas |
|---|---:|---:|---:|
| 0° | 26 | 26 | 0 |
| -45° | 28 | 28 | 0 |
| -90° | 27 | 27 | 0 |
| -135° | 27 | 27 | 0 |
| -180° | 27 | 27 | 0 |
| -225° | 27 | 27 | 0 |
| -270° | 26 | 26 | 0 |
| -315° | 28 | 28 | 0 |
| **Total** | **216** | **216** | **0** |

Os 64 outros raios ficaram em categorias:

- 52: SDF sem interseção até 320m / depth sem geometria opaca;
- 10: SDF esperado além dos 130m / depth além de 130m;
- 1: SDF sem interseção até 320m / depth indicando geometria opaca além de 130m (**heading 3, pixel [720,280]**);
- 1: SDF a **131,528m** / depth na faixa de tolerância **129–131m** (**heading 5, pixel [240,400]**). Isso indica diferença na classificação de distância perto do limite, mas **não falta de terreno dentro de 129m**.

Verificação adicional diretamente nos 8 pares de screenshots completos (total **16.588.800 pixels** por modalidade): a máscara heurística de terreno verde da imagem RGB coincidiu com a máscara de geometria opaca do depth em todos, exceto **3 pixels de silhueta**, situados nos headings 1 e 3, junto ao limite céu/terreno. É consistência de imagem e depth, **não** prova independente da malha procedural nem validação de 16,6 milhões de raios SDF.

## Veredito delimitado

`A8_P4_SAMPLED_STATIC_DEPTH_CONSISTENT`: **216/216 interseções SDF esperadas dentro de 130m têm depth opaco classificado dentro de 130m; calibração 25m/165m passou e os dados PNG/JSON coincidem.** Há duas diferenças de classe em raios não cobertos pelo requisito interno, conforme descrito acima.

A A8-P4 apenas demonstra **consistência estática amostrada em um ponto do mundo (x=192,y=22,z=18), seed 20261119, oito headings**. Não demonstra cobertura total de todas as direções/pixels, estabilidade temporal a 18m/s, ausência de fissuras subpixel, identidades de malha, rochas/água (ocultadas neste teste), nem orçamento de FPS. Screenshot GPU readback altera a performance e não pode ser usado como métrica PERF-60.

**Decisão:** encerrar a A8-P4 como piloto de evidência positiva sem merge/promoção da A5 CPU16. `PERF-60`, `STREAM-18`, `VIEW-130`, `EDIT-100` permanecem `NOT_QUALIFIED`. Próxima investigação justificada: **A8-P5**, continuidade de rasterização/depth dentro de 130m **ao longo da rota de 18m/s**, com captura e medição de desempenho em braços separados, mantendo mesmo conteúdo do mundo, seed e condições de render. Não reabrir investigação LOD3 no horizonte opcional sem evidência no raio obrigatório.
