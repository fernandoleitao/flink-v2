# UV — Gerenciando imports entre módulos

## Como usar o uv para gerenciar imports entre módulos?

O segredo está em estruturar o projeto como um **pacote instalável** — assim o Python consegue resolver os imports corretamente, independente de onde você executa o código.

### Estrutura básica do projeto

```
meu-projeto/
├── pyproject.toml
├── src/
│   └── meu_app/
│       ├── __init__.py
│       ├── main.py
│       ├── modulo_a.py
│       └── modulo_b.py
└── tests/
    └── test_main.py
```

### `pyproject.toml` mínimo

```toml
[project]
name = "meu-app"
version = "0.1.0"
requires-python = ">=3.11"

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[tool.hatch.build.targets.wheel]
packages = ["src/meu_app"]
```

### Instalar o pacote em modo editável

```bash
uv sync
uv pip install -e .
```

### Fazendo os imports

```python
# src/meu_app/modulo_a.py
def saudacao(nome: str) -> str:
    return f"Olá, {nome}!"
```

```python
# src/meu_app/main.py
from meu_app.modulo_a import saudacao   # ✅ import absoluto
```

### Adicionando um entrypoint

```toml
[project.scripts]
meu-app = "meu_app.main:main"
```

```bash
uv run meu-app
```

### Workspaces (múltiplos pacotes)

```toml
# pyproject.toml (raiz)
[tool.uv.workspace]
members = ["packages/*"]
```

```toml
# packages/api/pyproject.toml
[project]
dependencies = ["core"]

[tool.uv.sources]
core = { workspace = true }
```

---

## Funciona num ambiente onde só tenho o `requirements.txt`?

Sim. O `uv` suporta `requirements.txt` nativamente, mas o problema dos imports é resolvido pela estrutura do projeto.

### Opção 1 — `uv` + `requirements.txt` + instalar o pacote

```bash
uv venv
uv pip install -r requirements.txt
uv pip install -e .
```

### Opção 2 — Manipulando `sys.path` (sem arquivos extras)

```python
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from modulo_a import saudacao
```

### Opção 3 — Gerar `requirements.txt` a partir do `pyproject.toml`

```bash
uv pip compile pyproject.toml -o requirements.txt
```

---

## Uso o uv localmente, mas preciso gerar o `requirements.txt` para a esteira

### Fluxo ideal

```
Localmente → uv (pyproject.toml)
    ↓
git commit → requirements.txt gerado automaticamente
    ↓
CI/esteira → pip install -r requirements.txt + pip install -e .
```

### Automatizar com pre-commit hook

```bash
# .git/hooks/pre-commit
#!/bin/sh
uv pip compile pyproject.toml -o requirements.txt
git add requirements.txt
```

### Na esteira

```yaml
- name: Install dependencies
  run: |
    pip install -r requirements.txt
    pip install -e .
```

### Alternativa: `PYTHONPATH` na esteira

```yaml
- name: Run tests
  env:
    PYTHONPATH: src
  run: pytest
```

---

## Como setar o PYTHONPATH no uv?

Pelo arquivo `.env` na raiz — o `uv run` carrega automaticamente:

```bash
# .env
PYTHONPATH=src
```

Confirmando que funcionou:

```bash
uv run python -c "import sys; print(sys.path)"
```

Configuração alternativa no `pyproject.toml`:

```toml
[tool.uv]
env-file = ".env"
```

---

## Imports de `tests/` para módulos em `src/` com PYTHONPATH

Com `PYTHONPATH=src`, tanto `src/tests/` quanto `tests/` conseguem importar qualquer módulo de `src/`:

```
meu-projeto/
├── .env                  # PYTHONPATH=src
├── src/
│   ├── meu_app/
│   │   ├── __init__.py
│   │   └── modulo_a.py
│   └── tests/            # testes unitários
│       └── test_modulo_a.py
└── tests/                # testes de integração
    └── test_integracao.py
```

```python
# src/tests/test_modulo_a.py
from meu_app.modulo_a import saudacao  # ✅

# tests/test_integracao.py
from meu_app.modulo_a import saudacao  # ✅
```

### Rodando separadamente

```bash
uv run pytest src/tests/    # unitários
uv run pytest tests/        # integração
uv run pytest               # todos
```

```toml
[tool.pytest.ini_options]
testpaths = ["src/tests", "tests"]
```

---

## Sempre preciso criar o `__init__.py`?

Não. Desde o Python 3.3, o `__init__.py` é **opcional**.

| | Com `__init__.py` | Sem `__init__.py` |
|---|---|---|
| Tipo | Regular package | Namespace package (PEP 420) |
| Suporte | Python 2 e 3 | Python 3.3+ |
| Import | Funciona | Funciona |
| Código de inicialização | Sim | Não |

### Quando usar

```python
# __init__.py re-exportando para facilitar imports
from meu_app.modulo_a import saudacao

# Quem importa pode fazer:
from meu_app import saudacao
```

### Recomendação prática

- **`src/meu_app/`** → usa `__init__.py` (é um pacote de verdade)
- **`src/tests/` e `tests/`** → omite, deixa o pytest resolver

---

## Consigo criar módulos via CLI com o uv?

Não. O `uv` é um gerenciador de pacotes e ambientes — não faz scaffolding de código.

O mais próximo:

```bash
uv init meu-projeto       # projeto novo
uv init --lib meu-projeto # com src layout
```

Para criar módulos dentro de um projeto existente, é na mão:

```bash
touch src/meu_app/novo_modulo.py

mkdir src/meu_app/novo_subpacote
touch src/meu_app/novo_subpacote/__init__.py
```

Script simples para automatizar:

```bash
# scripts/new_module.sh
#!/bin/sh
touch src/meu_app/$1.py
echo "Módulo src/meu_app/$1.py criado"
```

```bash
uv run bash scripts/new_module.sh meu_modulo
```
