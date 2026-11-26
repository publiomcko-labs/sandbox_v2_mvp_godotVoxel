# V3.2 — geologia e materiais

Status COMPLETE_WITH_LIMITATIONS — avanço autorizado pelo usuário. Base V3.1 checkpoint/v3-1-20261126, 5a4f9b7c8af649c8f0073d1b58ee4457d3f10136.

API confirmada no commit Voxel Tools 2ac9f5f8a8219bf499314cc0fad54ffc47df908f:
- VoxelFormat.indices_depth DEPTH_8_BIT; VoxelGeneratorGraph.TEXTURE_MODE_SINGLE e NODE_OUTPUT_SINGLE_TEXTURE; VoxelMesherTransvoxel.TEXTURES_SINGLE_S4 (CUSTOM1.xy, quatro índices/pesos de 8 bits). Índice voxel 0..255; MVP utiliza seis papéis por perfil (grama, solo, areia, calcário, granito, basalto).
- Material metadata declarativo: density, hardness, excavation_resistance, permeability, albedo RGB, roughness. Resistência e permeabilidade não atuam na física ainda.
- Paleta ordenada, IDs persistentes namespace:id, validada e fixada por pins do conteúdo + generator_version contendo ID do perfil. V3.1 mantém formato e saves; V3.2 não abre SQLite anterior.
- Construção material-aware no adaptador nativo: copy/paste conjunto SDF+INDICES em AABB limitada, preserva índices de sólidos existentes e na remoção. Não cria segundo streamer. Operação lógica única; persistência continua SQLite, não atomicidade crash-safe.
- Mod oficial earth (mesma pipeline), perfis temperate/coastal. Perfil declarativo externo pode referenciar materiais próprios completos, com seis papéis. Graph/renderer e teste real pendentes neste incremento.

## Runtime e validação

Entrada opt-in res://scenes/v3_geology_main.tscn, default user://worlds_v32; perfil por V3_GEOLOGY_PROFILE (earth:temperate ou earth:coastal). A5 e V3.1 continuam usando o graph sem outputs de materiais. O graph usa SDF original e função geológica separada baseada em altura não escavada, camada superficial, inclinação aproximada por diferença finita de 2m, ruído contínuo e profundidade; gera índices nativos inclusive em volume sólido. Shader Single S4 decodifica CUSTOM1, respeita CUSTOM0/transições, mistura cores e roughness declarativas e detalhe procedural triplanar em coordenadas mundiais. Sem texturas externas, sem mapas de normais. Teclas 1–6 selecionam IDs de material da paleta. Fixture headless verifica formato, amostras em LOD0/1, distribuição, preservação de índices ao escavar, construção basalto e reopen real. Teste gráfico e custo comparativo ainda pendentes; headless não comprova ausência de fissuras nem compilação/renderização real do shader.

CI 45841991651 PASS (GCC/MSVC), 45841991806 build, A5, V3.1 e V3.2 SDF+materiais/reopen PASS; seis slots efetivamente encontrados [5,4,3,1,0,2], paridade LOD0/1 nas amostras. Porém logs continham erro do parser de shader na linha 6 (mat2, nome reservado de tipo). Candidato não aprovado para visual. Corrigidos todos nomes para u_geo_mat0..5 e a CI agora rejeita erros de shader/script nos logs, independentemente do código de saída do Godot. Gate de amostras exige todos os seis slots. Validação gráfica permanece pendente.

## Candidato funcional validado — 26/11/2026

Commit c7fd64b75142fe782b17f07267cc73705b5fa148, CI [45842375434](https://github.com/publiomcko-labs/sandbox_v2_mvp_godotVoxel/actions/runs/45842375434) SUCCESS (1min33s), sem SHADER ERROR/Shader compilation failed/SCRIPT ERROR, regressões A5 e V3.1 PASS, V3_GEOLOGY_GENERATION_PASS seis slots [5,4,3,1,0,2] e paridade de amostras LOD0/1, V3_GEOLOGY_FIXTURE_PASS write/reopen e V3_GEOLOGY_E2E_PASS. O teste utiliza earth:temperate; earth:coastal possui validação de schema/paleta, não fixture de geração separada. SDF e material de construção basalto persistiram. A validação headless usa parser dummy, não pipeline GL real. Único gate pendente: visual em desktop (mistura/cores, corte, construção e transições LOD). Script scripts/v3-geology-local-windows.ps1 instala o artefato exato ID 15130360002 (ZIP SHA256 de746cdd340f50a3ed98fdc292e77e15ef9953be719b2902f3af772804b5cf2c), usa mundo descartável por execução, GL Compatibility e coleta logs/metadata; não atribui PASS visual automaticamente. Sem qualificação gráfica ou de desempenho até coleta real. A5/main preservados.

## Encerramento V3.2

Usuário testou/interagiu com seleção de materiais e autorizou avanço em 26/11/2026. Não forneceu relatório explícito de qualidade visual nem ZIP; não atribuir PASS gráfico formal ou desempenho. Gate funcional headless aprovado no candidato c7fd64b; avanço aceito com limitação visual registrada. Checkpoint checkpoint/v3-2-20261126. Preservar código e mundos V3.2; V3.3 terá versão de gerador e diretório próprios.
