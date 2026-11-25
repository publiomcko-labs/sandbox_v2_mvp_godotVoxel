# A1 — terreno SDF com cavernas e LOD inicial

Estado: implementação proposta para validação A1. A0 já teve aprovação headless e terreno visível em teste local do usuário. **Não interpretar o smoke da A1 como gate gráfico aprovado.**

## Implementado
- Geração SDF determinística em \`VoxelGeneratorGraph\`, com \`ZN_FastNoiseLite\` de baixa e média frequência (seeds explícitas).
- Um túnel volumétrico contínuo aproximadamente em y=-11, eixo ao longo de X, raio ~4,6 unidades, sinuoso por noise 2D, com acesso vertical na região (x=38,z=0).
- Reutiliza \`VoxelLodTerrain\` e \`VoxelMesherTransvoxel\` nativos; quatro LODs, malha de bloco 16, view distance solicitada de 192 unidades e \`lod_distance=48\`. Nenhum segundo gerenciador de regiões.
- Câmera livre a 18 m/s; W/A/S/D, E/Q, clique esquerdo para capturar mouse e Escape para liberá-lo.
- Testes de SDF positivo/negativo (túnel, rocha, ar e entrada), seed fixa, variação entre seeds e validação da cena em headless.

## Execução local

PowerShell, após A0 bootstrap já compilado na mesma pasta (o DLL gerado é ignorado no Git e permanece no checkout ao alternar de branch):

\`\`\`powershell
git fetch origin
git switch feat/a1-sdf-caves-lod-130m-20261119
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\a1-smoke-windows.ps1
& .\.tools\godot.exe --path .\godot
\`\`\`

Se \`.tools/godot.exe\` ou \`godot/bin/sandbox_native.windows.template_debug.x86_64.dll\` estiver ausente, execute o bootstrap A0 e depois o smoke A1.

## Gatilhos de qualificação

| Gate | Condição | Estado |
|---|---|---|
| A1-GRAPH | Compilação de grafo SDF, determinismo e interior de caverna | Pendente de CI |
| A1-LOD | Configuração 4 LODs e horizonte solicitado | Pendente de CI |
| VIEW-130 | Cobertura *efetivamente renderizada* de 130m em todas as direções, incluindo diagonais | Não testado |
| A1-SEAM | Sem frestas em transições de LOD durante voo panorâmico e deslocamento | Não testado |
| A1-TRAVERSAL | Entrada vertical e túnel conectados; observação visual sem cortes | Não testado |
| A1-PERF | 1080p, frame completo ≤16,7ms (métricas p99, máximo, GPU+present) | Não testado |

**Limitação importante:** resolução base de voxel permanece em 1 unidade do Voxel Tools; equivalência de 0,5 m no núcleo ainda não implementada e deve ser resolvida antes da qualificação final. Não mascarar perda de cobertura diminuindo o raio, aplicando neblina opaca ou pausando a câmera. A2 avaliará streaming a 18 m/s de maneira reproduzível, A3 edição e persistência.
