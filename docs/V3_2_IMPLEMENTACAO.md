# V3.2 — geologia e materiais

Status IN_PROGRESS. Base V3.1 checkpoint/v3-1-20261126, 5a4f9b7c8af649c8f0073d1b58ee4457d3f10136.

API confirmada no commit Voxel Tools 2ac9f5f8a8219bf499314cc0fad54ffc47df908f:
- VoxelFormat.indices_depth DEPTH_8_BIT; VoxelGeneratorGraph.TEXTURE_MODE_SINGLE e NODE_OUTPUT_SINGLE_TEXTURE; VoxelMesherTransvoxel.TEXTURES_SINGLE_S4 (CUSTOM1.xy, quatro índices/pesos de 8 bits). Índice voxel 0..255; MVP utiliza seis papéis por perfil (grama, solo, areia, calcário, granito, basalto).
- Material metadata declarativo: density, hardness, excavation_resistance, permeability, albedo RGB, roughness. Resistência e permeabilidade não atuam na física ainda.
- Paleta ordenada, IDs persistentes namespace:id, validada e fixada por pins do conteúdo + generator_version contendo ID do perfil. V3.1 mantém formato e saves; V3.2 não abre SQLite anterior.
- Construção material-aware no adaptador nativo: copy/paste conjunto SDF+INDICES em AABB limitada, preserva índices de sólidos existentes e na remoção. Não cria segundo streamer. Operação lógica única; persistência continua SQLite, não atomicidade crash-safe.
- Mod oficial earth (mesma pipeline), perfis temperate/coastal. Perfil declarativo externo pode referenciar materiais próprios completos, com seis papéis. Graph/renderer e teste real pendentes neste incremento.

## Runtime e validação

Entrada opt-in res://scenes/v3_geology_main.tscn, default user://worlds_v32; perfil por V3_GEOLOGY_PROFILE (earth:temperate ou earth:coastal). A5 e V3.1 continuam usando o graph sem outputs de materiais. O graph usa SDF original e função geológica separada baseada em altura não escavada, camada superficial, inclinação aproximada por diferença finita de 2m, ruído contínuo e profundidade; gera índices nativos inclusive em volume sólido. Shader Single S4 decodifica CUSTOM1, respeita CUSTOM0/transições, mistura cores e roughness declarativas e detalhe procedural triplanar em coordenadas mundiais. Sem texturas externas, sem mapas de normais. Teclas 1–6 selecionam IDs de material da paleta. Fixture headless verifica formato, amostras em LOD0/1, distribuição, preservação de índices ao escavar, construção basalto e reopen real. Teste gráfico e custo comparativo ainda pendentes; headless não comprova ausência de fissuras nem compilação/renderização real do shader.
