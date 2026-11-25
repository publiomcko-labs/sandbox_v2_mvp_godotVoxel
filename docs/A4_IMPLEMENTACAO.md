# A4 — rochas em lotes, interação física e persistência

**Checkpoint de entrada:** \`checkpoint/a3-functional-20261119\` → commit \`0b74e2ac01c65f48027e590bd22e2d86060287cc\`. A3 aprovada em testes nativos/SQLite e revisão funcional manual, mas EDIT-100 estrito, colisão do personagem e streaming sob carga continuam pendentes de medição.

## Arquitetura
- \`Terrain/RockInstancer\` é um \`VoxelInstancer\` nativo, filho do terreno. \`VoxelInstanceLibraryMultiMeshItem\`, ID fixo 100 e \`VoxelInstanceGenerator\` configuram densidade de ~0,016 rocha/m², altura e inclinação. Um \`SphereMesh\` low-poly evita assets externos. Geração, publicação e LOD continuam *exclusivamente* no Voxel Tools.
- \`item.persistent=true\`: quando uma rocha é removida pelo instancer, sua retirada estática é associada ao \`VoxelStreamSQLite\`. A ferramenta nativa \`remove_instances_in_sphere\` dispara a ação \`REMOVAL_BEHAVIOR_INSTANTIATE\` para converter apenas as rochas atingidas por meio de um wrapper \`Node3D\` que preserva o transform original e cria um \`RigidBody3D\` com colisão de esfera simplificada, massa, atrito e gravidade.
- \`RockManager\` controla somente os corpos **já promovidos**, com ≤24 corpos ativos em física no raio de 24 m, congelamento além de 32 m. Não há malha individual por rocha distante nem outro gerenciador de regiões.
- Os corpos promovidos têm ID por posição original quantizada em centímetros, proteção contra duplicatas e sidecar JSON por seed para posição, rotação, velocidades e estado de repouso. O sidecar é gravado temporariamente e renomeado; o VoxelStreamSQLite nativo continua responsável pelas alterações do terreno e pela marcação de instâncias estáticas removidas.
- Input: pressione \`F\` mirando o chão junto de uma rocha (até 24 m); edição SDF da A3 e \`Ctrl+S\` preservados. Automático: sidecar de corpos a cada 5 s, salvamento SQLite sob Ctrl+S. Evitar desligamento forçado durante gravações.

## Critérios
- A4-INSTANCER: código e cena nativos instanciados, contagem/estatística real, pelo menos 400 objetos **na área de 130 m**, após carregamento. Contador do motor, isoladamente, não qualifica essa área; verificação gráfica/espacial ainda é necessária.
- A4-PHYSICS: corpo físico cai, colide e repousa sobre terreno/fixture sem atravessar.
- A4-PROMOTE: disparo nativo remove a estática, corpo aparece na mesma posição e o total dinâmico é limitado. Sem duplicação ao reentrar/reabrir.
- A4-SAVE: sidecar persiste transform/velocidades e o VoxelStreamSQLite persiste a remoção da instância estática. Reabertura deve verificar os dois lados.
- STREAM-18/VIEW-130/PERF-60: executar cargas gráficas A2 sob rochas; sem gaps, atraso de rochas nem stutter. CI headless NÃO é gate gráfico.

## Local
\`\`\`powershell
cd C:\Dev\sandbox_v2_mvp_godotVoxel
git fetch origin
git switch --track origin/feat/a4-voxel-rock-instancing-physics-20261119
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\a4-smoke-windows.ps1
& .\.tools\godot.exe --path .\godot
\`\`\`
A mesma DLL C++ da A3 é reutilizada. O CI verifica hashes Git dos arquivos nativos antes de restaurar o artefato aprovado da A3; se o C++ mudar, falha em vez de reutilizar uma DLL incorreta.

## Limitações
1. O motor escolhe os pontos estocasticamente por bloco/malha, de modo que o contador global \`debug_get_instance_counts\` pode incluir rochas fora do círculo de 130 m. A contagem qualificada da área e ausência de rochas flutuantes exigem inspeção espacial adicional.
2. O instancer fornece callback de remoção por esfera, não ID público de cada item antes da promoção. O ID é baseado no transform inicial quantizado; eventos em posições extremamente próximas precisam de revisão de colisão/duplicata.
3. A conexão entre salvamento nativo de remoções e o sidecar JSON não forma uma transação única; queda/crash no meio dos dois saves exige reconciliação em uma fase futura. Não reivindicar atomicidade entre arquivos.
4. Dinâmicas congeladas permanecem nos dados e podem ser reativadas, mas não voltam automaticamente à instância estática nativa. Isso evita reaparecimento duplicado, porém deve ser verificado sob trajetórias longas.


## Corretiva A4-ID
O primeiro CI da A4 retornou status success, mas a auditoria explícita detectou dezenas de registros \`A4_DUPLICATE_PREVENTED id=x0_y0_z0\`: o motor inicializou a raiz \`RigidBody3D\` da removal_scene em posição zero, perdendo a transformação recebida. Corrigido com \`rock_spawn.tscn\` de raiz \`Node3D\`; a identidade é capturada antes da criação do corpo físico. O smoke passou a exigir contagem consistente de estáticas removidas e de corpos promovidos, IDs únicos e posições dentro do raio original. Nunca aceitar somente exit-code/CI verde sem auditar o log de erros.


## Corretiva A4-CALLBACK
A cena \`rock_spawn.tscn\` com raiz \`Node3D\` também recebeu posição zero em múltiplas remoções. A rota foi substituída por \`VoxelInstanceLibraryMultiMeshItem.REMOVAL_BEHAVIOR_CALLBACK\`, cuja assinatura entrega o \`Transform3D\` original por valor antes de qualquer cena existir. O callback agenda a construção do corpo no \`RockManager\` após a operação nativa. Logs registram os primeiros transforms recebidos. Se estes também forem zero, a falha está dentro do caminho do VoxelInstancer e o gate deve falhar, sem disfarçar removidos como corpos criados.


## A4-HEADLESS-QUALIFICATION — limitação confirmada
No Windows Actions com \`--headless\`, o \`VoxelInstancer\` reporta instâncias ativas, mas os callbacks de remoção (tanto \`REMOVAL_BEHAVIOR_INSTANTIATE\` quanto \`REMOVAL_BEHAVIOR_CALLBACK\`) recebem \`Transform3D\` com origem (0,0,0) para diversas rochas do mesmo bloco. Isso não pode ser usado como posição válida e gerava duplicatas falsas.

No headless, a promoção a corpo físico é **suprimida** quando o motor não disponibiliza transforms da camada de renderização; o teste registra \`headless_native_transform_gate=NOT_QUALIFIED\`. O smoke agora separa: (1) remoção estática nativa e persistência SQLite; (2) corpos físicos criados a partir de **transforms de teste explícitos**, checando ID/cap/física/sidecar e reabertura em novo processo; (3) a ligação exata do transform nativo GPU/Multimesh → corpo físico deve ser testada em sessão gráfica real antes de aprovar A4. Não alegar que (1)+(2) comprovam (3). Cabe ao resultado gráfico decidir entre limitação do renderer headless e bug comum.
