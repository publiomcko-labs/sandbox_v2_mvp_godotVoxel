# V3.3 — cavernas naturais

Status FUNCTIONAL_HEADLESS_PASS — GRAPHICAL_ROUTE_PENDING. Base checkpoint/v3-2-20261126, d02cae1dd6a0a07e278fb599927e6fe37213fd60. V3.2 autorizada a avançar com limitação visual registrada.

Mod data-only karst, perfis karst:natural e karst:wide. Seeds de cinco campos derivados por SHA-256 de seed, ID do perfil, versão e papel, compilados no registry antes de abrir stores. Compatibilidade de save fixa perfil geológico e de cavernas, pins e gerador v3_3_caves_v1. Worlds V3.3 isolados em user://worlds_v33.

Algoritmo: três campos contínuos FBM 3D; a união das interseções par a par cria túneis sinuosos, desníveis e ramificações nas interseções triplas. Câmaras irregulares expandem junções triplas; cobertura variável por ruído 2D permite entradas naturais. Rede superior limitada a 62% da profundidade. Bolsões inferiores deformados por FBM em células globais, com margem sólida entre células e separação vertical mínima de 6m da rede. Sem pré-calcular rede, sem streamer paralelo. SDF resultante usa max do solo original e campo de ar. Geologia permanece derivada da superfície não escavada; mesmos canais e shader V3.2. Perfis anteriores preservam o túnel A5.

Entrada res://scenes/v3_caves_main.tscn; V3_CAVE_PROFILE default karst:natural, V3_CAVE_SPAWN opcional x,y,z. A água ainda é A5 e pode ocupar cavidades abaixo de y=0; V3.4 resolverá sua representação/fluxo. Não confundir cavernas geométricas com simulação de líquidos. Topologia e benchmark comparativo pendentes.

Fixture: dois perfis/seeds, grade finita 80³ com passo de 2m (160m de lado), flood fill de vizinhança 6 para componentes conectados à superfície e bolsões profundos fechados dentro do volume. Gate de amostras exige entradas, componente conectado com profundidade mínima 16m, amostras de junção e clearance axial 4m, bolsão isolado e fração de ar limitada. Grau de vizinhança não prova topologia de ramificação formal; clearance amostral não prova colisão; rota gráfica requerida. Alinhamento LOD0/1 e geração repetida por bloco, construção de basalto e reopen SQLite. Benchmark micro de generate_block real: 24 origens, warmup 24 e 72 blocos cronometrados por braço A5/V3.2/V3.3, LOD0, sem FPS/qualificação gráfica.

## Resultado — 26/11/2026

Candidato b295af24b313f3cac505cfda36d4f9e1c778b8fd: Actions [45849940174](https://github.com/publiomcko-labs/sandbox_v2_mvp_godotVoxel/actions/runs/45849940174) SUCCESS, 2min19s entre criação e atualização final. Regressões A5/V3.1/V3.2 e V3_CAVES_E2E_PASS; nenhum erro de shader/script nos logs. Contratos GCC/MSVC 45849772909 SUCCESS com seeds idênticas [1346196365,1914169279,151450886,186393434,1762128814].

| Medida amostral | natural seed 20261119 | wide seed 20261120 |
|---|---:|---:|
| Fração ar subterrâneo | 14,61% | 19,37% |
| Maior componente conectado a amostras superficiais | 58409 | 77930 |
| Amostras superficiais no componente | 1287 | 1799 |
| Profundidade máxima conectada (m) | 69,18 | 89,02 |
| Amostras clearance axial 4m | 5628 | 14309 |
| Bolsões profundos isolados dentro da grade | 22 | 16 |
| A5 us/bloco | 217,89 | 214,90 |
| V3.2 us/bloco | 823,97 | 816,28 |
| V3.3 us/bloco | 1961,74 | 1920,17 |
| Razão V3.3/A5 | 9,00x | 8,94x |
| Razão V3.3/V3.2 | 2,38x | 2,35x |

Determinismo/amostras LOD0/1 e material de construção reaberto via SQLite passaram. Custos medidos em CI Windows hosted, geração direta em CPU, não medem streaming/FPS/p95/p99 nem garantem desempenho no desktop. Regressão de custo real significativa, a investigar no benchmark integrado antes de promover gates de desempenho; não otimizar sem evidência de gargalo no caminho interativo. Topologia é amostral: conexões na grade, não garantia de passagem livre contínua ou ramificação esquelética. O ponto de spawn Entrada fica 3m acima da amostra superficial (natural 60,8,78; wide -66,8,70); Deep usa amostra de ar profunda (-26,-70,-34 ou -6,-86,26), sem garantia de clearance para colisão. Script scripts/v3-caves-local-windows.ps1 usa artefato 15133761312, SHA256 a3edefb5eb0b27a1c77dac5bdb920fcfda7b22729b89baa459d54426de7c6222, mundo descartável, logs e metadata. Nenhuma qualificação gráfica automática. Água A5 ainda não representa fluxo localizado (V3.4). Não alterar main/A5.

## V3.3b — correção da superfície, 26/11/2026

Teste visual do usuário rejeitou a V3.3 inicial: relevo esburacado e fragmentado. Causa de geração confirmada no graph: cobertura anterior era ruído 2D centrado aproximadamente em zero, permitindo interseções de campos e grandes câmaras interceptarem a superfície em regiões extensas. Não confundir automaticamente as aberturas com falhas de LOD. V3.3b impõe teto sólido de 12/14 m abaixo da superfície original para a rede principal, reduz os raios de túneis/câmaras, e separa entradas estreitas em células de 80/88 m com jitter contínuo e inclinação, alargando-as gradualmente em profundidade. Preserva os cinco campos de ruído prévios; sexto seed exclusivo para jitter Z. Mod karst 1.1.0, gerador v3_3_caves_v2 e saves isolados user://worlds_v33b. Não reabrir mundos V3.3v1. Gate adicional por colunas amostradas: superfície aberta <=2%, faixa até 8m <=4%, mantém conectividade subterrânea e bolsões. Frações e geometria são amostrais, não garantia visual ou de passagem contínua. Água legada segue pendente V3.4. Validação em andamento.
