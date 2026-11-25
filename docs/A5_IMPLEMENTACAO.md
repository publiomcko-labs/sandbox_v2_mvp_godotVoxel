# A5 — Oceano contínuo e física aquática

**Entrada:** \`checkpoint/a4-functional-20261119\` (cc81d83e7469e7f086a0b4bb734e9088e175c46b), aprovado funcionalmente com diferença cosmética entre malha estática e rocha dinâmica. A A5 mantém seed, C++20/GDExtension, gerador SDF, SQLite, Voxel Tools e o streaming A0–A4; nada é mesclado na main.

## Implementação
Uma única \`PlaneMesh\` transparente com 640 × 640 m permanece no nível mundial y=0, seguindo o jogador em X/Z sem ser recriada. O shader apresenta ondulação óptica baseada em coordenadas globais e não desloca a altura dos vértices. O terreno opaco oculta a água onde estiver acima de y=0; escavar abaixo dessa cota revela a mesma superfície, sem criar tiles ou invalidar meshes de água. O volume \`Area3D\` (128 × 128 × 128 m, teto y=0) segue o jogador somente para os corpos locais.

Para \`RigidBody3D\` ativos e imersos: força de empuxo \`F=ρgVf\` para uma esfera (fração submersa calculada pelo volume da calota), arrasto proporcional à velocidade relativa à corrente, processamento limitado a 24 corpos. Um curso de água prescrito tem velocidade 2,2 m/s para \`|z-30|≤7 m\`. Não há simulação CFD, erosão, propagação de ondas, água voxelizada, gerenciamento de regiões nem estado de água persistido; o nível é uma propriedade determinística constante.

Rochas têm massa de 3600kg e volume de aproximadamente 1,437m³, afundando em água de 1000kg/m³. Um corpo leve de teste com massa 250kg e mesmo volume flutua. O Player é \`CharacterBody3D\` com cápsula; começa em voo livre a 18m/s, preservando controles A1–A4. Tecla \`G\` ativa o modo físico (gravidade/contato/nado quando imerso) e alterna de volta. Nado limitado a 7m/s, E/Q controlam ascensão/imersão. **O padrão de voo continua sem colisão.**

## Executar localmente

\`\`\`powershell
cd C:\Dev\sandbox_v2_mvp_godotVoxel
git fetch origin
git switch --track origin/feat/a5-ocean-buoyancy-shoreline-20261119
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\a5-smoke-windows.ps1
& .\.tools\godot.exe --path .\godot
\`\`\`

Nenhuma recompilação da GDExtension é necessária após checkout partindo da A4 (nenhum arquivo nativo modificado). O smoke usa apenas \`reports/generated/a5-ci\` para arquivos de teste; não interfere com os saves do jogo.

## Critérios

| Gate | Procedimento | Estado inicial |
|---|---|---|
| A5-STATIC | superfície y=0, uma PlaneMesh, nenhuma criação por chunk | Pendente de CI |
| A5-PHYSICS | esfera densa afunda, leve flutua, corrente desloca, contato em fixture | Pendente de CI |
| A5-COAST | edição SDF abaixo de y=0, malha reaproveitada, SQLite reabre editado | Pendente de CI (somente dados) |
| A5-SWIM | CharacterBody3D transita do ar para água com gravidade/arrasto | Pendente de teste visual |
| VIEW-130/STREAM-18 | água acompanha solo/rochas sem flash ao mover a 18m/s | Não qualificado |
| PERF-60/EDIT-100 | CPU+GPU+apresentação e tempo até primeiro pixel correto | Não qualificado |

O teste headless NÃO garante a continuidade de pixels, relação visual com a costa, iluminação da água ou ausência de queda física através do terreno após edição. Ainda falta validar em sessão gráfica. O raio do water mesh é superior a 130m, mas isso por si não comprova a cobertura efetivamente apresentada.

**Limitações:** sem hidráulica de volume finito; água em galerias abaixo de y=0 é tratada como imersa mesmo quando há teto sólido; a corrente é um campo prescrito na faixa z≈30 e não requer um canal escavado no relevo; sem personagem físico automático por padrão, por compatibilidade com a baseline de 18m/s.
