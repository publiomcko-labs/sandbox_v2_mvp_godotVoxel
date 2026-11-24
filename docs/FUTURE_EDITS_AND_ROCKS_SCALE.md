# Ações futuras — escalabilidade de edições e rochas (pós-MVP)

Registrado em 24/11/2026; rastreio em [issue #27](https://github.com/publiomcko-labs/sandbox_v2_mvp_godotVoxel/issues/27). **Este documento não autoriza alterar A5/CPU16 nem qualifica desempenho em larga escala.**

## Arquitetura confirmada

- `native/src/world_bootstrap.cpp`: `edit_sphere(center,add,radius)` exige `is_area_editable` da AABB local em LOD0, aplica `VoxelTool.do_sphere` com `MODE_ADD` ou `MODE_REMOVE`; mede apenas custo síncrono da operação.
- `godot/scripts/a3_edit_controller.gd`: raio interativo 1,5m, frequência limitada a 10Hz, `Ctrl+S` chama `save_modified_blocks()` e aguarda tracker até 30s; **não existe autosave periódico do terreno explícito neste controlador**.
- `godot/scripts/terrain_sdf.gd`: `VoxelStreamSQLite` por seed; `save_generator_output = false` grava alterações em blocos, não toda saída procedural nem log integral dos cliques. Não há evidência de limite global de número de edições no wrapper, mas tampouco stress-test de milhões de blocos.
- `godot/scripts/a4_rock_manager.gd`: `MAX_ACTIVE_BODIES=24` só limita dinâmica não congelada; todos os promovidos continuam em `_bodies`/nós `RigidBody3D`. `_refresh_activity()` a cada 0,25s ordena e visita IDs globais, `save_states()` serializa todo JSON a cada 5s, `_restore_states()` instancia todos os corpos. Possível crescimento O(N) de CPU/memória/escrita para muitos promovidos.
- Estado de rochas em JSON separado do SQLite do terreno; **sem commit atômico de ambos** na implementação atual.

## Plano de ações, somente após qualificação do MVP

1. **Benchmark de edições 10k/100k/1M**: variantes de edições no mesmo conjunto de blocos e dispersas por 10k/100k/1M blocos distintos; separar número de *operações* de blocos modificados. Medir custos de `do_sphere` p50/p95/p99/p99.9, remeshing/colisor/pixel correto, backlog de save, bytes SQLite, picos de I/O, memória, tempos de reabertura fria/quente e retorno em regiões.
2. **Persistência e recuperação**: testar encerramento normal, CTRL+S, save parcial e queda inesperada, identificar janela de perda máxima e integridade de SQLite+JSON; considerar checkpoint incremental e reconciliação de transações apenas se necessidade observada.
3. **Escala de rochas promovidas 1k/10k/100k**: medir nós resident, RAM, custo de ordenação trimestral por segundo, autosave JSON 5s, reload, física real ativa ≤24, remoção de instâncias estáticas e IDs.
4. **Arquitetura corretiva somente com evidência**: rochas distantes viram registros leves indexados espacialmente, instanciadas como físicos só perto; persistência segmentada e incremental por região, validação de IDs e removals. SQLite: avaliar índices/chaves/cache/compactação/migração apenas caso benchmark demonstre gargalo.
5. **A/B justo**: mesmas seeds, distribuição espacial, jornada do jogador, hardware, instrumentação, conteúdo de mundo e taxas de edição; rejeitar ganhos falsos que sacrificam 130m/18m/s ou consistência do save.

## Bloqueios

A7.2 passou **300/300 edições funcionais**, não 1M nem **EDIT-100**. Nenhuma ação acima é executada nesta A8-P6; o escopo imediato continua auditoria offline de continuidade dinâmica. Todos os gates estritos permanecem `NOT_QUALIFIED`. Não criar merge automático ou alteração de runtime em nome deste backlog.
