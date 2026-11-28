# Passagem de contexto — avaliador independente do Sandbox V3.4

Data da auditoria: 2026-11-27 (America/Sao_Paulo).
Este documento é para um **novo agente avaliador**, não para o executor. É uma fotografia da avaliação no commit `7102d5180af65754c55305d6f55c988993bf461c`, não uma declaração de conclusão. Sempre consultar HEAD remoto antes de avaliar outra execução. Não presumir que este checkpoint ainda seja o mais recente.

## 1. Papel, escopo e preferências do usuário

- Repositório: https://github.com/publiomcko-labs/sandbox_v2_mvp_godotVoxel
- Branch exclusivo do experimento: `exp/v3-hydraulic-hybrid`.
- O usuário solicita avaliações sucessivas do trabalho de agentes implementadores, seguidas, quando solicitadas, de prompts de continuidade. Avaliar é atividade de leitura e auditoria; não alterar código, workflows, launcher, branches, checkpoints ou critérios de aceitação sem pedido expresso. Este arquivo documental foi autorizado pelo pedido de passagem de contexto.
- Priorizar resultados objetivos, critérios de aceitação e próxima implementação essencial. Evitar campanhas redundantes de testes e solicitações de trabalho manual que os runners conseguem executar.
- Distinguir progresso, aprovação de regressão, aprovação funcional, limitação, falha e conclusão integral. Não confundir Action verde com qualidade visual, teste sintético com prova de runtime, headless com GPU, nem checkpoint com encerramento.
- Preferir respostas diretas em português. Ao produzir prompt para executor, ser conciso e inequívoco. Pontuação qualitativa, se usada, não representa percentual de conclusão.

## 2. Origem e decisões arquiteturais

H14, branch `v3/hydraulic` (base `ab3500f6d61bca0e71eb1d90a5de48485fd7892f`), apresentava cortes, degraus, falhas de cobertura e redistribuição instantânea dentro de compartimentos. O modelo celular volumétrico anterior é histórico, não arquitetura a restaurar. Blueprint inicial do experimento: `3daaec2f8c5881c9afc7b5bb50b618746de54bd8`.
Arquitetura escolhida: reservatórios/compartimentos agregados para equilíbrio, Virtual Pipes multicamada C++ nas regiões ativas, renderização independente de ownership e residência física, Voxel Tools como autoridade exclusiva do terreno; mod-first e GL Compatibility. Sem máscara global, sem solver volumétrico global, sem nova autoridade de terreno. Cada litro possui um único proprietário; fontes/drenos explicitamente contabilizados; terreno e líquidos respeitam revisão e persistência. Não mesclar nem promover automaticamente o branch.

Documentos de referência obrigatórios:
- `docs/V3_4_HYBRID_BLUEPRINT.md` — contrato e gates R1–R5.
- `docs/V3_4_HYBRID_EXPERIMENT.json` — estados estruturados e evidências; alguns campos históricos permanecem antigos, usar a entrada específica do checkpoint e os logs.
- `docs/V3_4_HYBRID_RESULTS.md` — resultados por intervenção, limitações e artefatos.
- `docs/V3_4_HYBRID_CONTINUATION.md` — handoff atualizado pelo executor.
- `docs/V3_4_HYDRAULIC.md` — baseline H14.
- `scripts/v3-hydraulic-hybrid-local-windows.ps1` — launcher pinado, verificar versão e artefato reais.

## 3. Histórico resumido e evidências a preservar

| Checkpoint documental | Entrega / limites |
|---|---|
| R1–R3 core, 64ab2c9 | B2 mantém geometria H14 com 315→43 meshes no retorno; VP microbenchmark conserva 56.000 L, R3 ownership conserva 48.000 L, protótipo ainda não integrado naquele ponto. |
| I6, 5adc966 | Godot integrado: zero litros nas colunas recém-abertas antes dos ticks, chegada >=20 L em 16/34 ticks GPU, 11.314.442 L exatos e reopen. Geometria parcial; 0 settles residentes. |
| I9a, 2ad6495 | Survey fora LOD0 apenas mundo pristine/bootstrap; GPU 27 tiles, refresh p95 6,805 ms. |
| I11b, 385542d | I10a buffer reuse, I10b cache por mutações, I11b fecha fissura focal de 7 cm com face vertical. Refresh p95 5,687 ms; p99 10,122 ms. Margens escalonadas persistem. |
| I15, 74ddf19 | I12b corrige serrilhamento, I13 ativa receptor antes do fluxo agregado, I14 cache de fronteira no worker, I15 procedência de edições persistida; 3 surveys pós-edição GPU. Refresh p95/p99 6,589/10,557 ms. |
| I21, a86475f | I16 recuperação exata de proprietário suspenso (71.472 bytes); I17b lava 64.000 L, fonte fixa; I18 barreira dentro de tile; I19 SDF stream autoritativo, I20 leitura incremental um bloco/frame, I21 fontes visíveis a 192 m independentes LOD0. Ainda não oceano extenso. |
| I22f, 7102d51 | Cold owners persistidos, visualização cold sem ownership físico, conectividade oceânica e aquisição. Regressões corrigidas, mas falha de bootstrap remoto explicitamente aberta. I22 parcial; I23–I26 pendentes. |

As metas propostas no blueprint são 20 Hz solver, passo inicial 1 m, solver p95 <=5 ms, publicação isolada main-thread p95 <=1 ms, cobertura visual >=130 m. A configuração de terreno do fixture I21/I22 é 192 m; descoberta de âncoras a 192 m não prova cobertura integral. Não inferir PERF-60 de fixture instrumentado/capado. O usuário prefere reduzir testes ao mínimo decisivo.

## 4. Auditoria I22f (última avaliação desta conversa)

HEAD avaliado: `7102d5180af65754c55305d6f55c988993bf461c` (documentação); runtime/fixture efetivamente testado `8c0bee64c635228fcd8c823a0364eb4a4301d1f5`.
Core run [46080772250](https://github.com/publiomcko-labs/sandbox_v2_mvp_godotVoxel/actions/runs/46080772250) passou GCC/MSVC no commit `5b9a4b4c4dd6379ae9e38439168e16393f6ae33b`; arquivos core/testes C++ inalterados até o candidato final, runtime integrado modificado e validado pelos runs abaixo.
Native [46082956119](https://github.com/publiomcko-labs/sandbox_v2_mvp_godotVoxel/actions/runs/46082956119) e GPU [46082956189](https://github.com/publiomcko-labs/sandbox_v2_mvp_godotVoxel/actions/runs/46082956189) passaram no SHA 8c0bee64; job interativo efetivamente executado. Nenhum run pendente entre os consultados no momento da auditoria. Artefatos: native 15238041249, ZIP SHA256 ab8ca1e2aa12591146d81e6dca2ad716031c43b11c3d824895acd66283008fa0, DLL 3b37b84a2dadf466a335dfdd1f58085f7f9c3a0f2b681120e75b25833fe6bfeb; GPU 15237966549, ZIP SHA256 4906e1d39a79b598a0acc49824221ada4e2760b86f8cf1bd67da2445343b54da. Hashes e inspeção das sete imagens registrados pelo executor; nesta auditoria independente foram lidos código, docs, jobs e logs efetivos, não baixadas/inspecionadas novamente as imagens ou executado o launcher.

**Provas:**
- Core: 120 proprietários frios, 1.920.000 L conservados; 120 registros disco, reopen, ledger incompatível rejeitado; oceano sintético 121 regiões, 3.872.000 L injetados, caverna coberta e proof obsoleto excluídos. Não equivale a gameplay ou cobertura de 121 regiões simultaneamente visíveis.
- Native: streaming arquiva 34 regiões/9.896.672 L, depois 22 restores físicos e 12 cold visual-only restantes. Ciclo write/reopen preserva 5.159 L em coluna e 11.378.442 L globais; 71.472 bytes liberados em suspensão exata, 10 cold regiões/1.893.734 L no fechamento. Contador settles=1 neste fixture de suspensão com ticks=0 **não comprova** equilíbrio molhado residente por 20 ticks; GPU breach settles=0.
- Native: integrated write/reopen 13.226.759 L = 11.378.442 L iniciais (pond 11.314.442 + lava 64.000) + 1.848.317 L de aquisição oceânica. Fixture isolado de fontes tardias: 2 âncoras não residentes, 3 IDs, 12 aquisições oceânicas, +9 L físicos write e +9 L reopen, drained=0. Barreiras intra-tile e stream SDF mantidos; digest aed03023105e9816 e capacidade 8.874.232 L.
- GPU: 11.378.442 L, injected=0, 16/34 ticks, 120 ticks, 42 wet tiles, 44 meshes, 96 hot tiles, 5 locais, 2.418 intervalos, 0 settles. Não há neste GPU prova de expansão oceânica, >96 regiões molhadas visíveis, drenagem real nem shader de lava.
- Regressão de bootstrap remoto: native [46082537465](https://github.com/publiomcko-labs/sandbox_v2_mvp_godotVoxel/actions/runs/46082537465) falhou, código `37097d1c65ae6db14230f2bac607df4c39994c48`. Duas fontes remotas foram descobertas, mas pond finito excedeu orçamento de busca de 35 tiles. Inicial 64.000 L lava, oceano 1.848.317 L; pond não inicializado. Teste posterior primeiro inicializa o pond perto da origem, depois muda spawn para (16,12,112) antes das fontes tardias. É regressão isolada válida, não correção da falha remota. Reabrir o caso original como requisito independente; não relaxar o gate.
- Revisão de código: armazenamento `native/src/persistence/hydraulic_region_store.hpp` usa JSON por região, ledger resumido e session intent crash gate; leitura/escrita síncrona, validação de registro sob demanda, não auditoria integral de todos os arquivos na abertura. Não reivindicar recovery de crash transacional completo ou latência comprovada. `native/src/hydraulic_integrated_runtime.hpp` tem conjuntos de interesse físico/survey separados, fronteira ocean limitada, visual cold sob demanda. Bulk acquisition ocean restrita à revisão global zero, após edições somente fluxo. Esses limites não são solução final.
- Launcher atual ainda pinado em I21 `75b342b3019fc128c4c553613334f31a20cf1513`, run 46074463346. Guardas de igualdade rejeitam HEAD com runtime novo. Não fornecer instrução de execução do HEAD como se launcher estivesse atualizado; não promover candidato parcial.

### Comparação GPU (ms, cenário instrumentado)

| Métrica | I21 | I22b | I22c | I22f |
|---|---:|---:|---:|---:|
| Solver p95 | 4,782 | 4,972 | 4,866 | 4,937 |
| Refresh combinado p95 | 6,259 | 6,525 | 6,692 | 6,944 |
| Refresh combinado p99 | 9,088 | 8,827 | 8,496 | 9,625 |
| Frame p95 fixture | 48,390 | 48,429 | 48,249 | 52,252 |
| Snapshot máximo | 39,293 | 29,334 | 29,898 | 40,814 |

I22f vs I21: refresh p95 +10,9%, p99 +5,9%, frame p95 +8,0%, solver p95 +3,2%. Sem aprovação global de desempenho. Refresh combinado não é publicação main-thread isolada; frame fixture não é benchmark de gameplay. A leitura incremental I20 reduziu o pico de trabalho por etapa, não necessariamente a latência total. Cold I/O precisa perfil próprio.

## 5. Matriz de aceitação e ordem de retomada

**I22, continuar antes de encerrar:** corrigir inicialização distante de bacia finita por busca incremental certificada, persistência/limite de fronteira e propriedade única; não trocar silenciosamente o lago por fonte volumétrica nem assumir terreno desconhecido. Validar oceano extenso real, >96 wet tiles visíveis com hot <=96 (ou limite justificado), drenagem, spawn remoto, movimento/revisit/reopen, expansão segura após edição sem inundação de cavernas isoladas. Demonstrar custo e integridade de cold I/O, recuperação sob falhas conforme contrato. Lava visual em GPU.
**I23:** settle molhado residente por 20 ticks estáveis, propriedade/reagregação conservativa sem enfraquecer critérios, suspensão de fronts não equivalentes via cold store. Construção cross-tile e abertura de multicavidades, rejeição atômica deixa terreno e massa intactos. Não repetir I16/I18 já provados.
**I24:** instrumentação seletiva, separar custo de aquisição, solver, worker, packing e publicação. Manter ganhos medidos e separar topologia estática de atributos dinâmicos; comparar p95/p99, picos e frame real. Não usar campanhas repetitivas ou apenas elevar caps.
**I25:** corrigir margens escalonadas, cortes e patches desconectados com provas geométricas e físicas; preservar I11b e I13. R4 shaders, profundidade, espuma/fluxo/lava somente após gate geométrico.
**I26:** integração final R5, benchmark representativo, launcher com ZIP/DLL exatos e execução standalone real, documentos e checkpoint. Aprovação visual humana antes da promoção segundo blueprint; sem merge automático.

Status desta auditoria: I22 PARTIAL, I23–I26 OPEN, R4 BLOCKED_GEOMETRY, R5 PARTIAL. Não foi identificado bloqueio humano. Limite de contexto é uma razão de handoff, não bloqueio do projeto. Regressões corrigidas não transformam uma tarefa parcial em concluída.

## 6. Protocolo de avaliação futura

1. Consultar ref remoto e comparar com o último SHA avaliado (este documento é apenas referência histórica). Buscar commits e diff, confirmar se o novo checkpoint é docs-only e identificar runtime SHA.
2. Ler apenas trechos novos/pertinentes dos quatro documentos do experimento. Ler arquivos implementados e testes relevantes quando houver divergências ou mudança de critério. Consultar logs reais dos jobs finais e dos testes falhos pertinentes; conferir conclusão e SHA de artefatos, job interativo e métricas. Se imagens não puderem ser verificadas diretamente, atribuir observações visuais ao executor e explicitar limitação.
3. Conferir invariantes: ledger initial + injected - drained == hot + cold, sem dupla posse; ticks zero e sequência de chegada; dry cave; revisão certificada e rejeição de staleness; cap residente, cold restores, cobertura e reabertura. Distinguir volume cumulativo transferido de massa única. Conferir critérios alterados e casos removidos/isolados.
4. Comparar métricas com cenários equivalentes; atribuir mudança de custo a mudança de workload apenas como hipótese quando não controlada. Reportar p95/p99 separadamente. Não inventar FPS, porcentagem de conclusão ou aprovação.
5. Relatar o que passou, falhou, ficou parcial e qual o risco mais importante; incluir links diretos para runs e docs, avaliação qualitativa se útil, próxima prioridade e se parada foi justificada. Se pedido, elaborar prompt de execução que parte do HEAD confirmado. Não publicar novo código por conta própria.
6. Atualizar este handoff quando solicitado; manter histórico do SHA avaliado. Não repetir investigações concluídas. Se o executor declara conclusão, confrontar cada requisito antes de aceitar.

### Instruções ao executor a preservar em novos prompts
Loop obrigatório: selecionar tarefa → implementar → commit/push → acompanhar Actions até conclusão → ler logs/artefatos/screenshots → corrigir e revalidar só o necessário → atualizar checkpoint → próxima tarefa. Usar runners Windows locais interativos GPU e Actions nativos/core; não transferir tarefas automatizáveis ao usuário. Não parar em commit, sucesso de workflow, dificuldade rotineira ou relatório intermediário. Se uma frente bloqueia, avançar nas independentes. Só encerrar por aceitação integral ou bloqueio humano comprovado que impede qualquer avanço. Se limite de contexto/executivo real, registrar checkpoint preciso, sem declarar aceitação. Preservar evidências anteriores e não diminuir critérios para fazer testes passarem.

## 7. Referências operacionais

GitHub Actions: https://github.com/publiomcko-labs/sandbox_v2_mvp_godotVoxel/actions
HEAD avaliado: https://github.com/publiomcko-labs/sandbox_v2_mvp_godotVoxel/commit/7102d5180af65754c55305d6f55c988993bf461c
Continuação do executor: https://github.com/publiomcko-labs/sandbox_v2_mvp_godotVoxel/blob/7102d5180af65754c55305d6f55c988993bf461c/docs/V3_4_HYBRID_CONTINUATION.md
Resultados: https://github.com/publiomcko-labs/sandbox_v2_mvp_godotVoxel/blob/7102d5180af65754c55305d6f55c988993bf461c/docs/V3_4_HYBRID_RESULTS.md
Se usar ferramentas GitHub, consultar ref, commits, compare, workflow runs/jobs/logs, artifacts. Acesso ao desktop físico não é presumido; usar runners existentes. Não inventar disponibilidade de ferramenta. Não copiar credenciais ou segredos. Esta auditoria não lançou novos testes nem modificou runtime.
