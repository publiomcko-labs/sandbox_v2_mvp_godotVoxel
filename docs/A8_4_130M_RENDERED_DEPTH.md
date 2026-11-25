# A8-P4 — cobertura visual de terreno a 130 m por pixels e depth buffer reais

Data: 24/11/2026. PR experimental isolado. **Baseline funcional A5/CPU16 GL Compatibility inalterada**, sem merge, sem promoção de gates.

## Por que não repetir LOD3 ou o teste de performance

A8-P3 comprovou que, dos 60 pixels de cinco transições distantes, 45 interseções no terreno SDF **esperado** estavam a 231–317m horizontais e 15 não encontraram terreno até 320m. Nenhum dos 60 raios apontou terreno dentro de 130m. Resultado de investigação local, não um PASS de VIEW-130 nem profundidade rasterizada. PR #22 fechado sem merge.

A8-P4 começa um braço específico de verificação de **profundidade efetivamente rasterizada**, capaz de avaliar a existência de geometria opaca *nos pixels amostrados*, diferente das oito sondas `is_area_meshed` usadas até A8-P3.

## Método A8-P4

- Runtime original Godot 4.7.2, Voxel Tools 1.7, **GL Compatibility/OpenGL3**, mundo A5 CPU16 mesh16/LOD4/view192/seed20261119; nenhum ajuste de worker, mundo, mesher ou física.
- Uma única sessão GPU na GTX1050Ti, 1.000 frames **realmente desenhados** de warmup (limitador de 180s), depois 8 posições angulares de câmera separadas por 45°, em ponto estático (x=192,y=22,z=18) e pitch -22°.
- Antes da coleta, **calibração obrigatória** do depth buffer real com duas superfícies auxiliares em céu livre a 25m e 165m da câmera. O primeiro centro deve ser classificado até 129m, o segundo além de 131m; se uma falhar, o programa salva diagnóstico e **interrompe sem produzir resultados de cobertura**.
- Em cada direção, grava duas imagens de 1920×1080: **RGB normal**, em seguida **depth codificado por pixel** por um postprocess QuadMesh que lê `hint_depth_texture`, reconstrói coordenadas de mundo com `INV_VIEW_MATRIX * INV_PROJECTION_MATRIX` e **NDC OpenGL (-1..1)**. Verde = geometria opaca <129m horizontal; amarelo = 129–131m; vermelho = >131m; azul = nenhum depth opaco; preto/fora da paleta = inválido. Essas são leituras GPU por imagem; não usar o tempo medido nesse braço como FPS.
- RockInstancer, RockManager, Water e HUD são ocultados **somente nesta execução diagnóstica**, para evitar confundir a cobertura do terreno com objetos/água. O depth buffer ainda não identifica **qual objeto específico** gravou a profundidade.
- Por direção, o SDF procedural A5 é consultado em 35 raios independentes, em uma grade 7×5 de pixels fixos, para comparar o **terreno esperado** (<129m) com o **depth rasterizado** no mesmo pixel. Total **280 pixels**.
- O analisador `scripts/a8_p4_depth_report.py` rejeita warmup incompleto, calibração falha, material de evidência trocado, PNG ausente/tamanho incorreto, coordenadas repetidas/erradas, discrepância entre números e raios, ou gates indevidamente promovidos. Gera `a8_p4_review.json`, sumário e SHA256 dos PNGs. O ZIP inclui imagens originais e manifestos, sem SQLite.

A implementação é **diagnóstica de cobertura estática amostrada**: não comprova ausência de fissura entre pixels, continuidade durante os 18m/s, todos os cenários/seeds, precisão de profundidade subpixel, rochas/água nem tela continuamente apresentada sem frames perdidos. Mesmo que os 280 pixels concordem, VIEW-130 permanece NOT_QUALIFIED até critérios de cobertura contínua mais abrangentes.

## Piloto gráfico local (após CI)

GTX1050Ti, desktop Windows desbloqueado, resolução primária pelo menos 1920×1080, Godot custom e DLL A5 previamente instalados:

    cd "C:\Dev\sandbox-a7-etw"
    git fetch origin exp/a8-4-rendered-depth-130m-probe-20261124
    git switch --detach FETCH_HEAD
    powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\a8-p4-depth-windows.ps1"

O comando executa **um único piloto**, sem vídeo DDAGrab/FFmpeg, sem PresentMon, e salva `reports/generated/a8-p4/pilot-.../a8_p4_depth_evidence.zip`. Se a calibração falhar no renderer custom, o ZIP conterá o erro e os PNGs já produzidos para diagnóstico; **não** significa que VIEW-130 falhou.

## CI, gates e próximos passos

CI CPU-only executa apenas **testes sintéticos de contrato, esquema, PNG, proveniência e parser GDScript/shader**, além dos smokes A0–A7/P3. Headless **não tem depth buffer rasterizado**. É proibido concluir que a P4 passou no cenário real antes de receber as imagens da GTX 1050 Ti.

Depois do ZIP, classificar cada observação como: pixel SDF esperado dentro de 130m com depth compatível, pixel esperado mas ausente/mais distante, ou pixel inconclusivo. Só então decidir uma intervenção de streaming/LOD caso exista discrepância **reprodutível dentro de 130m**. Não repetir a bateria A7.4 ou P0/P1.

**Gates estritos** `PERF-60`, `STREAM-18`, `VIEW-130`, `EDIT-100`: **NOT_QUALIFIED**, sem promoção/merge. A5/CPU16 permanece checkpoint funcional.
