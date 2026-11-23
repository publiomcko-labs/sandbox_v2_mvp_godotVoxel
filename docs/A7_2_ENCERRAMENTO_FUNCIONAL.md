# A7.2 — encerramento funcional da campanha de 100 edições

**Estado:** `FUNCTIONAL_COMPLETE_WITH_LIMITATIONS` — 23/11/2026.
**Escopo:** apenas a campanha A7.2 de edição (repouso, movimento, fronteiras de chunk).
**Baseline preservada:** A5 CPU16, GL Compatibility, referência `0c3fee959576d0a1faec9ceecffb4b132a65558b`.
**Branch experimental:** `exp/a7-visual-edit-evidence-20261121`, PR #16 (draft).
**CI de referência:** [45229869108](https://github.com/publiomcko-labs/sandbox_v2_mvp_godotVoxel/actions/runs/45229869108) — `success`, CPU-only.

## Evidência e decisão

| Cenário | Evidência válida | Chamadas aceitas | SDF central alterado | Pior aplicação nativa | ETW/desktop |
| --- | --- | ---: | ---: | ---: | --- |
| `edit_idle_100` | `evidence-20261123-102807-51376.zip` | 100/100 | 88/100 | 12,518 ms | ETW exit 0; 100 marcadores |
| `edit_moving_100` | `evidence-20261123-104838-40780.zip` | 100/100 | 100/100 | 16,495 ms | ETW exit 0; 100 marcadores |
| `boundary_edit_100` | `evidence-20261123-140948-49204.zip` | 100/100 | 99/100 | 5,657 ms | ETW exit 0; 100 marcadores após revisão independente |
| **Total** | **3 campanhas válidas para avaliação funcional** | **300/300** | **287/300 amostras centrais** | **16,495 ms máx.** | **300 marcadores sincronizados** |

Uma amostra SDF **central** inalterada não equivale a nenhuma alteração do pincel no raio: é uma sonda pontual, especialmente em operações de adição. A decisão funcional apoia-se em chamadas aceitas, evidência visual, execuções e persistência, não em afirmar 300 mudanças centrais.

Os três casos salvaram em SQLite; os testes anteriores A3/A4/A5 também validam reabertura nas condições implementadas. As capturas e o PresentMon demonstram um caminho observável de execução e oportunidade de apresentação, **não** o primeiro pixel geometricamente correto. Os contadores ETW de eventos/buffers perdidos vieram sem valores explícitos; **não** certificar `ETW_LOSSLESS`.

**Ressalva de proveniência da fronteira:** a aquisição `140948` foi marcada como falha automaticamente porque outro processo ganhou foco **após** a 100ª edição, na saída normal do Godot; a inspeção independente mostrou 100/100 marcadores e mundo no primeiro plano durante as edições. O manifesto original deve continuar intacto como registro do falso positivo; a correção de encerramento está na branch. A captura anterior `105002` tinha navegador sobreposto durante as edições e **não** é evidência visual válida.

## Intervenção A7.3 — encerrada como diagnóstico, sem promoção

O analisador `scripts/a7_pixel_roi_review.py` processou as gravações existentes sem novas capturas nem readback GPU do Godot. O diagnóstico classificou:

| Cenário | Candidato local de alteração visual | Movimento/alteração ambígua | Sem alteração local detectada |
| --- | ---: | ---: | ---: |
| Repouso | 82 | 14 | 4 |
| Movimento | 21 | 76 | 3 |
| Fronteira | 52 | 13 | 35 |
| **Total** | **155** | **103** | **42** |

**155 candidatos não são 155 pixels corretos**; 42 não detectados não são 42 edições defeituosas. Todos os `first_correct_presented_pixel_ms` permanecem desconhecidos. Não promover resultados heurísticos a latência de pixels.

## Matriz de aceite remanescente

| Gate contratual | Estado após A7.2 | Lacuna |
| --- | --- | --- |
| `PERF-60` | `NOT_QUALIFIED` | Tempo de quadro completo CPU + GPU + apresentação com limite de 16,7ms; vídeo NVENC ~58–59fps com PTS repetidos não é PASS |
| `STREAM-18` | `NOT_QUALIFIED` | Continuidade sem fissuras em todas as rotas frias/quentes, com terreno/rochas/água no vídeo completo |
| `VIEW-130` | `NOT_QUALIFIED` | Cobertura real de 130m e 360° por imagem e profundidade, não apenas 8/8 sondas de malha |
| `EDIT-100` | `NOT_QUALIFIED` | Primeiro pixel **correto** apresentado em até 100ms, com referência geométrica independente, não marcador, SDF central ou `frame_post_draw` |

`FUNCTIONAL_COMPLETE_WITH_LIMITATIONS` não substitui `PASS` desses quatro gates.

## Decisão de encerramento

1. Encerrar A7.2 no plano **funcional**. Não repetir automaticamente `edit_idle_100`, `edit_moving_100` e `boundary_edit_100`: já há 300 chamadas aceitas e evidência compatível com o escopo funcional.
2. Preservar A5/CPU16 como referência, sem merge/promoção de variantes A6/A6B nem de otimizações não comprovadas; manter PR #16 **draft** como trilha de evidência.
3. Próxima intervenção recomendada: **A7.4 — qualificação estrita direcionada**, iniciando com um piloto estático e de fronteira com referência geométrica independente de pixels corretos e correlacionando brush UTC, vídeo e ETW. A prova deve ser fail-closed e não depender do marcador HUD. Executar campanha adicional apenas se o piloto demonstrar capacidade de medição válida. Após `EDIT-100`, abordar `PERF-60`, `STREAM-18` e `VIEW-130` com seus próprios instrumentos. A7 não termina até a matriz ser decidida com evidências ou explicitamente deixada `NOT_QUALIFIED`.
4. Depois de documentar a aceitação final A7, a sequência prevista pelo contrato é validar **build Windows Release/export** e comparar este MVP ao `sandbox_v2_mvp_rustBevy` sob cargas equivalentes. Não criar uma fase A8 fictícia nem declarar o MVP concluído antes da evidência.

**Nenhuma execução adicional no Windows exigida para encerrar A7.2.**
