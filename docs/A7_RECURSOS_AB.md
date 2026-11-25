# A7 — diagnóstico isolado de recursos do Windows

Branch experimental: exp/a7-resource-utilization-20261120, derivada da A7. A baseline A5/CPU16 e a bateria de aceitação estrita permanecem inalteradas. Nenhuma cena, geração SDF, C++, física, água, rochas ou renderizador foi alterado.

## Hipótese e perfis

Os intervalos próximos a 16,667 ms podem refletir VSync/pacing, não saturação do hardware. O Voxel Tools oferece VoxelEngine.set_thread_count(), mas mais workers também podem provocar concorrência e picos de frame.

- VSync ON, threads padrão (referência)
- VSync OFF, threads padrão (diagnóstico de sincronização)
- VSync OFF, threads intermediárias (até 16, limitadas pela CPU)
- VSync OFF, threads elevadas (até 24, preservando pelo menos quatro lógicas)

A ordem é invertida na segunda repetição. Todos os braços usam a mesma seed, rota, resolução 1920×1080, GL Compatibility, aquecimento de 45 s, telemetria de processo (1 Hz), recursos do terreno e duração de movimento 60 s. Sem capturas PNG. A campanha padrão possui até oito sessões e não é substituta da A7 Full.

## Executar

Em uma sessão de desktop Windows com a tela ativa:

    cd C:\Dev\sandbox_v2_mvp_godotVoxel
    git fetch origin
    git switch --track origin/exp/a7-resource-utilization-20261120
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\a7-resources-ab-windows.ps1

Se a branch já existir localmente, use git switch exp/a7-resource-utilization-20261120 e git merge --ff-only origin/exp/a7-resource-utilization-20261120 antes do teste.

Saída: reports/generated/a7-resources/campaign-*/resource_comparison.csv e resource_comparison.json. A execução registra a quantidade de workers efetiva, modo de VSync solicitado e reportado, CPU usada pelo processo, memória, percentis de frame, render CPU/GPU e as sondas de malha. Compactar a pasta completa para análise, incluindo a7_route.jsonl.

## Limitações e precauções

O driver pode impor VSync mesmo que a Godot reporte o modo desativado. O VoxelEngine pode demorar a estabilizar a nova quantidade de threads; a campanha usa 45 s de warmup. CPU maior não implica redução de latência, especialmente em tarefas seriais da thread principal ou publicação de malhas. A utilização de GPU por processo não é medida neste teste; os tempos de render GPU são indicadores parciais. Caso o p99 aumente ou a cobertura caia, não promover o perfil. Não alterar globalmente plano de energia ou afinidade do Windows para estes testes.

A7 continua NOT_QUALIFIED quanto ao tempo integral CPU+GPU+apresentação, cobertura 130 m por pixels/depth e latência HID até pixel apresentado.
