# Backlog pós-MVP — não bloqueante para encerramento funcional

Baseline congelada A5/CPU16. Não iniciar automaticamente novas campanhas ou alterações; priorizar após comparação arquitetural com Rust + Bevy. Cada intervenção futura deve manter baseline isolada, mesmas seeds, hardware, carga e instrumentação entre braços.

| Prioridade | Frente | Resultado esperado |
|---|---|---|
| P0 | Comparação Godot vs Rust + Bevy | Mesmas cargas e critérios; distinguir funcional, nominal, amostrado, estimado e formalmente qualificado. |
| P1 | Export Windows Release e instalação limpa | Build reproduzível, dependências fixadas, teste smoke fora do editor e distribuição; ainda não exportado/validado. |
| P1 | Edições 10k/100k/1M e SQLite | Cenários concentrados e dispersos; RAM, I/O, p99.9, reabertura, backlog e custo por bloco, não apenas por clique. [Issue #27](https://github.com/publiomcko-labs/sandbox_v2_mvp_godotVoxel/issues/27). |
| P1 | Rochas promovidas 1k/10k/100k | Eliminar, se comprovado, custo global de corpos congelados, ordenação e regravação do JSON; persistência espacial, ativação local e identidade estável. |
| P1 | Integridade de persistência | Save incremental e recuperação de interrupção; consistência entre SQLite e sidecar JSON, migração e compatibilidade. |
| P2 | PERF-60 estrito | Atribuição de caudas por frame, ETW com contadores de perdas válidos; otimizar apenas gargalo demonstrado, evitar regressão por instrumentação. |
| P2 | STREAM-18 / VIEW-130 estritos | Confirmar cobertura 130 m, 360°, trajetórias frias/quentes e publicação de terreno, rochas e água; examinar raras falhas visuais em movimento e transições periféricas. |
| P2 | EDIT-100 estrito e colisão pós-edição | Associação inequívoca frame–ETW, primeiro pixel correto, HID se necessário, adições de pequena amplitude, oclusões e colisão atualizada. Não repetir bateria integral sem objetivo específico. |
| P2 | Água e rochas visuais | Substituir oceano global y=0 onde inadequado por volumes/corpos d'água locais; consistência visual de rocha estática/promovida (dimensão, iluminação); manter física e persistência. |

Gates estritos continuam NOT_QUALIFIED; risco de escala não é falha demonstrada. Não promover A6/A8, alterar mesher/LOD/workers ou reabrir campanhas sem evidência causal.
