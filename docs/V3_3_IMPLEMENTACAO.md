# V3.3 — cavernas naturais

Status IN_PROGRESS. Base checkpoint/v3-2-20261126, d02cae1dd6a0a07e278fb599927e6fe37213fd60. V3.2 autorizada a avançar com limitação visual registrada.

Mod data-only karst, perfis karst:natural e karst:wide. Seeds de cinco campos derivados por SHA-256 de seed, ID do perfil, versão e papel, compilados no registry antes de abrir stores. Compatibilidade de save fixa perfil geológico e de cavernas, pins e gerador v3_3_caves_v1. Worlds V3.3 isolados em user://worlds_v33.

Algoritmo: três campos contínuos FBM 3D; a união das interseções par a par cria túneis sinuosos, desníveis e ramificações nas interseções triplas. Câmaras irregulares expandem junções triplas; cobertura variável por ruído 2D permite entradas naturais. Rede superior limitada a 62% da profundidade. Bolsões inferiores deformados por FBM em células globais, com margem sólida entre células e separação vertical mínima de 6m da rede. Sem pré-calcular rede, sem streamer paralelo. SDF resultante usa max do solo original e campo de ar. Geologia permanece derivada da superfície não escavada; mesmos canais e shader V3.2. Perfis anteriores preservam o túnel A5.

Entrada res://scenes/v3_caves_main.tscn; V3_CAVE_PROFILE default karst:natural, V3_CAVE_SPAWN opcional x,y,z. A água ainda é A5 e pode ocupar cavidades abaixo de y=0; V3.4 resolverá sua representação/fluxo. Não confundir cavernas geométricas com simulação de líquidos. Topologia e benchmark comparativo pendentes.
