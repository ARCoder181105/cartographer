# 🗺️ Cartographer

> **Turn any codebase into a navigable spatial map — like a city.**

Cartographer is a developer tool that transforms a code repository into an interactive, spatial visualization. Every file is a building, every module is a district, every function call is a road. Proximity means coupling, size means complexity, color means churn. A developer joining a new project opens Cartographer and gets genuine spatial intuition about the codebase in **minutes instead of weeks**.

---

## Why Cartographer Exists

When you join a new codebase you read files linearly — but code is never linear. It's a dense graph of relationships. You can't hold the whole shape in your head by reading files one by one.

Senior engineers have a **mental map** they built over months. Cartographer makes that map **explicit and shareable**.

---

## What It Does

- **Parses** your codebase using a hand-written recursive descent parser (C++) to extract functions, calls, imports, and complexity metrics
- **Layouts** the resulting graph using the Fruchterman-Reingold force-directed algorithm — strongly coupled code clusters together naturally
- **Visualizes** everything in a WebGL-powered interactive map with real-time zoom, pan, search, and editor deep-links
- **Animates** codebase evolution through git history — watch your architecture morph over time

---

## Visual Language

| Visual Property | Meaning |
|---|---|
| Node size | Cyclomatic complexity |
| Node color | Git churn rate (blue = stable, red = hot) |
| Edge thickness | Coupling strength |
| District boundaries | Module/package groupings (convex hulls) |
| Node glow | Currently being edited (filesystem watcher) |

---

## Architecture Overview

Cartographer is built in **three layers across three languages**:

```
┌─────────────────────────────────────┐
│   TypeScript / WebGL  (Frontend)    │  ← Interactive map renderer
├─────────────────────────────────────┤
│   Go (Layout + Query Engine)        │  ← Force-directed layout + HTTP API
├─────────────────────────────────────┤
│   C++ (Parser Engine)               │  ← Recursive descent parser + graph emitter
└─────────────────────────────────────┘
```

---

## Tech Stack

| Layer | Language | Key Components |
|---|---|---|
| Parser | C++ | Hand-written recursive descent parser, custom binary graph format |
| Layout & API | Go | Fruchterman-Reingold algorithm, BFS/Dijkstra pathfinding, HTTP server |
| Frontend | TypeScript | Raw WebGL renderer, convex hull districts, git time-slider |

---

## Key Features

- **Multi-language parsing** — Go and TypeScript support (extensible)
- **Force-directed layout** — mathematically meaningful spatial positions
- **Git history animation** — time-slider morphs the map through every commit
- **Incremental updates** — file changes re-parse only the affected file
- **Spatial queries** — find coupled files, hotspots, call paths in milliseconds
- **Editor integration** — double-click any node to jump to source in VS Code

---

## Getting Started

> Prerequisites: C++17 compiler, Go 1.21+, Node.js 18+

```bash
# 1. Build the parser
cd parser && make

# 2. Run it on a repository
./cartographer-parser /path/to/repo --out graph.cgraph

# 3. Start the layout + query server
cd engine && go run . --graph graph.cgraph

# 4. Start the frontend
cd frontend && npm install && npm run dev

# 5. Open http://localhost:5173
```

---

## Roadmap

See [ROADMAP.md](./ROADMAP.md) for the full phased build plan.

---

## Project Structure

```
cartographer/
├── parser/          # C++ recursive descent parser
│   ├── src/
│   │   ├── lexer/
│   │   ├── parser/
│   │   ├── ast/
│   │   └── emitter/
│   └── Makefile
├── engine/          # Go layout + query server
│   ├── layout/      # Fruchterman-Reingold
│   ├── graph/       # Graph data structures
│   ├── query/       # Spatial + path queries
│   ├── git/         # Git log parser
│   └── server/      # HTTP API
├── frontend/        # TypeScript + WebGL
│   ├── renderer/    # WebGL node/edge rendering
│   ├── camera/      # Pan/zoom controls
│   ├── ui/          # Search, panels, time-slider
│   └── api/         # Go server client
├── shared/
│   └── format/      # Binary graph format spec (.cgraph)
└── docs/
    ├── ROADMAP.md
    ├── MASTERPLAN.md
    ├── ARCHITECTURE.md
    └── ALGORITHMS.md
```

---

## Stretch Goals

- **VS Code extension** — live map panel inside your editor via LSP
- **Dependency vulnerability overlay** — color nodes by known CVEs
- **Team ownership layer** — color by git-blame engineer per district
- **Shareable HTML export** — self-contained single file, no install required

---

## Documentation

- [Roadmap](./docs/ROADMAP.md)
- [Master Plan](./docs/MASTERPLAN.md)  
- [Architecture](./docs/ARCHITECTURE.md)
- [Algorithms](./docs/ALGORITHMS.md)

---

## License

MIT