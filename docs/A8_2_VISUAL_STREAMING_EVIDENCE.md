# A8-P2 — evidência visual de continuidade a 18 m/s e cobertura a 130 m

Data: 23/11/2026. **Experimentação separada, sem modificação do A5 CPU16.**

## Decisão após A8-P1

A8-P0/P1 mediram um percurso de 30 s na GTX 1050 Ti com 1.000 frames de warmup. P0 registrou **2 intervalos >20 ms** (máximo 21,978 ms); P1 registrou **0 >20 ms** (máximo 19,967 ms). A8-P1 capturou 24 eventos >=18ms; somente 2 tinham fila de workers não vazia na última amostra de 1 Hz e 3 tinham LODs bloqueados. Não há evidência suficiente para alterar workers, mesher ou LOD. PR #19 encerrado sem merge.

As **8/8 sondas de malha a 130 m** em ambas as execuções não equivalem a pixels/depth nem a rochas e água corretamente publicadas; tampouco identificam fissuras ou flicker. Portanto, a próxima hipótese exige evidência **visual independente**, não mais repetição do diagnóstico de filas.

## A8-P2 — implementação

- Reutiliza `a7-record-evidence-windows.ps1`, `a7-run-windows.ps1`, `a7_route_runtime.gd` e `a7_video_timeline.py`; nenhum algoritmo funcional novo.
- Introduz opção explícita `-A8VisualEvidence` para permitir **1.000 frames realmente desenhados** antes da medição da rota, mesmo em modo de vídeo (antes, warmup por frames era restrito ao benchmark sem captura). O vídeo é capturado com DDAGrab/NVENC durante o warmup e o movimento; a contagem de frames de Godot fica comprovada no relatório.
- Vídeo externo 1920×1080 solicitado a 60 fps, sem readback de PNG e sem PresentMon/ETW. **O custo do gravador exclui estes números do benchmark canônico PERF-60.**
- Piloto padrão: `turns_18mps_300s` abreviado a 30s, com primeira curva por volta de 20s, para examinar carga/transição direcional. Seed 20261119 e baseline A5/CPU16.
- `a8_visual_audit.py` exige proveniência A5, warmup 1000/1000, manifestos consistentes, vídeo original >1MB, hash SHA256, 1080p/60 solicitado, correlação entre marcadores temporais e frames reais e janela de vídeo de pelo menos 20s. Duplicatas/gaps/cadência baixa são sinalizados.
- Nenhum diagnóstico automático marca ausência de fissuras ou 130m corretos. Requer inspeção direta do **vídeo original completo**, com atenção às transições de LOD, terreno ausente, rochas antes do terreno, água ausente, retorno e viradas.
- Cobertura **real de 130m em 360°** ainda exige profundidade/posicionamento geométrico independente (não fornecida por um vídeo RGB). Esta campanha pode mostrar falhas visíveis, mas **não certifica VIEW-130**.

## Executar somente um piloto visual na GPU

Usar a mesma GTX 1050 Ti, sessão gráfica desbloqueada e tela com pelo menos 1920×1080 na origem (0,0). Não colocar outra janela sobre o Godot.

```powershell
cd "C:\Dev\sandbox-a7-etw"
git fetch origin exp/a8-2-stream-view-video-evidence-20261123
git switch --detach FETCH_HEAD
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\a8-p2-visual-windows.ps1"
```

O script encontra a nova campanha em `reports/generated/a7-visual-evidence/evidence-...` e cria **`a8_visual_evidence.zip`** contendo o vídeo original e os manifestos/frames de sincronização/telemetria. O arquivo pode ser significativamente maior que o ZIP A8-P1, pois contém vídeo de tela. Sem vídeo, a análise de flicker não é possível.

A auditoria separa relógio de vídeo, validade de coleta e interpretação visual. Uma falha de captura/PTS não é evidência de defeito no mundo; não repetir baterias longas apenas por erro de agregação.

## Próxima decisão e gates

Se uma fissura, região ou rocha/água desaparecendo for observada em vídeo com timestamp identificável, abrir correção pequena e reproduzível em nova branch, mantendo o checkpoint A5/CPU16. Se o vídeo não mostrar falhas, registrar apenas **observação visual localizada**, ainda sem prova de 360°/130 m ou de múltiplas seeds.

Todos os quatro gates `PERF-60`, `STREAM-18`, `VIEW-130` e `EDIT-100` permanecem **NOT_QUALIFIED**. Não promover PR ou aplicar merge automaticamente.
