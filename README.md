# Sandbox V2 — MVP A | Godot + Voxel Tools + C++

**Estado experimental (23/11/2026):** baseline A5/CPU16 preservada; A7.2 encerrada funcionalmente (`FUNCTIONAL_COMPLETE_WITH_LIMITATIONS`, 300/300 edições aceitas). A7.3 realizou análise offline de pixels. Os gates estritos `PERF-60`, `STREAM-18`, `VIEW-130` e `EDIT-100` permanecem `NOT_QUALIFIED`; nenhuma promoção/merge da PR #16.

MVP independente de sandbox volumétrico 3D com Godot 4.7.2 + Voxel Tools 1.7 integrado e lógica nativa em C++20. Meta final: 60 FPS/16,7 ms por frame completo, movimento contínuo de 18 m/s sem lacunas, raio visual efetivo de 130 m em 360°, edição visível <=100 ms, rochas físicas, água básica e persistência.

## Documentos
- [Especificação técnica do MVP A](docs/MVP_A_GODOT_VOXEL_TOOLS_CPP.md)
- [Contrato comum de requisitos e benchmarks](docs/CRITERIOS_COMUNS.md)
- [A0: bootstrap, execução e gates](docs/A0_IMPLEMENTACAO.md)
- [A1: mundo SDF, cavernas e LOD](docs/A1_IMPLEMENTACAO.md)
- [A2: rotas determinísticas, streaming e telemetria](docs/A2_IMPLEMENTACAO.md)
- [A3: edição C++, SQLite e teste de reabertura](docs/A3_IMPLEMENTACAO.md)
- [A4: rochas em MultiMesh, promoção para RigidBody e estado persistido](docs/A4_IMPLEMENTACAO.md)
- [A5: oceano y=0, empuxo, arrasto, corrente e nado](docs/A5_IMPLEMENTACAO.md)
- [A7: campanha de aceite final e matriz PASS/FAIL/NOT_QUALIFIED](docs/A7_IMPLEMENTACAO.md)
- [A7.2: encerramento funcional (300 edições, limitações e próxima intervenção)](docs/A7_2_ENCERRAMENTO_FUNCIONAL.md)
- [A7.1–A7.3: evidência gráfica, ETW e auditoria de pixels](docs/A7_VISUAL_EDIT_EVIDENCE.md)
- [A8-P0: diagnóstico de FPS, 18 m/s e sondas de 130 m, com warmup de 1.000 frames](docs/A8_0_PERFORMANCE_STREAMING_DIAGNOSTIC.md)
- [A8-P2: prova visual de rotas a 18 m/s e revisão manual de 130 m](docs/A8_2_VISUAL_STREAMING_EVIDENCE.md)

## A0 Windows (PowerShell)
Pré-requisitos: MSVC Build Tools x64, Python 3.12, Git e SCons 4.10.0.
```powershell
py -3.12 -m pip install scons==4.10.0
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\bootstrap-windows.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\smoke-windows.ps1
& .\.tools\godot.exe --path .\godot
```
O bootstrap usa o editor Godot+Voxel Tools oficial do release v1.7, confere SHA-256, baixa `godot-cpp` em commit fixo, gera `extension_api.json` no editor **customizado** e compila `native/` contra esta API. CI inclui verificação estática e smoke headless; **não** classifica teste headless como 60 FPS gráfico.

A1 usa `VoxelGeneratorGraph` determinístico para relevo, túnel curvo subterrâneo e acesso vertical em aproximadamente (x=38,z=0), com um único `VoxelLodTerrain` + Transvoxel. Solicita 192 unidades de view distance e 4 LODs; 130 m efetivamente visíveis e costuras sem falhas precisam de teste gráfico, não de smoke headless. W/A/S/D movem a 18 m/s, E/Q controlam altura; clique esquerdo captura o mouse e Escape libera. Este observador não possui colisão.

Princípios: um único sistema de terreno/LOD, geometria válida retida até substituição, recursos não antecipam terreno, tarefas e publicação limitadas por orçamento e qualificações por benchmark gráfico real. Ver detalhes nos documentos de arquitetura.

## A2 — benchmark gráfico reproduzível (experimental)
Sem substituir o streamer do Voxel Tools. Registra rotas a 18 m/s e métricas de frame/filas/meshing (não confundir intervalos CPU com GPU+present).

\`\`\`powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\a2-benchmark-windows.ps1 -Route out_and_back_18mps_300s -Duration 300 -Warmup 45
\`\`\`

JSONL e resumo aparecem em \`reports/generated/\`. Para capturas periódicas, inclua \`-Capture\`, em execução separada. A aprovação visual 18m/s e 130m efetivos ainda requer inspeção dos resultados.


## A3 — edição nativa e persistência
Novo C++ exige recompilação da GDExtension após mudar para a branch A3:
\`\`\`powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\bootstrap-windows.ps1 -SkipDownload
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\a3-smoke-windows.ps1
& .\.tools\godot.exe --path .\godot
\`\`\`
No jogo, clique para capturar mouse, botão esquerdo remove terreno e direito adiciona; segure até 10Hz, Ctrl+S salva, Esc libera mouse. SQLite padrão: \`user://worlds/a3_v1_seed_20261119.sqlite\`. O smoke usa banco temporário isolado e verifica reabertura em novo processo. A edição aceita somente áreas LOD0 carregadas; falhas não executam brush parcial. **Latência até pixel realmente apresentado e colisão pós-edição ainda exigem qualificação gráfica.**


## A4 — rochas físicas por promoção
A4 parte do checkpoint A3 e mantém o mesmo C++/ABI (sem recompilação nativa). Usa \`VoxelInstancer\` + \`VoxelInstanceLibraryMultiMeshItem\` para renderizar rochas por LOD nativo e marca remoções como persistentes. Pressione **F** mirando o terreno junto a uma rocha (até 24 m) para promovê-la a \`RigidBody3D\`. No máximo 24 corpos ficam fisicamente ativos; os demais promovidos são congelados. \`Ctrl+S\` salva os estados dos corpos num JSON separado, associado à mesma seed; a remoção dos objetos estáticos é salva pelo \`VoxelStreamSQLite\` do terreno. Os relatórios headless verificam contagem de instâncias, física e reabertura, **não** pixels, 130 m efetivos, estabilidade visual ou desempenho.


## A5 — água básica
Uma única superfície transparente acompanha a câmera em y=0 (sem chunks, tiles ou lacunas de LOD). A costa é determinada pela oclusão geométrica do terreno; escavar abaixo da cota zero expõe a água imediatamente, sem remalhar a superfície aquática. \`Area3D\` de 128m de lado calcula empuxo e arrasto de no máximo 24 corpos físicos próximos; rochas de densidade > água afundam. Um canal com corrente prescrita ocupa a faixa \`z≈30 ±7m\`. A água não usa CFD.

A câmera inicia no voo livre original a 18m/s. **G** alterna para \`CharacterBody3D\` (gravidade, colisão de terreno e nado quando imerso); E/Q controlam subida/descida na água. G novamente retorna ao voo original. Não prometer 18m/s *nadando*: o alvo de 18m/s é para movimento terrestre/livre; nado fica limitado a 7m/s. Edição A3, promoção A4 e \`Ctrl+S\` permanecem.

\`\`\`powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\a5-smoke-windows.ps1
& .\.tools\godot.exe --path .\godot
\`\`\`

\`reports/generated/a5-ci\` contém testes de física e de geometria/edição. O CI headless verifica fórmulas, forças, colisão em fixture e correspondência do nível nominal y=0, não pixels, continuidade 130m nem p99 GPU/present.


## A7 — verificação final do MVP A5 CPU16

A7 começa no checkpoint A5 aprovado, preservando a configuração de jogo e excluindo A6/A6B experimentais. Inclui rotas a 18m/s, 3 seeds x 3 repetições, edição 10Hz/100 operações, evidências gráficas opcionais, verificações de persistência e relatórios de aceite rigorosos em reports/generated/a7. O workflow A7 em GitHub Actions valida scripts/contratos e smoke headless, não FPS total nem pixels.

Comandos em docs/A7_IMPLEMENTACAO.md. Entrada individual curta (não qualificatória): powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\a7-run-windows.ps1 -Scenario out_and_back_18mps_300s -Duration 60 -Warmup 45

Campanha completa (90 execuções gráficas): powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\a7-run-windows.ps1 -Full -Repeats 3 -Seeds 20261119,20261120,20261121 -Warmup 45

O relatório não marca as metas PERF-60 / STREAM-18 / VIEW-130 / EDIT-100 como aprovadas sem evidência específica. Limitações de A4/A5 permanecem documentadas; não há alteração do terreno, CPU16, água, física ou streaming.

## A8-P0 — diagnóstico gráfico curto, sem readback

A7.4 foi encerrada sem merge em [PR #17](https://github.com/publiomcko-labs/sandbox_v2_mvp_godotVoxel/pull/17). A8 inicia isoladamente a coleta de desempenho/streaming sobre a baseline A5 CPU16; não altera mundo/LOD/C++ e mantém PERF-60, STREAM-18, VIEW-130 e EDIT-100 como NOT_QUALIFIED.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\a8-pilot-windows.ps1
```

1.000 frames de warmup realmente desenhados, 30 s de trajeto reto a 18 m/s, sem vídeo/PNG/ETW, relatório e ZIP resumido em `reports/generated/a8/`. Ver [escopo e limitações](docs/A8_0_PERFORMANCE_STREAMING_DIAGNOSTIC.md).

## A8-P2 — vídeo separado da medição de FPS

Após o encerramento da A8-P1 sem merge, esta etapa coleta uma única rota com curva e 1000 frames realmente desenhados de warmup, via DDAGrab/NVENC 1080p60 e marcadores de relógio. Nenhuma otimização de workers/LOD é promovida; vídeo não qualifica profundidade a 130m nem PERF-60.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\a8-p2-visual-windows.ps1
```

Resultado: `reports/generated/a7-visual-evidence/evidence-.../a8_visual_evidence.zip` (contém vídeo original). Revisão humana de fissuras, regiões, rochas e água continua obrigatória.
