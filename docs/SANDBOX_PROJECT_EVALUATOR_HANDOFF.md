# Sandbox — passagem de contexto para avaliação de todo o projeto

**Data:** 2026-11-27. Documento de orientação ao avaliador, não declaração de aprovação. Estado verificado nos refs abaixo. Revalidar HEAD remoto a cada nova auditoria. Este documento geral complementa, não substitui, o handoff especializado [V3.4 hidráulico](V3_4_HYBRID_EVALUATOR_HANDOFF.md).

## 1. Objetivo, escopo e papel do avaliador

Sandbox procedural volumétrico, explorável, editável e extensível por mods, com terreno/cavernas, objetos naturais, líquidos fisicamente coerentes e simulação escalável de entidades. O projeto evoluiu de uma arquitetura anterior própria para dois MVPs comparativos e, depois, V3 sobre Godot/Voxel Tools. O objetivo não é apenas renderizar terreno, mas construir uma base durável para simulação e conteúdo expansível.

O proprietário solicita avaliações sucessivas de agentes executores e, quando pedido, prompts de continuidade. Avaliar significa auditar código, commits, resultados e limitações; não executar alterações de runtime, promover branches ou alterar critérios sem solicitação. Prefere português objetivo, execução autônoma, testes mínimos decisivos, automação com Actions e runners locais, evitando campanhas intermináveis e trabalho manual dispensável. Nota qualitativa, quando útil, não é percentual de conclusão.

## 2. Mapa de repositórios e linhas de evolução

| Linha | Fonte | Estado de referência |
|---|---|---|
| Projeto original | Referenciado pelo [plano V3](V3_PROJETO.md), ADR-0007 | Conceitos de sandbox/simulação/mod-first reaproveitados; gerenciador de streaming anterior não reutilizado. |
| MVP A | https://github.com/publiomcko-labs/sandbox_v2_mvp_godotVoxel | main c60e9fb33e7ce229d666496e2583d7c9f9ceaaba, funcional com limitações |
| MVP B | https://github.com/publiomcko-labs/sandbox_v2_mvp_rustBevy | main ef78b8ec00ced3eb1033242302492cc6090d9128, funcional com limitações |
| Comparação V1 | branch bench/comparison-v1-20261125 em ambos | Godot 165a1b73ca2fc4e10187830ce44b40d71fd9b93b; Bevy 005a9519348a295e212cd7cd34fe45abdba607ad |
| V3.0–V3.3 | Godot, checkpoints versionados | Fases encerradas com os limites abaixo |
| V3.4 celular | history/v3-4-cellular-20261126; v3/development | 50beeefd3270835dbacd138d420ac6a8f88582ac; abordagem histórica congelada |
| V3.4 Volume Graph H14 | v3/hydraulic | ab3500f6d61bca0e71eb1d90a5de48485fd7892f; baseline histórico |
| V3.4 híbrido atual | exp/v3-hydraulic-hybrid | Avaliação I22f no 7102d5180af65754c55305d6f55c988993bf461c; handoff especializado 5aec50fd5656f6727ae105fd5e8ca50ac5f7032b |

Referências verificadas remotamente na data. Não presumir que o HEAD documental seja o SHA compilado/testado. Não trabalhar diretamente em main ou checkpoint histórico. O original é uma linha histórica de referência conceitual; não se afirma auditoria integral de suas muitas experiências antigas. Este handoff público usa o histórico já documentado nos repositórios públicos, sem republicar material privado.

## 3. MVP A — Godot + Voxel Tools + C++

Fonte executável A5/CPU16: 0c3fee959576d0a1faec9ceecffb4b132a65558b. Checkpoints checkpoint/a5-functional-20261119 e checkpoint/mvp-a-functional-final-20261125 (este último igual ao main documental acima). Godot 4.7.2, Voxel Tools 1.7, C++20, GL Compatibility, blocos de mesh 16, quatro LODs, view solicitada 192 m. A0 bootstrap, A1 SDF/cavernas/LOD, A2 streaming/benchmark, A3 edição SDF SQLite, A4 rochas instanciadas/promovidas a físicas, A5 água plana, corrente prescrita, empuxo/arrasto/nado. A6 variantes CPU/GPU não promovidas; A7/A8 instrumentação e diagnósticos preservados fora do runtime A5.

Encerramento funcional autorizado 25/11/2026: MVP_FUNCTIONAL_COMPLETE_WITH_LIMITATIONS. [Relatório final A](https://github.com/publiomcko-labs/sandbox_v2_mvp_godotVoxel/blob/c60e9fb33e7ce229d666496e2583d7c9f9ceaaba/docs/MVP_A_ENCERRAMENTO_FINAL.md), [CI A5](https://github.com/publiomcko-labs/sandbox_v2_mvp_godotVoxel/actions/runs/44572157321). A7.2 300/300 chamadas aceitas, 287/300 amostras centrais SDF alteradas. A8-P7 ~59,99 FPS nominal, p99 16,750 ms, máximo 17,618 ms, 392 intervalos >16,7 ms. VIEW-130 P4 216/216 raios estáticos, P5 799/799 raios seguros <125 m, P6 margem <120 m. EDIT-100 P8.3 12/12 chamadas aceitas, 3656 comparações CSG sem divergência, 7/12 classificações originais compatíveis, proxy de desenho 30,912–48,525 ms. Estimativas conversacionais posteriores não comprovam first pixel/HID-to-photon. Todos PERF-60, STREAM-18, VIEW-130, EDIT-100 estritos NOT_QUALIFIED. Não reabrir A6–A8 só para satisfazer métricas extremas já dispensadas no encerramento funcional. Não afirmar água volumétrica ou 1M edições na A5. Publicação fonte, não export Release qualificado.

## 4. MVP B — Rust + Bevy + GPU

Fonte executável B17 14e8806acfa4f4413278266789db7b2b7dd1519f; main/checkpoint/b17-final-mvp-20261125 ef78b8ec00ced3eb1033242302492cc6090d9128; branch release/b17-mvp-20261125 1893e2f9f61d572fb49d7c62cb714db30f91ab38. B0 bootstrap, B1 SDF, B2 Surface Nets GPU-resident, B3 LOD/streaming retido, B4 edições, B5 rochas/água/física, B6–B13 estabilização funcional/visual, B14–B15 diagnóstico e slabs fixos 32 MiB, B16 shell distante assíncrono, B17 integração. Configuração aprovada exige scripts/b17-play.ps1, SANDBOX_STAGE=B11 e flags de otimização/culling/edição; binário sem flags não é a referência aprovada. Colisão aproximada Marching Tetrahedra 1 m, não topologia Surface Nets idêntica; água plana, sem prova integral de nado/fluxo local.

[Relatório final B17](https://github.com/publiomcko-labs/sandbox_v2_mvp_rustBevy/blob/ef78b8ec00ced3eb1033242302492cc6090d9128/docs/B17_FINAL_MVP_20261125.md), [E2E](https://github.com/publiomcko-labs/sandbox_v2_mvp_rustBevy/actions/runs/45688167846). Decisão B17_MVP_FUNCTIONAL_APPROVED_WITH_PERFORMANCE_AND_SCOPE_LIMITATIONS; aprovação visual do proprietário 25/11. Controle B15.5→B17: ViewVisibility 823,6→205,5 (proxy, não draw calls); reconstrução distante main p95 1963→13 µs, trabalho transferido ao worker; máximo intervalo B14 224→58 ms, p95 19 ms ambos, uma comparação headless; GPU-ready máximo 39,310 ms não first pixel. Afterburner interativo ~59,8–59,9 FPS; rodada longa 1% low 36,4 / 0,1% low 28,6 FPS. PresentMon não produziu CSV em duas tentativas, eventos ETW perdidos não são frames perdidos. Gates estritos não homologados, capacidade RAM/VRAM e milhões de edições não medidas. Não confundir aprovação funcional com paridade total ou aprovação de produção.

## 5. Comparação e escolha de arquitetura

[Contrato de comparação V1](https://github.com/publiomcko-labs/sandbox_v2_mvp_godotVoxel/blob/165a1b73ca2fc4e10187830ce44b40d71fd9b93b/docs/COMPARISON_V1.md). Mesmo survey46: 1080p, 12 s warm-up, +X até 30 s, -Z até 46 s, 18 m/s, seis edições t=25/28/31/34/37/40 s, três rodadas cold por engine. Geometrias e cargas não equivalentes; contrato de raio 1,5 m, validar implementação efetiva antes de alegar paridade exata. Métricas de intervalos entre inícios de frames, não GPU time, apresentação física ou primeiro pixel. Dados brutos externos não versionados no plano; usar resultados documentados em V3_PROJETO.md e não alegar nova medição independente.

| Mediana das rodadas | Godot | Bevy |
|---|---:|---:|
| FPS | 59,91 | 59,96 |
| p95 frame ms | 17,54 | 25,61 |
| p99 frame ms | 17,97 | 29,84 |
| 1% low FPS | 47,08 | 32,49 |
| Intervalos >20 ms | 2 | 211 |

Godot apresentou pico histórico isolado de 143,75 ms antes do primeiro brush. A escolha de Godot/Voxel Tools para V3 preserva ferramenta madura de terreno, pipeline de conteúdo e melhor estabilidade rotineira observada; não prova superioridade de C++ sobre Rust ou GPU sobre CPU. Bevy é referência comparativa, não branch a fundir. Nenhum dos protótipos obteve todos os gates estritos.

## 6. Arquitetura V3 e invariantes permanentes

Fonte canônica [V3_PROJETO.md](V3_PROJETO.md), [benchmarks de escala](V3_BENCHMARKS_ESCALA.md), [contrato JSON](V3_BENCHMARK_CONTRACT.json). Estado PLANNED no documento original é histórico; consultar resultados por etapa para saber o que já existe.

- World Core C++20 independente da SceneTree: IDs estáveis, comandos, revisões, eventos, scheduler fixo, tiers ativo/agregado/dormente, persistência. Voxel Tools autoridade exclusiva SDF/material, Transvoxel, LOD, streaming e blocos modificados. Nenhum segundo streamer/mesher de terreno. GDScript composição/UI, nativo trabalho intensivo.
- Mod Loader → Content Registry → World Core → adaptadores → Godot/Voxel Tools. First-party e externos pela mesma pipeline, data_only, IDs namespace:id, dependências determinísticas, SHA-256/pins, seeds independentes da visita. Handlers engine-owned, sem scripts arbitrários nesta fase.
- Workers snapshots imutáveis, buffers próprios, revisão e versão de entrada, rejeição stale, publicação limitada/coalescida, backpressure, segurança de colisores. Regiões lógicas não substituem residência do terreno.
- Persistência incremental espacial, sem trabalho global por frame. Isolar saves por versão/perfil/seed/mod pin; não abrir saves A5 em V3 in-place. SQLite Voxel Tools + domínio com checkpoint/journal; crash gate não equivale recuperação transacional completa entre stores. Testar antes de reivindicar.
- Escopo V3 exclui CFD global, clima/ecossistema completo, erosão, termodinâmica, multiplayer, scripts arbitrários. Preservar GL Compatibility salvo mudança explicitamente fundamentada.

## 7. Roadmap completo e status

| Etapa | Estado em 27/11/2026 | Entrega / gate |
|---|---|---|
| V3.0 diagnóstico | COMPLETE_NOT_REPRODUCED_WITH_LIMITATIONS | Checkpoint 78d540e6da554082bb83e2949d11c5116e8a40c8. Duas rodadas cold: p95 17,472/17,497 ms, máximos 22,957/20,665 ms; pico histórico não reproduzido, causa UNATTRIBUTED, PresentMon NOT_MEASURED. Sem otimização especulativa. |
| V3.1 World Core/mod-first | COMPLETE, gate funcional headless | Checkpoint 5a4f9b7c8af649c8f0073d1b58ee4457d3f10136. 11 handlers, 2 mods externos, pins, eventos ordenados, SQLite write/reopen, tiers 27/98/218, tick 10Hz. A5 regressão OK. Sem prova gráfica, recuperação automática de crash ou consumidores completos. |
| V3.2 geologia | COMPLETE_WITH_LIMITATIONS | Checkpoint d02cae1dd6a0a07e278fb599927e6fe37213fd60. Seis materiais declarativos, estratos, construção material-aware, Single S4, reabertura. Temperate fixture; coastal schema/paleta, não geração separada. Avanço autorizado, sem PASS visual formal. |
| V3.3 cavernas | COMPLETE_WITH_LIMITATIONS | Checkpoint 1872e5dcd8d064ffc0881d5d191e662b695f5b4d. Karst natural/wide, ruídos 3D, entradas/câmaras/isoladas, V3.3b corrige superfície fragmentada, V3.3c entradas orgânicas. Custo ~2,75x V3.2 no teste amostral; usuário autorizou avanço, sem PASS gráfico/FPS formal. |
| V3.4 líquidos | EXPERIMENTAL_INTEGRATED_PARTIAL | I22f, ver seção 8 e handoff especializado. |
| V3.5 objetos naturais | PLANNED | Árvore procedural determinística, rochas irregulares, variantes/LODs, MultiMesh/VoxelInstancer, IDs e promoção física coerentes, tombstones regionais, cap inicial 24 corpos. Gate: determinismo, unload/reopen, interação sem duplicação. |
| V3.6 exploração | PLANNED | CharacterBody3D, caminhada/corrida/salto/gravidade, colisão terreno/objetos, nado real; voo criativo 18 m/s separado. Revisões de collider, impedir passagem em colisores indisponíveis, rejeitar construção sobre cápsula. Gate: rota terrestre/caverna, água e edição. |
| V3.7 escala de edições | PLANNED | 10k/100k/1M cumulativos de comandos reais efetivos, perfis local/disperso/revisita. Contar no-op/rejeição separado, persistir e reabrir, medir RAM/I/O/backlog/custo por região e survey46. 1M opt-in, não rotina CI. Sem extrapolar sucesso. |
| V3.8 simulação | PLANNED | Grazer declarativo determinístico, energia/recurso/repouso/steering, SoA C++, índice espacial, render em lote. 1k/5k/10k ativos e 10k/100k lógicos com 1k ativos alvo; 10Hz, 12s warm-up, 60s/600 ticks. Gate mínimo 1k ativos com ticks completos, determinar capacidade medida, p95 subsystem alvo 10ms conforme contrato. Sem equiparar lógico/renderizado/ativo. |
| V3.9 integração | PLANNED | Todos módulos ligados, export Windows Release instalado e testado fora editor, benchmark A5/V3 cold/warm com limitações, smoke/reopen, critérios separados, documentação e entrega. |

Fontes de fechamento: [V3.0](V3_0_ENCERRAMENTO.md), [V3.1](V3_1_IMPLEMENTACAO.md), [V3.2](V3_2_IMPLEMENTACAO.md), [V3.3](V3_3_IMPLEMENTACAO.md). Referências de CI: V3.1 native 45840418732/core 45840266763; V3.2 native 45842375434; V3.3c native 45852883354/core 45852884043. Não antecipar V3.5–V3.9 como implementadas por existirem schemas/handlers em V3.1.

## 8. V3.4 — fase ativa, handoff de alto nível

Baseline celular congelado; Volume Graph H14 vindo da V3.3; experimento híbrido originado no commit 3daaec2f8c5881c9afc7b5bb50b618746de54bd8. Arquitetura: agregação estável, VP multicamada local, render independente de ownership/residência, oceanos fixed-head com ledger explícito. Metas propostas 20Hz, passo inicial 1m, solver p95 <=5ms, publicação main isolada <=1ms, alcance >=130m. R1 renderer; R2 núcleo VP; R3 integração/ciclo; R4 cosméticos após geometria; R5 comparação integrada e visual. Não retornar ao modelo celular global nem máscara global.

Consultar primeiro [handoff do avaliador hidráulico](V3_4_HYBRID_EVALUATOR_HANDOFF.md), [continuação executor](V3_4_HYBRID_CONTINUATION.md), [resultados](V3_4_HYBRID_RESULTS.md), [blueprint](V3_4_HYBRID_BLUEPRINT.md), [contrato](V3_4_HYBRID_EXPERIMENT.json). Esses arquivos contêm evidências exatas e evitam releitura redundante.

Último runtime validado 8c0bee64c635228fcd8c823a0364eb4a4301d1f5. Core 46080772250 (5b9a4b4; core inalterado), native 46082956119, GPU 46082956189 PASS de regressão. Cold archive 34 regiões/9.896.672L, 22 restores físicos, 12 visual-only; núcleo 121 regiões ocean sintéticas, runtime aquisição oceânica 1.848.317L. Fonte lava 64.000L; GPU 11.378.442L, 16/34 ticks, 96 hot, 42 wet, 0 settles, 0 aquisições oceânicas no fixture GPU. Frame p95 52,252ms, refresh p95/p99 6,944/9,625ms, solver p95 4,937ms. Sem qualificação de gameplay/60FPS. Falha de bootstrap distante 46082537465 permanece aberta, teste final parte de pond inicializado. Bulk ocean somente revisão zero; >96 wet visíveis, drenagem real, cross-tile construction, settle residente, margens, performance e launcher final pendentes. Launcher ainda I21. Nenhum bloqueio humano identificado. Não declarar I22 ou V3.4 concluídos.

Retomada I22: corrigir bacia remota e cobertura oceânica certificada, hot/cold com integridade e custo; I23 lifecycle e edições; I24 desempenho; I25 geometria e acabamento; I26 validação e checkpoint. Depois V3.5 conforme plano, somente quando aceitação ou limitação expressamente autorizada pelo proprietário. Não mudar prioridades por iniciativa especulativa.

## 9. Protocolo para avaliações e execução futura

1. Consultar ref remoto e comparar com último SHA auditado. Identificar código compilado/testado vs docs-only. Revisar diff, documentos e testes pertinentes; não presumir que o estado histórico permaneça.
2. Confirmar Actions/jobs concluídos e conclusões reais, SHA, artefato, logs, hardware/backend e sessão interativa. Distinguir PASS unitário/core, headless, GPU real, análise de screenshots e avaliação humana. Não afirmar inspeção direta se só leu relato do executor. Sem acesso direto presumido ao desktop.
3. Conferir invariantes e gates: SDF/material autoridade, persistência/revisões, IDs/determinismo, massa, ownership, isolamento de saves, filas/memória limitadas, cobertura e coerência física/visual. Examinar critérios afrouxados, fixtures substituídos e casos removidos. Verificar falhas antigas relevantes sem repetir testes aprovados.
4. Usar evidência comparável: warm-up excluído, p95/p99/p99.9, picos, 1%/0,1% low, contagem >20/33ms, workload e perfil cold/warm. Intervalo de frame, GPU-ready, colisores, ETW, apresentação e primeiro pixel são diferentes. Não inferir FPS de headless, contagens lógicas de pixels ou escalabilidade por extrapolação. Gates comuns PERF-60/STREAM-18/VIEW-130/EDIT-100 continuam estritos até evidência suficiente ou decisão explícita de fechamento com ressalvas.
5. Relatar avanços e regressões, estado por requisito, risco prioritário, evidência e limitação. Não confundir nota do agente com percentual de escopo concluído. Se pedido, produzir prompt de retomada a partir do HEAD confirmado.
6. Executor deve usar loop: implementar → commit/push no branch isolado → acompanhar Actions até fim → inspecionar logs/artefatos/screenshots → corrigir e revalidar somente o necessário → checkpoint → próxima tarefa. Usar runners Windows interativos GPU para jogo e benchmarks, core/native para contratos; sem transferir tarefas automatizáveis. Se frente bloqueada, avançar em independentes. Só parar por conclusão integral ou bloqueio humano comprovado que impede todo avanço; limite técnico real de contexto exige handoff, não declaração de conclusão. Não alterar gates para obter PASS. Evitar longas consultas redundantes e campanhas diagnósticas sem decisão.
7. Ao encerrar etapa, preservar checkpoint, testes, resultados/limitações, launcher/binário exato e documentação; aprovação do proprietário quando houver gate visual. Não promover/merge automaticamente. Manter handoffs geral e especializado conforme pedido e novos resultados.

## 10. Fontes e limites deste documento

As refs públicas, relatórios de encerramento A/B, contrato comparativo, planejamento V3, benchmarks e documentos de V3.0–V3.3 foram reabertos na criação deste handoff. A avaliação hidráulica detalhada deriva da auditoria anterior com logs reais no handoff especializado. Não foram repetidos os testes, baixados os dados brutos externos ou inspecionadas novamente as screenshots. Não é catálogo exaustivo de todos os experimentos históricos; é mapa completo da trajetória e roadmap necessários à avaliação do projeto atual. Preservar fontes originais e consultar o documento da etapa antes de decidir. O handoff geral é exclusivamente documental, sem alteração de runtime ou promoção.
