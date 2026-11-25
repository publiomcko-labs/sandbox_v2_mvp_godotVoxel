# A0 — Fundação Godot + Voxel Tools + C++ (Windows)

## Estado
Código de bootstrap e workflow CI adicionados. **Não confundir commit com aprovação**: o gate exige logs de build, smoke e execução gráfica nativa. Os resultados permanecem `NOT_TESTED` até sua execução.

## Dependências verificáveis
- Godot 4.7.2-stable (upstream `ed1daf0bf001b61586d9930840f2f1394092c079`).
- Voxel Tools 1.7 (módulo integrado, `2ac9f5f8a8219bf499314cc0fad54ffc47df908f`).
- Binário de editor Voxel Tools release v1.7, SHA256 fixado no `third_party.lock`.
- godot-cpp 10.0.0-stable, commit `507ed9d840c01a3c5b2a39af8bb4000bfac30bf5`; **bindings geradas exclusivamente pelo editor com módulo**, não pelo Godot vanilla.
- Windows x64 com MSVC Build Tools e Python 3.12 + scons 4.10.0.

## Instalar / testar em PowerShell
```powershell
git clone https://github.com/publiomcko-cloud/sandbox_v2_mvp_godotVoxel.git
cd sandbox_v2_mvp_godotVoxel
py -3.12 -m pip install scons==4.10.0
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\bootstrap-windows.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\smoke-windows.ps1
& .\.tools\godot.exe --path .\godot --editor
```

Movimento livre na cena: W/A/S/D, E/Q (subir/descer), 18 m/s. Sem colisão/personagem nesta etapa. O mundo é provisoriamente plano (`VoxelGeneratorFlat`), não um SDF com cavernas. A1 implementará relevo determinístico e 130 m efetivos.

## O que o smoke verifica
1. A versão binária foi obtida de um arquivo SHA-256 verificado.
2. O editor realmente expõe `VoxelLodTerrain` em `extension_api.json`.
3. `godot-cpp` está na revisão esperada e a GDExtension é compilada contra a API customizada.
4. O projeto importa; classes `VoxelLodTerrain`, `VoxelViewer` e `WorldBootstrap` instanciam.
5. O método nativo C++ `get_voxel_tool()` é acessível e retorna uma ferramenta válida.

## Gate A0
| Item | Requisito | Estado na criação |
|---|---|---|
| A0-BUILD | Reexecução limpa no Windows / GitHub Actions | NOT_TESTED |
| A0-API | API customizada, GDExtension C++ e smoke | NOT_TESTED |
| A0-RENDER | Janela gráfica real com terreno visível | NOT_TESTED |
| A0-FRAME | 1080p, cena mínima, frame completo <=16,7 ms sem stutter aplicativo | NOT_TESTED |
| A0-REPORT | Log de ambiente, driver, GPU e medição real | NOT_TESTED |

CI headless não é evidência de GPU/render/present; `_process(delta)` é diagnóstico e **não mede frame completo**. A versão gráfica deve ser capturada localmente e o resultado registrado antes de iniciar A1. Não aceitar FPS médio como substituto.

## Limites conscientes da A0
- Este fluxo usa binário customizado **verificado e fixado**, não recompila toda a engine em cada PR. Para auditoria de código, os commits exatos de Godot e Voxel Tools estão no lock; a recompilação completa será validada separadamente se exigida.
- Ainda não existem física, água, edição, persistência, rotas automatizadas ou medição real ponta a ponta. São tarefas das próximas fases.
- GL Compatibility é usado somente no bootstrap A0; Forward+ Vulkan deve ser validado antes do benchmark de GPU, evitando conclusões de desempenho equivocadas.
- O template de export Windows está fixado no lock, mas export de executável ainda não é gate da A0.
