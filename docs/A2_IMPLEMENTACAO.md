# A2 — rota determinística de streaming e instrumentação

## Escopo e estado

Implementação A2 focada em reproduzir e diagnosticar deslocamento contínuo a 18 m/s. Não introduz outro streamer, retenção manual de chunks ou troca de malhas gerenciada pelo projeto; Voxel Tools permanece autoridade única de streaming/LOD/publicação.

A validação visual da A1 foi reportada pelo operador, mas o requisito estrito 130 m / sem fissuras / 60 FPS ainda exige evidência gráfica/temporal formal. A2 inicia pela **medição da baseline nativa**; alterações de prioridade e cache devem ser propostas somente após diagnóstico.

## Trajetórias (18 m/s no relógio monotônico, independentes do teclado e do FPS)

- \`stationary_180s\`: câmera fixa por 180 s.
- \`straight_18mps_600s\`: linha contínua 10.800 m no eixo X por 600 s.
- \`turns_18mps_300s\`: perímetro quadrado com lados de 360 m, curvas de 90° sem pausa por 300 s.
- \`out_and_back_18mps_300s\`: 2.700 m em 150 s e retorno de 2.700 m em mais 150 s.

As posições são \`position_for(route, elapsed)\` — funções puras. Interrupção do motor não desacelera artificialmente a câmera, tornando gaps observáveis. Referência da câmera: posição inicial (0,22,18). Variações de terreno não modificam trajetória, pois é um observador livre, sem colisão (A3 implementará personagem físico).

## Executar benchmark gráfico no Windows

Após \`git fetch\` e \`git switch --track origin/feat/a2-deterministic-streaming-bench-20261119\`:

\`\`\`powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\a2-benchmark-windows.ps1 -Route straight_18mps_600s -Duration 600 -Warmup 45
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\a2-benchmark-windows.ps1 -Route turns_18mps_300s -Duration 300 -Warmup 45
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\a2-benchmark-windows.ps1 -Route out_and_back_18mps_300s -Duration 300 -Warmup 45
\`\`\`

Opcional: \`-Capture\` gera PNGs em intervalos de 30 s (altera a carga e **não** qualifica desempenho). \`-Headless\` é para smoke/diagnóstico apenas, nunca substitui GPU/pixels. \`-Duration 30\` permite uma amostra curta exploratória; NÃO satisfaz a rota canônica.

Padrão de saída: \`reports/generated/a2_<route>_<timestamp>_<pid>.jsonl\` e \`.json\`. Pode ser alterado pela variável de ambiente \`A2_OUTPUT_DIR\`. Diretório permanece ignorado pelo Git.

## Evidência coletada

- Metadados: rota, seed, distância solicitada, 4 LODs, resolução do viewport, renderer.
- Posição por segundo; intervalos entre inícios de frames (p50/p95/p99/p99,9/max; amostras acima de 16,7/20/33ms). **Não** são tempo de frame ponta-a-ponta com GPU/present.
- CPU process e physics process da \`Performance\` Godot, FPS reportado.
- \`VoxelLodTerrain.get_statistics()\` incluindo filas, descarte de loads/meshes e tempos microsegundos; contagem de blocos de dados/malhas.
- 8 sondas radiais a 130m testam \`is_area_meshed\` em LODs 2/3. Isso verifica meshing processado, **não** a apresentação real nem cobertura em pixels.
- Metadata, status de warmup, série e resumo JSON; sem exclusão silenciosa de outliers.

As métricas são coletadas com a mesma instrumentação na baseline e em futuros braços A/B. Captura PNG é um modo separado de evidência, não deve comparar quantis com runs sem captura.

## Gatilhos

| Gate | Regra | Estado na criação |
|---|---|---|
| A2-ROUTES | matemática da rota, ida/volta e descontinuidades nas curvas | PENDENTE CI |
| A2-E2E | runtime headless produz JSONL e sumário válido sem mascarar falta de GPU | PENDENTE CI |
| STREAM-18 | zero lacunas/flicker em rota gráfica completa e reversões | NÃO QUALIFICADO |
| VIEW-130 | profundidade/cobertura efetivamente apresentada em todas as direções | NÃO QUALIFICADO |
| PERF-60 | <16,7ms por frame completo CPU+GPU+present, sem picos induzidos | NÃO QUALIFICADO |
| A2-P99 | análise dos quantis, dropped workloads e buffer churn | NÃO QUALIFICADO |

**Importante:** warmup fixo de 45 s não comprova que o horizonte visual está integralmente preparado. O log indica readiness *não pixel verificada*. O gate de cobertura inicial só pode ser liberado por inspeção gráfica com evidência. Não há pausa automática, teleporte ou neblina para mascarar falhas.

A próxima intervenção após o diagnóstico será comparar política nativa atual contra ajustes controlados de LOD/blocos/prefetch, sem reduzir 130m nem alterar a carga de instrumentação entre braços.


## Reuso verificável do binário nativo da A1

A2 altera apenas scripts, documentação e testes: as quatro fontes de \`native/\` não sofreram alterações. O CI exige hashes Git-blob idênticos aos da A1 aprovada (\`8feb581\`), restaura o artefato \`a0-build-snapshot\` da execução [44507482206](https://github.com/publiomcko-labs/sandbox_v2_mvp_godotVoxel/actions/runs/44507482206) e valida que o editor é a versão pinada no lockfile. Não há recompilação C++ desnecessária nem dependência de MSVC no runner que executa o teste de scripts. **Se o código nativo mudar, o guard deve reprovar e exigir nova compilação/novo artefato.** A disponibilidade do artefato depende da retenção do GitHub Actions.
