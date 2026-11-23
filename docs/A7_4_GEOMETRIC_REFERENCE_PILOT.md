# A7.4 — piloto de referência geométrica independente da malha editada

**Status:** implementação experimental de metodologia; NÃO é aceite gráfico.
**Base:** A7.3 / PR #16; referência A5 CPU16 inalterada (commit 0c3fee959576d0a1faec9ceecffb4b132a65558b).
**Branch:** exp/a7-4-independent-pixel-pilot-20261123. Não mesclar/promover a A5, A6 ou A7.
**Meta:** descobrir se uma referência geométrica construída ANTES da edição consegue identificar candidatos visuais no vídeo do desktop, sem confundir mudança de câmera, HUD ou FPS nominal com pixels corretos.

## Contrato do piloto

1. godot/tests/a74_pilot.gd usa o mesmo mundo A5 CPU16, mesmo GL Compatibility, raio 1,5m, seed fixa, câmera imóvel, superfície carregada e uma edição por sessão. Cenários isolados: static_remove, static_add, boundary_remove, boundary_add. Não modifica a implementação A5.
2. ANTES do brush, salva um reticulado 11³ de amostras SDF via VoxelTool e 121 raios projetados pela câmera. Remoção prevista = max(SDF_antes, -SDF_esfera); adição prevista = min(SDF_antes, SDF_esfera). A referência não depende da malha renderizada após o brush; depende, entretanto, do SDF inicial do Godot.
3. Com a referência congelada, executa uma edição C++ e oito marcadores verde/magenta, com UTC do Godot. Não usa get_image() nem PNG/readback da GPU.
4. scripts/a74-pilot-windows.ps1 grava vídeo externo 1920×1080 via FFmpeg 7.1.1 D3D11/NVENC, dup_frames=0, sem alterar o monitor. Verifica desktop interativo, monitora o processo em primeiro plano, aborta oclusão e finaliza FFmpeg ordenadamente. Preserva o manifesto quando há erro.
5. scripts/a74_geometry_pilot.py valida integridade, sincroniza os oito marcadores com PTS real, traça raios em Python por interpolação trilinear do SDF anterior, aplica CSG esférica analítica e compara luminância em raios com alteração prevista versus controles estáveis. Não usa SDF posterior nem malha renderizada para construir o oráculo.
6. Os diagnósticos são ORACLE_CONSISTENT_LUMA_CANDIDATE, NO_CONSISTENT_LUMA_SIGNAL ou INSUFFICIENT_INDEPENDENT_RAYS. Qualquer violação de proveniência, integridade ou sincronização falha explicitamente. Nenhum diagnóstico autoriza EDIT-100 PASS.

## Execução gráfica local — um piloto inicial

No computador GPU GTX 1050 Ti, manter a sessão desbloqueada e o jogo em primeiro plano. Fechar janelas particulares; não interagir com o navegador enquanto grava. PowerShell comum é suficiente; não há ETW elevado no piloto. Comandos separados:

    cd "C:\Dev\sandbox-a7-etw"
    git fetch origin exp/a7-4-independent-pixel-pilot-20261123
    git switch --detach FETCH_HEAD
    powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\a74-pilot-windows.ps1" -Scenario static_remove -WarmupFrames 1000

O script usa FFmpeg portátil verificado por SHA-256, gera relatórios em reports/generated/a74-pilot/ por cenário e não modifica saves do jogador. Artefatos: world.sqlite, a74_reference.json, a74_events.jsonl, a74_result.json, a74_capture_manifest.json, desktop-1080p-60fps.mkv, a74_pilot_review.json (se análise concluir).

Se o piloto estático demonstrar sinal metodológico útil, executar separadamente static_add, boundary_remove e boundary_add alterando apenas -Scenario. Não repetir a campanha A7.2 de 300 edições.

## CI CPU-only

    python .\tests\check_a74_geometry_pilot.py

O workflow A0–A7 cobre CSG, profundidade prevista, direção add/remove, referências inválidas e falso positivo quando controles também mudam. Inclui parser PowerShell e parser de GDScript no Godot headless; não é aceitação gráfica.

## Restrições

- ORACLE_CONSISTENT_LUMA_CANDIDATE é apenas hipótese de mudança visual. Não demonstra pixel com profundidade correta nem pixel geometricamente correto. CSG/trilinear pode divergir da discretização, mesher e AA.
- PTS de FFmpeg e marcador HUD não garantem instante de apresentação no monitor. A sincronização é aproximada.
- Não há HID, ETW de apresentação alinhado ao piloto nem buffer de profundidade independente. first_correct_presented_pixel_ms permanece null, EDIT-100 NOT_QUALIFIED, automatic_acceptance false.
- Captura com gravador não mede PERF-60 canônico. STREAM-18 e VIEW-130 continuam NOT_QUALIFIED.
- Uma única edição por sessão qualifica apenas a metodologia, não a latência em 100 operações ou sob movimento.
- Próxima extensão, apenas após evidência favorável: profundidade independente, correlação ETW/vídeo, limites de incerteza, replicação estática e fronteira. Depois testar movimento e campanhas maiores.

## Critério de interrupção

Se não houver raios alterados/controles suficientes, câmera imóvel, foco contínuo ou sincronização válida, não afrouxar limiares para obter PASS. Diagnosticar, registrar e manter NOT_QUALIFIED.

## Auditoria do primeiro piloto real (23/11/2026)

Evidência fornecida: `static_remove-20261123-155735-26860.zip`, commit `6bcd2f9`. Manifesto: Godot=0, FFmpeg=0, foreground_ok=true, 1/1 edição aceita, aplicação nativa 4,131ms. Vídeo 1080p com 3.148 frames; 8/8 marcadores em ordem, alinhamento p99 4,5ms. O vídeo original tem 165 pares de PTS duplicados e intervalo máximo 983ms **fora** do momento da edição, não atribuível automaticamente ao Godot. Na janela da edição (quadros 2926–2938), PTS avançou ~16–17ms sem duplicatas; o primeiro sinal geométrico visível ocorre no quadro 2934.

O analisador P1 original marcou `NO_CONSISTENT_LUMA_SIGNAL` por exigir 18 níveis de alteração **em cada raio**: apenas 3/31 raios previstos e 4/90 controles passaram desse limiar no quadro 2934. Auditoria independente sobre o ROI Gray extraído diretamente do vídeo (ffmpeg, sem reencode visual): nos 31 raios previstos, diferença média de luminância 10,161; nos 90 controles, 2,578. Com limiar de 4 níveis, a cobertura é 83,9% dos raios esperados contra 17,8% dos controles. Um contraste espacial seletivo aparece a partir do frame 2934, cujo PTS alinhado equivale aproximadamente a **33,5 ms após a chamada de brush**. Esse número é `first_oracle_consistent_candidate_ms` aproximado, NÃO o primeiro pixel geometricamente correto ou input-to-photon.

Corretiva A7.4-P1b: manter o teste original de pixels fortes, mas acrescentar um ramo explícito de **contraste espacial relativo** com requisitos simultâneos de cobertura de raios previstos, média de contraste, relação sinal/controle e baixa variação dos controles. Marcar `TIMING_AMBIGUOUS` se houver PTS duplicado, reverso ou gap >34ms **na janela local** de edição. Os testes CPU incluem mudança localizada fraca, iluminação global falsa e PTS duplicado. O relatório original do ZIP **não é alterado** e continua um registro válido do detector anterior.

A revisão visual confirmou uma cavidade de terreno aparecendo após a edição, sem oclusão da janela no trecho avaliado. Ainda não há buffer de profundidade independente, ETW de apresentação alinhado a este piloto nem HID. Todos os gates permanecem `NOT_QUALIFIED`. Próxima aquisição, **somente depois de aprovar CI da corretiva**, pode usar `static_add` para verificar direção oposta antes de boundary ou campanhas amplas.


## A7.4-P1c — bateria de repetições independentes

A coleta estática individual de adição em 23/11/2026 (`static_add-20261123-161352-42048.zip`) confirmou 1/1 edição aceita e aplicação nativa de 4,181 ms; vídeo de 3.154 quadros, 34 raios com mudança geométrica prevista e 87 controles. A gravação apresenta uma elevação sutil, mas o detector P1b retornou `NO_CONSISTENT_LUMA_SIGNAL`. Isso não comprova que a edição falhou: aparência local e critério de detecção são coisas diferentes.

Uma única operação não fornece estimativa robusta de variabilidade. A bateria automatizada `scripts/a74-batch-windows.ps1` repete os quatro cenários **três vezes cada (12 execuções por padrão)** com seed idêntica, mas novo processo, SQLite, referência SDF pré-edição, vídeo e pasta para cada execução. O agregador CPU-only `scripts/a74_batch_report.py` registra número de aquisições válidas, falhas, sinal/no-signal, média/mediana/p95/máximo/desvio amostral da **aplicação nativa**, e estatísticas separadas apenas dos **candidatos visuais** encontrados. Não calcula médias de `first_correct_presented_pixel_ms` e não transforma ausência de sinal em zero.

Execução recomendada no Windows GPU, após o CI da branch passar (PowerShell, sem interação na tela enquanto grava):

    cd "C:\Dev\sandbox-a7-etw"
    git fetch origin exp/a7-4-independent-pixel-pilot-20261123
    git switch --detach FETCH_HEAD
    powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\a74-batch-windows.ps1" -Repeats 3 -WarmupFrames 1000

Para um único cenário que apresentou sinal fraco (3 repetições):

    powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\a74-batch-windows.ps1" -Scenarios static_add -Repeats 3 -WarmupFrames 1000

Para ampliar as seeds somente depois da primeira bateria, mantendo três repetições por cenário e por seed:

    powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\a74-batch-windows.ps1" -SeedList "20261119,20261120,20261121" -Repeats 3 -WarmupFrames 1000

A pasta `reports/generated/a74-batch/batch-<timestamp>-<pid>/` terá `a74_batch_manifest.json`, `a74_batch_report.json`, `a74_batch_trials.csv`, dados completos de cada run, e `a74_batch_summary.zip`. **Envie inicialmente o ZIP resumido.** Ele contém os JSONs e referências geométricas, mas não os vídeos do desktop por privacidade e tamanho. Se algum cenário precisar de verificação quadro a quadro, fornecer somente o vídeo correspondente ou usar `-FullArchive` para criar o ZIP com todos os vídeos. O processo interrompe em erro de aquisição por padrão e produz um resumo parcial reprovado; `-ContinueOnFailure` permite prosseguir com os cenários restantes, preservando as falhas como inválidas. Não alterar o relatório histórico.

**Limitações estatísticas:** três repetições servem como triagem de consistência, não como prova de distribuição de cauda; p95 calculado com n=3 tende a coincidir com o máximo. A medição não é HID-to-photon, e as capturas NVENC não são a carga canônica PERF-60. `EDIT-100`, `PERF-60`, `STREAM-18` e `VIEW-130` permanecem `NOT_QUALIFIED`.

## A7.4-P1d — warmup por frames e recuperação da bateria anterior

**Evidência real** `a74_batch_summary.zip` de 23/11/2026, lote `batch-20261123-163513-36464`: **12/12 execuções gráficas terminaram com 1 edição aceita por sessão**. Quatro capturas (`static_remove` repetições 2–3 e `boundary_remove` repetições 1 e 3) têm `TIMING_AMBIGUOUS` na janela local do PTS; não são falhas de edição, gravação ou aplicação nativa. O agregador P1c descartava essas quatro execuções inteiras, provocando `collection_complete=false` e exit code 2 após mais de 12 capturas. **Corrigido:** manter todos os tempos nativos de aquisições com manifesto válido, mas não atribuir latência de vídeo aos quatro registros ambíguos. As contagens separadas são `video_timing_ambiguous_runs`, `visual_signal_without_usable_timing` e `video_candidate_ms` somente para casos cronometráveis.

Reprocessar **sem repetir nenhum teste** (CPU-only):

    python .\scripts\a74-reprocess-summary.py "C:\Dev\sandbox-a7-etw\reports\generated\a74-batch\batch-20261123-163513-36464\a74_batch_summary.zip"

A saída `a74_batch_summary-reprocessed.zip` preserva o ZIP original e contém a revisão do CSV e do JSON, com o relatório anterior arquivado como `a74_batch_report_original.json`. Requer apenas Python stdlib, sem FFmpeg ou Godot.

**Redução de duração da próxima bateria:** o comando `scripts/a74-batch-windows.ps1` passou a usar `-WarmupFrames 1000` por padrão. O Godot aguarda **1.000 frames realmente desenhados** (`Engine.get_frames_drawn()`), com exigência de LOD0 editável e watchdog. Quando o referencial SDF pré-edição e a câmera estão prontos, escreve `a74_ready.json` e aguarda o Windows iniciar a gravação NVENC externa. Só então inicia os oito marcadores e a edição. Vídeo não inclui o aquecimento e reduz duração, tamanho e esforço do ffprobe/análise; o relatório inclui `warmup_frames_requested`, `warmup_frames_observed` e `warmup_elapsed_ms`. Se o warmup não completar ou o handshake falhar, o piloto falha explicitamente. A captura gráfica continua sem qualificar os quatro gates.

Comando atualizado para **todos os quatro cenários e três repetições**, se nova evidência for indispensável:

    powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\a74-batch-windows.ps1" -Repeats 3 -WarmupFrames 1000

**Não é necessário executar os 12 casos novamente apenas para corrigir a consolidação.** O primeiro próximo experimento útil deverá focalizar a baixa sensibilidade das operações `static_add`/`boundary_add`, somente após avaliar os resumos e decidir um critério visual independente de direção.


## A7.4-P1e — investigação final de adição e encerramento experimental

**Fontes auditadas (23/11/2026):** o lote original de 12 capturas
`batch-20261123-163513-36464` e seu ZIP reprocessado sem modificar
os arquivos originais, mais o vídeo individual
`static_add-20261123-161352-42048.zip`. Não foram feitas novas
gravações nem alterações no motor, terreno ou na baseline A5.

A referência geométrica pré-edição prevê mudanças em 34 raios e usa 87
controles para `static_add`; para `boundary_add`, são 29 raios
alterados e 92 controles. Todas as seis edições (3+3) foram aceitas.
Os três vídeos de cada cenário foram medidos com a **mesma seed e câmera**:
não são amostras independentes da distribuição de terrenos.

| Indicador | static_add (3 sessões) | boundary_add (3 sessões) |
| --- | ---: | ---: |
| Tempo nativo médio do brush | 4,161 ms | 5,607 ms |
| Raio previsto: média de abs delta Y | 1,706 | 3,862 |
| Raios de controle: média de abs delta Y | 0,172 | 0,652 |
| Cobertura com abs delta >= 4 no previsto | 14,7%–17,6% | 62,1% |
| Cobertura com abs delta >= 4 no controle | 0% | 4,3% |
| Estado do detector original | NO_CONSISTENT_LUMA_SIGNAL (3/3) | NO_CONSISTENT_LUMA_SIGNAL (3/3) |
| Assinatura fraca espacial/temporal exploratória | 3/3 | 3/3 |

A inspeção do vídeo individual original de `static_add` (quadros
2902–2918, recorte 240×240) mostrou que a modificação é uma
**elevação discreta**, predominantemente uma borda sombreada da mesma
cor do terreno, não uma mudança forte de cor. A imagem se mantém estável
antes do brush (incluindo os frames 2902–2906) e muda a partir do frame
2907, permanecendo até pelo menos 2950. O detector baseado em >=18
níveis de luminância, ou média >=6 com 70% da máscara alterada, não tem
sensibilidade suficiente para esse caso: no `static_add`, apenas
~15–18% dos raios previstos excedem 4 níveis, apesar do contraste relativo
médio de ~9,9 vezes em relação ao controle.

Foi implementada uma **auditoria separada, exploratória e sem efeito
nos gates**: `scripts/a74_addition_investigation.py`. Ela lê
o ZIP compacto existente, exige proveniência de seis execuções,
dois frames iniciais quietos e ao menos quatro dos cinco frames seguintes
com alteração espacialmente seletiva (média prevista >=1,2, relação
previsto/controle >=5, controles <=0,75, cobertura prevista >=12%,
falsa cobertura <=10%). Rejeita iluminação global, variação apenas
transitória, mudança anterior à edição e relógio ambíguo. Os limiares
foram definidos **depois de ver estas evidências** e, portanto, servem
somente para investigar a causa do falso negativo; **não são critérios
pré-registrados de aprovação**.

Reprodução CPU-only, sem captura, no checkout A7.4:

    python .\scripts\a74_addition_investigation.py "C:\Dev\sandbox-a7-etw\reports\generated\a74-batch\batch-20261123-163513-36464\a74_batch_summary-reprocessed.zip"

A ferramenta cria `a74_addition_investigation.json` ao lado do ZIP,
preservando o relatório original. CI contém
`tests/check_a74_addition_investigation.py` com casos sintéticos
positivos e controles negativos.

### Decisão de encerramento da A7.4

1. **Edição funcional / aplicação nativa:** aceita em 12/12 processos;
   tempos médios 4,113–5,715 ms segundo os cenários. Comprovado somente
   nesse escopo e na mesma seed.
2. **Alteração visual:** remoção apresenta sinal forte em 3/3 de cada
   cenário (dois relógios ambíguos por tipo); adição apresenta **sinal
   visual fraco e repetível em 3/3** de cada cenário, insuficiente para
   certificação da geometria exata.
3. **Metodologia temporal:** warmup de 1000 frames e vídeo pós-warmup
   passaram em piloto gráfico `static_remove-20261123-172130-65272.zip`.
   Esse teste não qualifica automaticamente todos os cenários.
4. **Limites:** não há profundidade independente por pixel, nem HID
   correlacionado a ETW de apresentação. Imagens de aparência não
   comprovam que o mesh corresponde às profundidades previstas.
5. **Gates estritos:** `EDIT-100`, `PERF-60`,
   `STREAM-18`, `VIEW-130`
   **permanecem NOT_QUALIFIED**.

**A7.4 encerrada como experimento diagnóstico, sem promoção.**
Nenhuma mudança aplicada à A5/CPU16, nenhum merge do PR experimental.
Não há justificativa para repetir as 12 capturas novamente apenas para
aumentar a confiança de um detector de luminância incapaz de medir
profundidade. A próxima campanha, se solicitada, deve priorizar
as metas de 60 FPS, continuidade visual a 18 m/s e alcance 130 m,
ou implantar uma prova independente de profundidade/present para EDIT-100
em um experimento distinto.
