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
    powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\a74-pilot-windows.ps1" -Scenario static_remove -Warmup 45

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
