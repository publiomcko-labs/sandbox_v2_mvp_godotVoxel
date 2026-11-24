# A8-P5 — continuidade dinâmica RGB e profundidade real a 18 m/s

Data: 24/11/2026. Issue #24. **Diagnóstico experimental; A5 CPU16 GL Compatibility e main intactos.**

## Entrada comprovada

A8-P4 (PR #23, encerrado sem merge) calibrou o depth real a 25m e 165m, encontrou **216/216 pixels** de profundidade compatível com terreno procedural esperado dentro de 130m, em um ponto estático e oito direções (280 amostras totais). Isso não prova continuidade ao deslocar a câmera. A8-P3 apontou 45/60 interseções esperadas a 231–317m nos cinco pops distantes, e nenhuma dentro de 130m. Investigar mais LOD3 distante fica secundário.

## Hipótese / implementação

**H0:** não existe ausência persistente de geometria opaca dentro de 125m nos 35 pixels SDF seguros examinados a cada segundo durante 30s a 18m/s, seed 20261119, rota com curva aos 20s.

**H1:** um ou mais desses pontos aparecem sem depth opaco verde ou com depth distante/indeterminado no vídeo, exigindo revisão quadro a quadro com PTS e posição.

São hipóteses **sobre amostras**, não certificação de todos os frames/130m/360°.

- Dois **braços distintos** na mesma branch, seed, resolução e rota: **RGB normal** e **depth codificado**. Cada braço registra 1000 frames de warmup realmente desenhados e 30 segundos de percurso `turns_18mps_300s` a 18m/s. O segundo tem pós-processamento isolado usando o mesmo `hint_depth_texture` GL Compatibility validado na A8-P4. Não são dois benchmarks de FPS.
- O braço depth calibra de novo o depth buffer real com painéis em **25 e 165 m**, **antes** dos 1000 frames de warmup, e registra o resultado na telemetria. Se qualquer painel falhar, o teste falha sem certificação.
- As duas gravações usam DDAGrab + NVENC 1080p/60fps, **sem readback do framebuffer durante movimento**. Só os painéis de calibração utilizam duas leituras GPU, fora da medição. O RGB preserva água, rochas e HUD da cena funcional; a profundidade exibe a superfície opaca e não identifica objetos ou água transparente.
- Em cada segundo da rota do braço depth, consulta o **SDF procedural nativo independente**, 7 colunas × 5 linhas (35 pontos), total 30 amostras temporais principais × 35 = **1050 pares esperados**. Mais uma amostra de encerramento aos 30s pode estar presente, mas é excluída da avaliação primária.
- O marcador HUD verde/magenta original da A7 é preservado fora da máscara de profundidade (CanvasLayer). `a7_video_timeline.py` vincula cada vídeo ao relógio da rota por 31 transições a 1Hz. O auditor escolhe um frame efetivamente decodificado após cada marcador, **sem interpolação nem duplicação**, e lê os mesmos 35 pixels no vídeo depth original H.264.
- Terreno SDF horizontal **inferior a 125m** é alvo seguro; acima de 135m fica fora da inferência de cobertura, e 125–135m é guardado como fronteira/inconclusivo. Margem conservadora de 5m cobre o atraso entre frame SDF, vídeo PTS e deslocamento de 18m/s (p99 de alinhamento de HUD <=50ms). Verde no vídeo depth (depth real <129m) é resultado compatível, vermelho/azul/amarelo/indeterminado é **candidato** e exige verificação no RGB original; nunca prova automática de lacuna.
- O validador `scripts/a8_p5_dynamic_depth_review.py` confronta manifestos A5/CPU16, mesmo SHA e seed nos dois braços, 1000 frames, 31 marcadores por vídeo, 30 instantes válidos, 35 pixels originais por instante, caminho do jogador, intervalos de classe e profundidade, calibração 25/165 e existência/integridade dos dois MKVs. Rejeita diferença de versão entre braços, amostras faltantes, vídeo sem marcador, mudança de rota ou gates prematuramente promovidos.
- Testes do CI são **apenas sintéticos e de sintaxe**: GDScript, PNGs, parser PowerShell e objetos de vídeo simulados. CI headless **não mede depth rasterizado**, nem fps do NVENC nem streaming. Só o ZIP gráfico da GTX 1050 Ti pode fornecer dados reais.

## Execute somente o piloto pareado, no computador GTX 1050 Ti

    cd "C:\Dev\sandbox-a7-etw"
    git fetch origin exp/a8-5-dynamic-depth-video-130m-20261124
    git switch --detach FETCH_HEAD
    powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\a8-p5-dynamic-depth-windows.ps1"

Requer desktop desbloqueado, monitor principal com >=1920×1080 no canto (0,0), Godot custom+DLL do A5, FFmpeg/NVENC da A7. O invocador começa gravando RGB, depois depth, cada um com **warmup 1000 frames + 30s**, sem outras repetições. Se algum braço falhar, gera ZIP com evidências parciais e erro; **não repetir automaticamente** sem investigar a causa.

Artefato: `reports/generated/a8-p5/pilot-.../a8_p5_dynamic_depth_evidence.zip`, contendo dois vídeos originais, manifestos, traces, timelines e `a8_p5_review.json`. Pode ter tamanho considerável por incluir dois vídeos.

## Regras de interpretação e aceitação

1. Havendo candidato na área SDF <125m, verificar o frame RGB e a máscara de depth no respectivo timestamp. Os dois braços são execuções diferentes, portanto **não são o mesmo frame exato**.
2. Captura a ~58fps, timestamps duplicados e frame PTS perdido são defeitos/limites do **gravador**, não provas de stall Godot. Registrar perda e intervalo; nunca contar vídeo ausente como PASS.
3. Rochas e água são preservadas nas execuções, mas o depth é **somente geometria opaca**, sem identidade de objeto. Publicação simultânea desses sistemas não está qualificada. Esconder objetos para simplificar o teste modificaria o contrato visual e não é feito na P5.
4. Nenhuma otimização de workers, mesher, LOD ou mundo A5 autorizada antes de localizar reprovação visual reproduzível **dentro de 130m** e separar defeito real de oclusão, aliasing ou compressor.
5. Mesmo com todos os **1050 pixels amostrados** compatíveis, isso não prova ausência de fissuras entre amostras, 360° a cada posição, todos os quadros originais, a taxa de apresentação real CPU+GPU+Present ou os 100ms de edição. Todos os critérios `PERF-60`, `STREAM-18`, `VIEW-130`, `EDIT-100` permanecem **NOT_QUALIFIED**, sem merge.

## Próxima decisão

Se o piloto apontar um candidato de lacuna dentro de 125m confirmado na inspeção do RGB/depth, abrir correção dirigida de publicação LOD na mesma posição, seed e tempo, com A/B equivalente. Caso contrário, encerrar A8-P5 como evidência dinâmica **amostrada e limitada**, identificar lacunas para os gates restantes e preservar checkpoint A5/CPU16.
