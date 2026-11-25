# A8-P3 — localização espacial independente dos cinco pops do horizonte

Data: 23/11/2026. Investigação associada à [issue #21](https://github.com/publiomcko-labs/sandbox_v2_mvp_godotVoxel/issues/21). **A8-P2 encerrada** em [PR #20](https://github.com/publiomcko-labs/sandbox_v2_mvp_godotVoxel/pull/20), sem merge; A5 CPU16 inalterada.

## Questão verificável

A A8-P2 observou cinco transições abruptas na silhueta distante, a aproximadamente 3,616; 10,716; 17,816; 22,600; 29,733 s de uma rota com curva a 18 m/s. O espaçamento dos pontos no mundo é da ordem de 128m, compatível com o tamanho de um bloco LOD3 (16 voxels × 8m/voxel).

**Não sabemos a distância horizontal dos pixels que surgiram.** As oito sondas `is_area_meshed` a 130m não medem profundidade nem visibilidade de superfície. Não existe justificativa para otimizar meshers, workers ou LOD antes de resolver a localização espacial.

## Procedimento A8-P3, sem nova captura gráfica

1. Reabrir o vídeo A8-P2 original de SHA256 `1488b6208f47d62f8c9070cf8896e2af0d97c2cbdf440d1bf7df5377f99f621b`.
2. Congelar pares de frames `1288→1289`, `1699→1700`, `2111→2112`, `2380→2381` e `2804→2805`. Em imagens de 960×540 obtidas por redimensionamento de RGB, selecionar pixels antes classificados como céu cinza neutro ~RGB(75,75,75) ±5 e depois como terreno verde G>1,15R, G>1,04B, G>90. Restringir x=[20,939], y=[100,214]; separar em seis bandas horizontais e amostrar dois quantis verticais por banda; converter aos centros de pixels 1080p. Exatamente **12 pixels por evento, total 60**. As coordenadas exatas estão congeladas em `godot/tests/fixtures/a8_p3_video_pixel_targets.json`; o vídeo original não integra o repositório.
3. Em **Godot headless, CPU-only**, reconstruir a câmera da rota canônica: 1920×1080, FOV vertical 75°, inclinação -22°, posição `Routes.position_for(t)`, yaw idêntico ao piloto A7. Consultar o mesmo **gerador procedural SDF congelado** (seed 20261119), sem carregar ou publicar chunks de VoxelLodTerrain e sem ler o framebuffer. Para cada um dos 60 raios, executar `VoxelGeneratorGraph.raycast_sdf_approx` até 320m com stride 0,5m.
4. Projetar o primeiro ponto sólido do SDF ao plano horizontal XZ. Distinguir **SDF_INSIDE_130** se distância horizontal for <129m, **SDF_OUTSIDE_130** se >131m, **SDF_BORDERLINE_130** entre 129–131m, ou **UNKNOWN_NO_SDF_HIT** se não houver amostra válida. Margem de 1m inclui a imprecisão do raycast e do alinhamento de pixel.
5. Registrar a posição do jogador, coordenada XY de cada pixel, distância raycast, hit XYZ, distância horizontal e **coordenada hipotética do bloco LOD3** `floor(hit.x/128), floor(hit.z/128)`. Isso **não é uma inspeção do estado de publicação de malha**. Executar auditoria Python que rejeita fontes/timestamps/contagens/raios inconsistentes e conserva todos os gates estritos em `NOT_QUALIFIED`.

## Execução automática no GitHub Actions

A etapa `A8-P3 independent generator SDF rays on CPU-only headless Godot` é executada **depois dos smokes A0–A7 e do bootstrap A5 nativo**, no runner CPU-only `DESKTOP-T0U6S55`. Saída: `reports/generated/a8p3-ci/a8_p3_procedural_depth.json` e `a8_p3_triage.json`, publicados como artifact `a8-p3-procedural-depth`.

O diagnóstico inicial **não precisa ocupar a GTX 1050 Ti**. Não criar teste visual adicional antes de analisar o resultado do oráculo CPU.

## Limites científicos e próximo gate experimental

Este método localiza **terreno procedural esperado**, não o z-buffer efetivamente renderizado. Não identifica de modo independente uma malha que apareceu, o horário de apresentação de um buffer de LOD3, efeitos de edição/persistência ou a profundidade de água/rochas. O conjunto amostral não cobre todos os pixels que surgiram. O vídeo original tem 58,1fps de captura, 104 timestamps duplicados e 129 gaps PTS >33ms; o erro de alinhamento da sincronização é ~14ms p99.

**Se houver SDF procedural esperado dentro de 130m nos pixels amostrados, a A8-P3 deve solicitar uma única observação gráfica limitada aos mesmos cinco instantes para registrar estado real de `debug_get_mesh_block_info` e presença visual dos blocos previstos antes/depois, sem tocar no streaming.** A mera coincidência com bordas de grid 128m não comprova causalidade. Se todos os raios amostrados ficarem além de 130m, não aprovar STREAM-18 ou VIEW-130: a área não amostrada continua desconhecida.

Status de `PERF-60`, `STREAM-18`, `VIEW-130` e `EDIT-100`: **NOT_QUALIFIED**, sem promoção ou merge de branches experimentais.
