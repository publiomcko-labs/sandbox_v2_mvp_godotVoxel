# A7 — estresse de streaming + apresentação ETW (sem promoção)

Branch isolada: exp/a7-streaming-present-20261121. Base herdada: A5/CPU16 com Godot 4.7.2 / Voxel Tools 1.7, GL Compatibility, 16 voxels, LOD4, visão 192 m, 18 m/s e threads automáticas. Não modificar os parâmetros do jogo nem promover as otimizações A6.

## Hipótese

O A/B anterior mostrou ~60 FPS com VSync e intervalos internos muito menores sem VSync. Os intervalos entre callbacks do Godot não provam tempo de exibição. Este teste registra, em todos os braços, o consumo do processo (CPU/RAM 1 Hz), trace A7 de terreno/rochas/água, intervalos de _process() e traços de frame apresentado via Intel PresentMon 2.6.0.

Versão externa fixa: Intel PresentMon 2.6.0 standalone, download oficial:
https://github.com/GameTechDev/PresentMon/releases/download/v2.6.0/PresentMon-2.6.0-x64.exe

SHA256: b2a706bc6ad475749e3b7e3409263aa1e6906d45bdcf993f6dbc0f660188f1af

O download é recusado se o hash não corresponder. O coletor de ETW é vinculado ao PID exclusivo do Godot. Não coleta todos os processos do sistema.

## Carga e desenho

- Trajeto reto contínuo: straight_18mps_600s, 300 s medidos (~5.400 m).
- Curvas: turns_18mps_300s, 180 s medidos.
- Água e rochas: rocks_water_180s, 180 s medidos.
- Linha costeira: shoreline_180s, 180 s medidos.
- Cada trajeto é medido com VSync ON e OFF, com seed 20261119 e 45 s de aquecimento, instrumentação idêntica, 1920x1080 na janela Godot e nenhuma captura PNG durante a medição.
- A ordem ON/OFF é alternada entre rotas. Nenhum ajuste de VoxelEngine.set_thread_count é aplicado.
- Todos os braços são diagnósticos. Esta campanha de uma seed não aprova automaticamente nenhum gate de aceitação.

## Medidas e verificação

O runtime Godot grava timestamps de início/fim da janela de movimento em época Unix. O PresentMon grava CPUStartDateTime e per-frame DisplayLatency, MsBetweenDisplayChange, MsBetweenPresents, MsGPUTime; os dois fluxos são alinhados no relatório. A parser exige ao menos 100 frames apresentados e cobertura temporal >=85% da janela. Ausência de ETW válido produz NOT_MEASURED ou ETW_INCOMPLETE, nunca um PASS inventado.

DisplayLatency corresponde ao tempo do início da preparação do frame na CPU até sua exibição segundo ETW; MsBetweenDisplayChange corresponde à cadência efetiva das atualizações de tela. Essas métricas não medem o fóton no painel, não validam pixels de terreno a 130 m nem latência HID→pixel de edição. As metas estritas PERF-60, STREAM-18, VIEW-130 e EDIT-100 permanecem NOT_QUALIFIED até evidência independente.

## Execução automática

Workflow: .github/workflows/a7-streaming-present-interactive.yml, em GitHub Actions, runner [self-hosted, Windows, X64, interactive-gpu], preflight de desktop interativo no DESKTOP-SAFGO15 com NVIDIA GTX 1050 Ti, resolução física mínima 1920x1080.

O job baixa o binário externo com SHA fixo, prepara Godot/DLL aprovados, valida os contratos e executa a campanha. Relatórios e ETW CSV em ZIP são preservados em artifact mesmo diante de falhas após checkout.

Arquivos principais no artefato:
- streaming_manifest.json: condições e provenance
- streaming_comparison.json/.csv: comparação consolidada
- a7_route.json/.jsonl, a7_process_resources.json, a7_process_resource_summary.json: instrumentação canônica
- a7_presentmon_status.json: estado do coletor
- a7_presentmon.csv.zip: evidência bruta sem perdas
- a7_present_analysis.json: tempos de apresentação e status de alinhamento

O PresentMon exige que o usuário Windows do runner pertença ao grupo **Performance Log Users** (SID S-1-5-32-559) ou que o processo seja elevado. O workflow **não eleva privilégios nem altera a associação a grupos**. Sem essa permissão, a campanha continua medindo CPU, GPU parcial e streaming em ambos os braços; os campos de apresentação são marcados como `NOT_MEASURED`, sem fingir aprovação. As capturas ETW inválidas também não causam aprovação.

Para habilitar ETW posteriormente, um administrador pode adicionar explicitamente a conta `DESKTOP-SAFGO15\\PUBLI` ao grupo local Performance Log Users e depois criar uma **nova sessão de logon** para atualizar o token Windows. O usuário deverá concordar com essa mudança; a execução atual não a fará automaticamente. Não executar todo o runner GitHub Actions como administrador.

Se o ETW não funcionar em OpenGL/driver ou a conta do runner não possuir permissões adequadas, manter status não qualificado; não elevar privilégios automaticamente nem alterar o Windows sem autorização.

## Critério de promoção

Nenhuma alteração de baseline/threads é candidata à promoção nesta campanha. Resultado deve separar: (1) p99 de frame Godot, (2) tempo da GPU, (3) CPU-frame-start→display ETW, (4) cadência real exibida, (5) sondas de malha e sinais de gaps. Requer subsequente prova por pixel para VIEW-130 e STREAM-18 e HID/present para EDIT-100.
