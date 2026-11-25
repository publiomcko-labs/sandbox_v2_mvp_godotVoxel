# A3 — edição volumétrica nativa, save SQLite e reabertura

## Escopo
Implementação da fase A3 sobre a baseline A2 aprovada visualmente pelo operador, sem alterar a geração SDF, políticas de streaming nativas, LODs ou alcance de 192 m configurado.

- Brush C++20 \`WorldBootstrap.edit_sphere(center, add, radius)\` usa \`VoxelTool.MODE_ADD / MODE_REMOVE\` e \`do_sphere\`, com rejeição explícita se \`is_area_editable\` falhar para todo volume do brush (LOD0).
- Raio interativo 1,5 m; controle por mouse até 10 Hz. Botão esquerdo subtrai, direito adiciona. Primeiro clique captura o mouse. Pressionar Ctrl+S inicia save e acompanha \`VoxelSaveCompletionTracker\`; Godot também aguarda operações pendentes no encerramento normal.
- \`VoxelStreamSQLite\` configurado na entrada da árvore, antes do primeiro streaming. Salva somente blocos alterados, sem salvar toda a saída determinística do gerador. Default \`user://worlds/a3_v1_seed_20261119.sqlite\` (seed versionada); \`A3_SAVE_PATH\` permite isolação de testes.
- Colisão habilitada somente em LOD0, pelo viewer; a câmera atual permanece livre e não há \`CharacterBody3D\` nesta fase.
- Telemetria de tempo síncrono do brush \`get_last_edit_apply_ms\` e marca temporal monotônica. **Não** representa o primeiro frame apresentado. Nenhuma alegação de ≤100 ms visual em headless.

## Gate e evidência
| Gate | Procedimento | Estado inicial |
|---|---|---|
| A3-NATIVE | Compilar nova DLL C++ contra API Godot custom pinada; A0/A1/A2 regressões | Pendente CI |
| A3-BRUSH | Rejeita área indisponível; subtrai matéria; adiciona matéria; borda de bloco | Pendente CI |
| A3-SAVE | Gravar SQLite, aguardar tracker concluir e reabrir em outro processo Godot | Pendente CI |
| EDIT-100 | Input → **frame apresentado visualmente correto** ≤100 ms, inclusive borda e movimento | Pendente gráfico |
| A3-COLLISION | Sem atravessamento após atualização dos colliders LOD0 | Pendente gráfico |
| STREAM-18/VIEW-130 | Sem regressão de cobertura/streaming em 18m/s com colisores ativos | Pendente gráfico |

## Teste local (PowerShell)
\`\`\`powershell
git fetch origin
git switch --track origin/feat/a3-native-sdf-edit-sqlite-20261119
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\bootstrap-windows.ps1 -SkipDownload
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\a3-smoke-windows.ps1
& .\.tools\godot.exe --path .\godot
\`\`\`

O runner A3 deve possuir MSVC x64; o compilador é indispensável porque a API C++ nativa foi alterada. Não reutilizar a DLL da A1/A2. O script de smoke usa um banco em \`reports/generated/a3-ci\`, limpa banco de teste ao começar, e faz duas inicializações distintas do Godot para verificar persistência verdadeira.

## Limitações
- O brush pode ser rejeitado até os blocos próximos estarem editáveis, e não há fila de edição diferida para evitar aplicar uma operação obsoleta após a câmera se mover.
- Não há personagem com gravidade nesta fase. Somente colliders LOD0 nativos; a atualização física precisa de validação separada.
- A3 não possui captura automatizada pixel-a-pixel sincronizada ao clique. A métrica ≤100ms de apresentação só pode ser validada com captura gráfica adequada (e comparável entre casos), nunca pelo retorno de \`do_sphere\` ou \`is_area_meshed\`.
- A2 continua disponível para comparação com instrumentação idêntica, porém habilitar colisões na A3 altera a carga.
