# V3.1 — World Core e mod-first

Status: **IN_PROGRESS — fundação de manifests**. Checkpoint V3.0: 78d540e6da554082bb83e2949d11c5116e8a40c8. Não modificar o streamer nem a autoridade SDF/material do Voxel Tools. Runtime A5 permanece inalterado neste incremento.

## Primeiro incremento

Contrato C++20 puro em native/src/content_registry/manifest.hpp: manifest schema 1, IDs ASCII minúsculos namespace:id, versão exata (sem resolução de ranges), política data_only, limites iniciais 256 mods/64 dependências/16 roots por pacote e 64 caracteres por ID/versão. Ordem topológica determinística com desempate lexical; falha fechada para duplicatas, dependências ausentes ou pin divergente, ciclos e políticas desconhecidas. Roots relativos compostos por identificadores simples separados por /; screening lexical, NÃO substitui verificação canônica de filesystem. A escolha de pins exatos e roots simples é restrição inicial deliberada para reduzir ambiguidade e superfície de ataque; formatos futuros exigem evolução explícita do schema.

Testes portáveis C++20 via Actions, sem Godot. Não há ainda leitura JSON do disco, loader, hashes SHA-256, validação canônica de paths/reparse points, handlers, snapshot, integração GDExtension, migração de saves, eventos de terreno, scheduler/tiering ou mods externos carregados. Não chamar este incremento de gate V3.1 aprovado.

## Próxima implementação

1. Loader data-only limitado e seguro, JSON estrito, leitura de first-party e externos pela mesma pipeline, verificação canônica e de symlinks/reparse points, hashes e pins.
2. Registry extensível de handlers e snapshots imutáveis com referências tipadas/índices estáveis; dois pacotes externos de demonstração.
3. World Core: comandos/revisões/eventos, adaptador VoxelTool preservando API A5, scheduler de ticks fixos/tiering, persistência versionada em diretório V3 separado. Testes unitários, integração, determinismo, reopen e fixture A5 conforme V3_PROJETO.md.
