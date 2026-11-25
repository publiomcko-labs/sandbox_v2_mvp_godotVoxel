# Encerramento funcional — MVP A (Godot + Voxel Tools + C++)

**25/11/2026 | MVP_FUNCTIONAL_COMPLETE_WITH_LIMITATIONS**

Decisão de escopo: encerrar o MVP funcional sem novas campanhas exaustivas, conforme orientação do responsável. Esta decisão não modifica o contrato original nem transforma evidência diagnóstica em aprovação formal. A comparação com Rust + Bevy deve preservar essa distinção.

## Checkpoint e publicação

- Código funcional: A5/CPU16, `0c3fee959576d0a1faec9ceecffb4b132a65558b`, checkpoint anterior imutável `checkpoint/a5-functional-20261119`. O novo checkpoint contém apenas README e documentos de encerramento; código, configuração e workflow são os mesmos da A5.
- Godot 4.7.2, Voxel Tools 1.7, C++20, GL Compatibility, CPU mesh block 16, quatro LODs, view distance solicitado 192 m. Baseline funcional [CI A5 #37](https://github.com/publiomcko-labs/sandbox_v2_mvp_godotVoxel/actions/runs/44572157321), sucesso.
- Diagnósticos A6–A8 conservados em suas branches; último código A8-P8.3 `b38b66e1193c88a5c1976cb99042760bceb97e1b` ([CI #238](https://github.com/publiomcko-labs/sandbox_v2_mvp_godotVoxel/actions/runs/45606170030), 49/49 etapas aprovadas em runner CPU/headless). Não incorporar shaders diagnósticos, água opaca, overlays ou instrumentação experimental no runtime publicado.
- Branch final: `checkpoint/mvp-a-functional-final-20261125`. Publicação de código-fonte; não equivale a export Windows Release, pacote executável ou qualificação de produção.

## Matriz de resultados

| Requisito | Evidência | Decisão prática | Gate estrito |
|---|---|---|---|
| Mundo procedural, cavernas, edição add/remove | A1–A3, A7.2: 300/300 chamadas aceitas em repouso, movimento e fronteira; 287/300 amostras SDF centrais alteradas, não 300 mudanças centrais | Funcional | Escopo funcional aceito |
| Persistência | SQLite, reabertura A3/A4/A5 e saves A7/A8 | Funcional em escala testada | Não qualificada para 1M operações/crash |
| Rochas | MultiMesh nativo, promoção seletiva, física e reabertura | Funcional | Escala de promovidas pendente |
| Água | Plano oceânico y=0, corrente prescrita, empuxo, arrasto, nado | Física básica funcional | Sem CFD nem hidrologia local |
| PERF-60 | A8-P7: 1799 apresentações, 1798 intervalos, ~59,99 FPS; mediana 16,676 ms, p99 16,750 ms, máximo 17,618 ms; 392 >16,7 ms, 0 >20 ms; 0 drops registrados | 60 FPS nominal no piloto | NOT_QUALIFIED |
| STREAM-18 | Rotas a 18 m/s e evidência dinâmica de 30 s; sem ausência confirmada nos raios seguros observados | Evidência positiva amostrada | NOT_QUALIFIED |
| VIEW-130 | P4 216/216 raios estáticos esperados dentro de 130 m; P5 799/799 raios seguros <125 m; P6 auditoria offline dos frames capturados com margem <120 m | Cobertura amostrada, não integral | NOT_QUALIFIED |
| EDIT-100 | P8.3: 12/12 chamadas aceitas, 3656 comparações de sinal CSG sem divergência; 7/12 classificações do analisador original compatíveis, 30,912–48,525 ms de proxy de desenho | Evidência positiva, estimativa temporal exploratória | NOT_QUALIFIED |

## Fechamento das campanhas

- **A6:** não promover CPU32/GPU ou variantes sem ganho canônico demonstrado; preservar A5 CPU16.
- **A7:** [encerramento funcional A7.2](https://github.com/publiomcko-labs/sandbox_v2_mvp_godotVoxel/blob/b38b66e1193c88a5c1976cb99042760bceb97e1b/docs/A7_2_ENCERRAMENTO_FUNCIONAL.md). Sem confundir chamadas aceitas ou marcadores com primeiro pixel correto.
- **A8-P4/P5/P6:** [P4](https://github.com/publiomcko-labs/sandbox_v2_mvp_godotVoxel/blob/b38b66e1193c88a5c1976cb99042760bceb97e1b/docs/A8_4_FIRST_GPU_RESULT.md), [P5](https://github.com/publiomcko-labs/sandbox_v2_mvp_godotVoxel/blob/b38b66e1193c88a5c1976cb99042760bceb97e1b/docs/A8_5_FIRST_GPU_RESULT.md), [P6](https://github.com/publiomcko-labs/sandbox_v2_mvp_godotVoxel/blob/b38b66e1193c88a5c1976cb99042760bceb97e1b/docs/A8_6_OFFLINE_ALL_FRAMES.md), [issue #26](https://github.com/publiomcko-labs/sandbox_v2_mvp_godotVoxel/issues/26). Evidência estática/dinâmica amostrada; compressão, gaps/PTS e margem espacial impedem cobertura integral. A cifra de 8652/8652 relatada na revisão offline anterior não é certificada novamente neste encerramento.
- **A8-P7:** [registro final](https://github.com/publiomcko-labs/sandbox_v2_mvp_godotVoxel/blob/b38b66e1193c88a5c1976cb99042760bceb97e1b/docs/A8_7_ENCERRAMENTO.md), commit testado `e19a456bef0dca475b8a0a4b82c094dbeece4a99`. Uma rota de 30 s, seed 20261119, GTX 1050 Ti, 1000 frames de warmup, VSync; ETW sem contadores de perda explícitos, sem atribuição causal por frame. Não aprovar o limite de 16,7 ms por FPS médio.
- **A8-P8.1–P8.3:** [P8.1](https://github.com/publiomcko-labs/sandbox_v2_mvp_godotVoxel/blob/b38b66e1193c88a5c1976cb99042760bceb97e1b/docs/A8_8_1_GEOMETRY_TIME.md), [P8.2](https://github.com/publiomcko-labs/sandbox_v2_mvp_godotVoxel/blob/b38b66e1193c88a5c1976cb99042760bceb97e1b/docs/A8_8_2_STABILITY_PRECISION.md), [P8.3](https://github.com/publiomcko-labs/sandbox_v2_mvp_godotVoxel/blob/b38b66e1193c88a5c1976cb99042760bceb97e1b/docs/A8_8_3_SEMANTIC_DEPTH.md). 2799 frames decodificados, 241 IDs estáveis, 25 ausentes, zero IDs conflitantes. Calibração empírica P8.3: 0,060901643 m, inferior a 0,10 m; 6 painéis fit, 5 holdout, 55 amostras holdout, 3/3 classes calibradas. Tolerância geométrica CSG 0,45 m é distinta do erro do sensor.

## EDIT-100: delimitação da aceitação

O relatório original A8-P8.3 comprova correspondência geométrica em 7/12 edições (1, 3, 5, 7, 8, 10, 11). As edições 2, 4, 6, 9, 12 não têm `first_sampled_csg_match` nesse relatório. Nenhuma está registrada como falha funcional. A revisão conversacional ampliada, retrospectiva, registrou candidatos nas 11 edições consideradas após exclusão da edição 11 por decisão do responsável (possível interferência da captura); edição 9 sujeita a oclusão por rochas. A exclusão não apaga o resultado original da edição 11. As estimativas conversacionais de apresentação foram 66,75 ms mediana, 83,05 ms máximo e 99,69 ms na hipótese do próximo evento. São **estimativas exploratórias relatadas**, não resultados do analisador original nem limite comprovado; não há artefato independente de correlação temporal no pacote e não há identidade exata frame–ETW. Não reivindicar 11/11 aprovações formais, pixel apresentado ou latência HID-to-photon.

O resultado original de todos os gates permanece `NOT_QUALIFIED`. Encerramento funcional autorizado com limitações aceitas para seleção de arquitetura; não iniciar A8-P8.4 nem novas coletas automaticamente.

## Proveniência

Pacotes originais preservados fora do GitHub (não publicar gravação do desktop, bancos ou saves). SHA-256 do ZIP P7 bem-sucedido: `41a08b756d7f87e07ca7290e39baaa2f2c93e759859b631d70077e924ab5c510`. SHA-256 do ZIP P8.3: `30039b05260a386170c047666e3717a64b05f6806398e14e806c07d6e8e0bda6`. Manifesto P8.3 aponta para `b38b66e1193c88a5c1976cb99042760bceb97e1b`; hashes do vídeo, trace e CSV ETW recalculados e idênticos ao relatório. Veja [MVP_A_RESULTADOS.json](MVP_A_RESULTADOS.json) para os dados e ressalvas. Próximas melhorias: [POS_MVP.md](POS_MVP.md) e [issue #27](https://github.com/publiomcko-labs/sandbox_v2_mvp_godotVoxel/issues/27).
